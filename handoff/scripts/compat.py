#!/usr/bin/env python3
"""用官方 openai SDK 逐项检查兼容性。用法: compat.py <base_url> <api_key>"""
import base64, io, json, sys, traceback
from openai import OpenAI, APIStatusError
from PIL import Image, ImageDraw, ImageFont

client = OpenAI(base_url=sys.argv[1], api_key=sys.argv[2] if len(sys.argv) > 2 else "x", timeout=600)
M = "RED-SNOW-5.3-FLASH-EXL3-2.49"
NOTHINK = {"chat_template_kwargs": {"enable_thinking": False}}
results = []


def check(name):
    def wrap(fn):
        try:
            detail = fn()
            results.append((name, "PASS", detail))
        except Exception as exc:
            results.append((name, "FAIL", f"{type(exc).__name__}: {exc}"[:300]))
            traceback.print_exc()
        print(f"{results[-1][1]} {name}: {results[-1][2]}", flush=True)
    return wrap


def image_uri():
    img = Image.new("RGB", (640, 400), "white")
    d = ImageDraw.Draw(img)
    d.text((30, 30), "CODE 7351", fill="black", font=ImageFont.load_default(size=64))
    d.rectangle((30, 180, 250, 380), fill=(220, 30, 30))
    buf = io.BytesIO(); img.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


WEATHER = [{"type": "function", "function": {"name": "get_weather", "description": "Get weather for a city",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]


@check("models.list")
def _():
    ids = [m.id for m in client.models.list().data]
    assert M in ids, ids
    return ids


@check("chat basic non-stream")
def _():
    r = client.chat.completions.create(model=M, messages=[{"role": "user", "content": "Say hello in one word."}],
                                       max_tokens=20, extra_body=NOTHINK)
    assert r.choices[0].finish_reason in ("stop", "length") and r.usage.total_tokens > 0
    return f"{r.choices[0].message.content!r} fp={r.system_fingerprint}"


@check("chat stream + include_usage")
def _():
    s = client.chat.completions.create(model=M, messages=[{"role": "user", "content": "Count 1 to 5."}],
                                       max_tokens=40, stream=True, stream_options={"include_usage": True},
                                       extra_body=NOTHINK)
    text, usage, finish = "", None, None
    for ch in s:
        if ch.usage:
            usage = ch.usage
        for c in ch.choices:
            text += c.delta.content or ""
            finish = c.finish_reason or finish
    assert usage and usage.completion_tokens > 0 and finish
    return f"{text.strip()!r} finish={finish}"


@check("developer role")
def _():
    r = client.chat.completions.create(model=M, max_tokens=20, extra_body=NOTHINK, messages=[
        {"role": "developer", "content": "Always answer with the single word PINEAPPLE."},
        {"role": "user", "content": "What is your answer?"}])
    assert "PINEAPPLE" in r.choices[0].message.content.upper()
    return r.choices[0].message.content


@check("max_completion_tokens -> length")
def _():
    r = client.chat.completions.create(model=M, max_completion_tokens=5, extra_body=NOTHINK,
                                       messages=[{"role": "user", "content": "Write a long story."}])
    assert r.choices[0].finish_reason == "length" and r.usage.completion_tokens <= 5
    return r.usage.completion_tokens


@check("stop sequence")
def _():
    r = client.chat.completions.create(model=M, max_tokens=60, stop=["4"], extra_body=NOTHINK,
                                       messages=[{"role": "user", "content": "Count from 1 to 9 separated by spaces."}])
    assert "4" not in r.choices[0].message.content and "5" not in r.choices[0].message.content
    return repr(r.choices[0].message.content)


@check("tool call round trip")
def _():
    msgs = [{"role": "user", "content": "What's the weather in Paris? Use the tool."}]
    r = client.chat.completions.create(model=M, messages=msgs, tools=WEATHER, extra_body=NOTHINK)
    call = r.choices[0].message.tool_calls[0]
    assert r.choices[0].finish_reason == "tool_calls" and json.loads(call.function.arguments)["city"]
    msgs += [r.choices[0].message.model_dump(exclude_none=True),
             {"role": "tool", "tool_call_id": call.id, "content": "Sunny, 22C"}]
    r2 = client.chat.completions.create(model=M, messages=msgs, tools=WEATHER, max_tokens=60, extra_body=NOTHINK)
    assert "22" in r2.choices[0].message.content
    return f"{call.function.arguments} -> {r2.choices[0].message.content!r}"


@check("tool call streaming assembly")
def _():
    s = client.chat.completions.create(model=M, messages=[{"role": "user", "content": "Weather in Tokyo? Use the tool."}],
                                       tools=WEATHER, stream=True, extra_body=NOTHINK)
    calls, finish = {}, None
    for ch in s:
        for c in ch.choices:
            finish = c.finish_reason or finish
            for tc in c.delta.tool_calls or []:
                e = calls.setdefault(tc.index, {"id": None, "name": "", "args": ""})
                e["id"] = tc.id or e["id"]
                e["name"] += (tc.function.name or "") if tc.function else ""
                e["args"] += (tc.function.arguments or "") if tc.function else ""
    e = calls[0]
    assert finish == "tool_calls" and e["id"] and e["name"] == "get_weather" and json.loads(e["args"])["city"]
    return e


@check("tool_choice named")
def _():
    r = client.chat.completions.create(model=M, messages=[{"role": "user", "content": "Hi there"}], tools=WEATHER,
                                       tool_choice={"type": "function", "function": {"name": "get_weather"}},
                                       extra_body=NOTHINK)
    assert r.choices[0].message.tool_calls[0].function.name == "get_weather"
    return r.choices[0].message.tool_calls[0].function.arguments


@check("tool_choice required")
def _():
    r = client.chat.completions.create(model=M, messages=[{"role": "user", "content": "Hi there"}], tools=WEATHER,
                                       tool_choice="required", extra_body=NOTHINK)
    assert r.choices[0].finish_reason == "tool_calls" and r.choices[0].message.tool_calls
    return r.choices[0].message.tool_calls[0].function.arguments


@check("response_format json_object")
def _():
    r = client.chat.completions.create(model=M, response_format={"type": "json_object"}, max_tokens=200, extra_body=NOTHINK,
                                       messages=[{"role": "user", "content": "Give name and age of a fictional person."}])
    return json.loads(r.choices[0].message.content)


@check("response_format json_schema")
def _():
    schema = {"type": "object", "properties": {"city": {"type": "string"}, "population": {"type": "integer"}},
              "required": ["city", "population"], "additionalProperties": False}
    r = client.chat.completions.create(model=M, max_tokens=200, extra_body=NOTHINK,
                                       response_format={"type": "json_schema", "json_schema": {"name": "c", "schema": schema}},
                                       messages=[{"role": "user", "content": "The largest city in Japan."}])
    d = json.loads(r.choices[0].message.content)
    assert isinstance(d["city"], str) and isinstance(d["population"], int)
    return d


@check("image in user message")
def _():
    r = client.chat.completions.create(model=M, max_tokens=60, extra_body=NOTHINK, messages=[{"role": "user", "content": [
        {"type": "text", "text": "What text is in the image?"},
        {"type": "image_url", "image_url": {"url": image_uri(), "detail": "high"}}]}])
    assert "7351" in r.choices[0].message.content
    return r.choices[0].message.content


@check("image in tool result")
def _():
    msgs = [{"role": "user", "content": "Take a screenshot with the tool, then tell me the code shown."},
            {"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function",
             "function": {"name": "screenshot", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "call_1", "content": [
                {"type": "text", "text": "Screenshot:"}, {"type": "image_url", "image_url": {"url": image_uri()}}]}]
    tools = [{"type": "function", "function": {"name": "screenshot", "parameters": {"type": "object", "properties": {}}}}]
    r = client.chat.completions.create(model=M, messages=msgs, tools=tools, max_tokens=60, extra_body=NOTHINK)
    assert "7351" in (r.choices[0].message.content or "")
    return r.choices[0].message.content


@check("thinking on returns reasoning_content")
def _():
    r = client.chat.completions.create(model=M, max_tokens=2000, reasoning_effort="high",
                                       messages=[{"role": "user", "content": "What is 17*23?"}])
    raw = r.choices[0].message.model_dump()
    assert raw.get("reasoning_content") and "391" in (r.choices[0].message.content or "")
    return f"reasoning {len(raw['reasoning_content'])} chars, answer {r.choices[0].message.content!r}"


@check("error: unknown model -> 404 JSON")
def _():
    try:
        client.chat.completions.create(model="nope", messages=[{"role": "user", "content": "x"}])
    except APIStatusError as e:
        assert e.status_code == 404 and e.body
        return e.body
    raise AssertionError("no error")


@check("error: n=2 -> 400 JSON")
def _():
    try:
        client.chat.completions.create(model=M, n=2, messages=[{"role": "user", "content": "x"}])
    except APIStatusError as e:
        assert e.status_code == 400
        return e.body
    raise AssertionError("no error")


print("\nSUMMARY", sum(r[1] == "PASS" for r in results), "/", len(results))
for name, status, _ in results:
    print(f"  {status} {name}")
