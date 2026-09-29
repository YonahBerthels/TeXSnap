#!/usr/bin/env python3
"""TeXSnap's local recognition server: one model in memory, JSON lines over stdin/stdout.

Started by the app (LocalEngine.swift) on the first local snip and stopped when it has been idle.
Usage: python serve.py <model-dir>

  -> {"id": 1, "image": "/path.png", "prompt": "...", "max_tokens": 2048}
  <- {"ready": true, "model": "...", "load_seconds": 1.2}        once, after loading
  <- {"id": 1, "text": "<accumulated reply>"}                    while generating
  <- {"id": 1, "done": true, "text": "...", "truncated": false, "seconds": 0.4, "tokens": 57}
  <- {"id": 1, "error": "..."}
"""
import json
import os
import sys
import time
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    model_dir = sys.argv[1]
    t0 = time.time()
    # Keep library chatter off stdout, which carries the protocol.
    real_stdout, sys.stdout = sys.stdout, sys.stderr
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template

    model, processor = load(model_dir, trust_remote_code=True)
    sys.stdout = real_stdout
    send({"ready": True, "model": os.path.basename(os.path.normpath(model_dir)),
          "load_seconds": round(time.time() - t0, 2)})

    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            send({"error": f"bad request: {e}"})
            continue
        rid = req.get("id")
        try:
            max_tokens = int(req.get("max_tokens", 2048))
            prompt = apply_chat_template(processor, model.config, req["prompt"], num_images=1)
            t = time.time()
            text, tokens, last_sent = "", 0, 0.0
            sys.stdout = sys.stderr
            try:
                for chunk in stream_generate(model, processor, prompt, image=[req["image"]],
                                             max_tokens=max_tokens, temperature=0.0):
                    text += chunk.text
                    tokens = getattr(chunk, "generation_tokens", tokens + 1)
                    now = time.time()
                    if now - last_sent > 0.05:
                        real_stdout.write(json.dumps({"id": rid, "text": text}) + "\n")
                        real_stdout.flush()
                        last_sent = now
            finally:
                sys.stdout = real_stdout
            send({"id": rid, "done": True, "text": text, "truncated": tokens >= max_tokens,
                  "seconds": round(time.time() - t, 3), "tokens": tokens})
        except Exception as e:  # report and keep serving
            send({"id": rid, "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
