#!/usr/bin/env python3
"""Vision smoke test: draw an image locally (text + color blocks), send it as an OpenAI image_url data URI, once streaming and once not."""
import base64, io, json, sys, time, urllib.request
from PIL import Image, ImageDraw, ImageFont

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8899/v1/chat/completions"
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""

img = Image.new("RGB", (800, 500), "white")
d = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 72)
except OSError:
    font = ImageFont.load_default(size=72)
d.text((40, 40), "CODE 7351", fill="black", font=font)
d.rectangle((40, 220, 300, 460), fill=(220, 30, 30))
d.ellipse((420, 220, 680, 460), fill=(30, 60, 220))
buf = io.BytesIO(); img.save(buf, "PNG")
uri = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

msgs = [{"role": "user", "content": [
    {"type": "image_url", "image_url": {"url": uri}},
    {"type": "text", "text": "What text is written in the image, and what colors and shapes are below it? Answer in one sentence."}]}]


def call(stream):
    body = {"model": "RED-SNOW-5.3-FLASH-EXL3-2.49", "messages": msgs, "max_tokens": 200, "stream": stream,
            "chat_template_kwargs": {"enable_thinking": False}}
    if stream:
        body["stream_options"] = {"include_usage": True}
    h = {"Content-Type": "application/json"}
    if TOKEN:
        h["Authorization"] = "Bearer " + TOKEN
    t0 = time.time()
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            if not stream:
                d = json.load(r)
                return time.time() - t0, d["usage"], d["choices"][0]["message"]["content"]
            out, usage = [], {}
            for raw in r:
                l = raw.decode().strip()
                if l.startswith("data:") and l[5:].strip() != "[DONE]":
                    ev = json.loads(l[5:]); usage = ev.get("usage") or usage
                    for c in ev.get("choices", []):
                        out.append(c.get("delta", {}).get("content") or "")
            return time.time() - t0, usage, "".join(out)
    except urllib.error.HTTPError as e:
        return time.time() - t0, {}, f"HTTP {e.code}: {e.read().decode()[:300]}"


for stream in (False, True):
    t, u, txt = call(stream)
    print(f"[vision stream={stream}] {t:.1f}s prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')} -> {txt.strip()[:300]!r}", flush=True)
