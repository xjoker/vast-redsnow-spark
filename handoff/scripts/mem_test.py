#!/usr/bin/env python3
"""Memory boundary test: A (one large image), A2 (three large images), B (vision + long context). Standard library and PIL only.
Usage: python3 mem_test.py A|A2|B ; each case prints one JSON line to stdout."""
import base64, io, json, os, random, sys, time, urllib.error, urllib.request
from PIL import Image, ImageDraw, ImageFont

URL = os.environ.get("MEM_URL", "http://127.0.0.1:8899/v1/chat/completions")
MODEL = "RED-SNOW-5.3-FLASH-EXL3-2.49"
W, H, NLINES = 2400, 1600, 60
WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa "
         "quebec romeo sierra tango uniform victor whiskey xray yankee zulu").split()


def font():
    try:
        return ImageFont.load_default(size=22)
    except TypeError:
        return ImageFont.load_default()


def make_image(marker, marker_line, seed):
    rnd = random.Random(seed)
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    f = font()
    for i in range(NLINES):
        text = f"row {i:04d}: total = {rnd.randint(1000, 9999)} * k + {rnd.randint(1, 99)}; status ok"
        if i == marker_line:
            text += f" {marker}"
        d.text((40, 40 + i * 24), text, fill="black", font=f)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def post(content, max_tokens):
    body = {"model": MODEL, "messages": [{"role": "user", "content": content}], "max_tokens": max_tokens,
            "stream": False, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time()
    start = time.strftime("%T", time.localtime(t0))
    err = None
    usage, answer = {}, ""
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            d = json.load(r)
        usage = d.get("usage", {})
        answer = d["choices"][0]["message"]["content"] or ""
    except urllib.error.HTTPError as e:
        err = f"HTTP {e.code}: {e.read().decode()[:300]}"
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
    t1 = time.time()
    return {"start": start, "end": time.strftime("%T", time.localtime(t1)), "elapsed_s": round(t1 - t0, 1),
            "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
            "answer": answer.strip()[:200], "error": err}


def case_a(name, images, question, expect):
    content = [{"type": "image_url", "image_url": {"url": uri}} for uri in images]
    content.append({"type": "text", "text": question})
    res = post(content, 50)
    res.update(test=name, images=len(images), ok={k: (k in res["answer"]) for k in expect})
    return res


def case_b():
    rnd = random.Random(160000)
    lines = [f"Log {i}: " + " ".join(rnd.choice(WORDS) for _ in range(9)) + "." for i in range(int(160000 / 14))]
    lines.insert(len(lines) // 2, "Log SECRET: The secret launch code is 4417-ALPHA.")
    long_text = "\n".join(lines)
    question = ("1) What is the secret launch code in the text? "
                "2) What token starting with MARKER- is in the image?")
    content = [{"type": "image_url", "image_url": {"url": make_image("MARKER-58213", 30, 1)}},
               {"type": "text", "text": long_text},
               {"type": "text", "text": question}]
    res = post(content, 100)
    res.update(test="B", images=1, ok={"4417-ALPHA": "4417-ALPHA" in res["answer"],
                                        "58213": "58213" in res["answer"]})
    return res


def main():
    t = sys.argv[1]
    if t == "A":
        r = case_a("A", [make_image("MARKER-58213", 30, 1)],
                   "Find the token that starts with MARKER- in the image and reply with it only.", ["58213"])
    elif t == "A2":
        imgs = [make_image("MARKER-11111", 9, 2), make_image("MARKER-22222", 30, 3), make_image("MARKER-33333", 50, 4)]
        r = case_a("A2", imgs, "Find the three tokens that start with MARKER- in the three images "
                   "(one per image, in image order) and reply with them only.", ["11111", "22222", "33333"])
    elif t == "B":
        r = case_b()
    else:
        sys.exit(f"unknown test {t}")
    print(json.dumps(r, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
