#!/usr/bin/env python3
"""Ask about the same long document three times and check whether the 2nd and 3rd first-token times reuse the prefix cache."""
import json, random, sys, time, urllib.request
U = "http://127.0.0.1:8899/v1/chat/completions"
n = int(sys.argv[1]) if len(sys.argv) > 1 else 64000
W = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima".split()
rnd = random.Random(7)
lines = [f"Log {i}: " + " ".join(rnd.choice(W) for _ in range(9)) + "." for i in range(n // 14)]
lines.insert(len(lines) // 3, "Log SECRET-A: the vault code is 111222.")
lines.insert(len(lines) * 2 // 3, "Log SECRET-B: the door code is 333444.")
doc = "\n".join(lines)

def ask(msgs):
    body = {"model": "RED-SNOW-5.3-FLASH-EXL3-2.49", "messages": msgs, "max_tokens": 32, "stream": True,
            "stream_options": {"include_usage": True}, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(U, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; out = []; usage = {}
    with urllib.request.urlopen(req, timeout=3600) as r:
        for raw in r:
            l = raw.decode().strip()
            if not l.startswith("data:") or l[5:].strip() == "[DONE]":
                continue
            ev = json.loads(l[5:])
            usage = ev.get("usage") or usage
            for c in ev.get("choices", []):
                d = c.get("delta", {}).get("content") or ""
                if d and ttft is None:
                    ttft = time.time() - t0
                out.append(d)
    return ttft, usage, "".join(out)

sys_msg = {"role": "system", "content": "You answer questions about the logs below.\n\n" + doc}
for label, msgs in [
    ("first  vault", [sys_msg, {"role": "user", "content": "What is the vault code? Number only."}]),
    ("second door ", [sys_msg, {"role": "user", "content": "What is the door code? Number only."}]),
    ("third  multi", [sys_msg, {"role": "user", "content": "What is the vault code? Number only."},
                      {"role": "assistant", "content": "111222"},
                      {"role": "user", "content": "And the door code? Number only."}]),
]:
    ttft, u, txt = ask(msgs)
    print(f"[prefix {label}] prompt={u.get('prompt_tokens')} ttft={ttft:.1f}s server_prefill={u.get('time_prefill', 0):.1f}s answer={txt.strip()[:20]!r}", flush=True)
