#!/usr/bin/env python3
"""RED-SNOW 服务压测：功能冒烟、上下文扫描（预填/解码速度 + 大海捞针）、并发。只用标准库。"""
import json, sys, time, threading, urllib.request, random, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://127.0.0.1:8899")
ap.add_argument("--token", default="")
ap.add_argument("--model", default="RED-SNOW-5.3-FLASH-EXL3-2.49")
ap.add_argument("--tests", default="smoke,tool,ctx,conc")
ap.add_argument("--ctx", default="1000,8000,32000,64000,128000,200000,250000")
ap.add_argument("--gen", type=int, default=256)
ap.add_argument("--conc", default="1,2,4")
args = ap.parse_args()
U = args.url.rstrip("/") + "/v1/chat/completions"


def post(body, stream=False, timeout=7200):
    h = {"Content-Type": "application/json"}
    if args.token:
        h["Authorization"] = "Bearer " + args.token
    req = urllib.request.Request(U, data=json.dumps(body).encode(), headers=h)
    return urllib.request.urlopen(req, timeout=timeout)


def chat(messages, max_tokens, **kw):
    """流式请求，返回 (首字时间, 总时间, usage, 文本)。"""
    body = {"model": args.model, "messages": messages, "max_tokens": max_tokens, "stream": True,
            "stream_options": {"include_usage": True}, "temperature": 0.7, "top_p": 0.95, "min_p": 0,
            "chat_template_kwargs": {"enable_thinking": False}, **kw}
    t0 = time.time(); ttft = None; usage = None; text = []
    with post(body, stream=True) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            ev = json.loads(data)
            if ev.get("usage"):
                usage = ev["usage"]
            for c in ev.get("choices", []):
                d = c.get("delta", {}).get("content") or ""
                if d and ttft is None:
                    ttft = time.time() - t0
                text.append(d)
    return ttft, time.time() - t0, usage or {}, "".join(text)


def smoke():
    ttft, tot, u, txt = chat([{"role": "user", "content": "Write a Python LRU cache class with O(1) get/put and unit tests."}], 1500)
    print(f"[smoke] ttft={ttft:.2f}s total={tot:.1f}s completion={u.get('completion_tokens')} "
          f"decode_tok_s={u.get('decode_tok_s')} draft_accept={u.get('draft_accept')}")
    print("[smoke] head:", txt[:160].replace("\n", " "))


def tool():
    body = {"model": args.model, "messages": [{"role": "user", "content": "Weather in Paris for 3 days? Use the tool."}],
            "tools": [{"type": "function", "function": {"name": "get_weather", "parameters": {"type": "object",
                      "properties": {"city": {"type": "string"}, "days": {"type": "integer"}}, "required": ["city"]}}}],
            "chat_template_kwargs": {"enable_thinking": False}}
    with post(body) as r:
        c = json.load(r)["choices"][0]
    print(f"[tool] finish={c['finish_reason']} calls={json.dumps(c['message'].get('tool_calls'))[:200]}")


WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa "
         "quebec romeo sierra tango uniform victor whiskey xray yankee zulu").split()


def filler(n_tokens, seed):
    rnd = random.Random(seed)
    # 每句约 14 token；带编号，避免重复文本被模型当成无意义
    lines = []
    need = int(n_tokens / 14)
    for i in range(need):
        lines.append(f"Log {i}: " + " ".join(rnd.choice(WORDS) for _ in range(9)) + ".")
    return lines


def ctx_sweep():
    for n in [int(x) for x in args.ctx.split(",")]:
        lines = filler(n, n)
        code = f"{random.Random(n).randint(100000, 999999)}"
        pos = len(lines) * 2 // 3
        lines.insert(pos, f"Log SECRET: the vault code is {code}.")
        prompt = "\n".join(lines) + "\n\nQuestion: what is the vault code mentioned in the logs? Answer with the number only."
        try:
            ttft, tot, u, txt = chat([{"role": "user", "content": prompt}], args.gen)
        except Exception as e:
            print(f"[ctx {n}] ERROR {e}")
            continue
        pt = u.get("prompt_tokens") or 0
        ct = u.get("completion_tokens") or 0
        dec = (ct / (tot - ttft)) if ttft and tot > ttft and ct else None
        print(f"[ctx {n}] prompt_tokens={pt} ttft={ttft:.1f}s prefill={pt / ttft:.0f} tok/s "
              f"completion={ct} decode={dec and round(dec, 1)} tok/s server_decode={u.get('decode_tok_s')} "
              f"needle={'OK' if code in txt else 'MISS'} answer={txt.strip()[:40]!r}", flush=True)


def conc():
    prompt = [{"role": "user", "content": "Explain how a B-tree insert works, step by step, with an example."}]
    for k in [int(x) for x in args.conc.split(",")]:
        res = []
        def one():
            res.append(chat(prompt, 400))
        t0 = time.time()
        ts = [threading.Thread(target=one) for _ in range(k)]
        [t.start() for t in ts]; [t.join() for t in ts]
        wall = time.time() - t0
        toks = sum(r[2].get("completion_tokens", 0) for r in res)
        print(f"[conc {k}] wall={wall:.1f}s total_tokens={toks} aggregate={toks / wall:.1f} tok/s "
              f"ttft={[round(r[0], 1) for r in res]}", flush=True)


for t in args.tests.split(","):
    {"smoke": smoke, "tool": tool, "ctx": ctx_sweep, "conc": conc}[t]()
