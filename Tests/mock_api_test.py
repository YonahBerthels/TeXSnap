#!/usr/bin/env python3
"""Exercises the app's Anthropic API engine against a local mock of the Messages API.

The mock checks every request against the documented shape (headers, model, streaming, system prompt
with cache_control, base64 image, effort, fallbacks) and replays scripted SSE streams: normal replies,
retries after overload, a rejected fallback beta, refusals, mid-stream errors, truncation and the
LaTeX auto-repair round trip.

Usage: python3 Tests/mock_api_test.py   (needs build/TeXSnap.app)
"""
import base64
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "TeXSnap.app", "Contents", "MacOS", "TeXSnap")
IMAGE = os.path.join(ROOT, "Tests", "fixtures", "quadratic.png")

REQUESTS = []  # (scenario, headers, body)
COUNTS = {}


def reply(latex, kind="math"):
    return f"<kind>{kind}</kind>\n<latex>\n{latex}\n</latex>"


def sse(events):
    out = b""
    for e in events:
        out += f"event: {e['type']}\ndata: {json.dumps(e)}\n\n".encode()
    return out


def stream(text_blocks, stop_reason="end_turn", model="claude-opus-5-5", stop_details=None, error_after=None):
    events = [{"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant",
                                                    "model": model, "content": [], "stop_reason": None,
                                                    "usage": {"input_tokens": 10, "output_tokens": 1}}},
              {"type": "ping"},
              {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}},
              {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": ""}},
              {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "abc"}},
              {"type": "content_block_stop", "index": 0}]
    index = 1
    for block in text_blocks:
        if block == "FALLBACK":
            events += [{"type": "content_block_start", "index": index,
                        "content_block": {"type": "fallback", "from": {"model": model}, "to": {"model": "claude-opus-5"}}},
                       {"type": "content_block_stop", "index": index}]
            index += 1
            continue
        events.append({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
        for i in range(0, len(block), 7):
            events.append({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": block[i:i + 7]}})
            if error_after is not None and i >= error_after:
                events.append({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
                return sse(events)
        events.append({"type": "content_block_stop", "index": index})
        index += 1
    delta = {"stop_reason": stop_reason, "stop_sequence": None}
    if stop_details:
        delta["stop_details"] = stop_details
    events += [{"type": "message_delta", "delta": delta, "usage": {"output_tokens": 42}}, {"type": "message_stop"}]
    return sse(events)


def check_request(headers, body):
    problems = []
    expect = lambda cond, msg: None if cond else problems.append(msg)
    expect(headers.get("x-api-key") == "test-key", "x-api-key header")
    expect(headers.get("anthropic-version") == "2023-06-01", "anthropic-version header")
    expect(headers.get("content-type", "").startswith("application/json"), "content-type header")
    expect(body.get("model") == "claude-opus-5-5", f"model {body.get('model')}")
    expect(body.get("stream") is True, "stream: true")
    expect(isinstance(body.get("max_tokens"), int) and body["max_tokens"] >= 16000, "max_tokens")
    expect("thinking" not in body, "thinking must be omitted on Opus 5.5 (adaptive by default)")
    expect("temperature" not in body and "top_p" not in body, "no sampling parameters")
    expect(body.get("output_config") == {"effort": "medium"}, f"output_config {body.get('output_config')}")
    system = body.get("system")
    expect(isinstance(system, list) and system[0].get("type") == "text" and "TeXSnap" in system[0].get("text", "")
           and system[0].get("cache_control") == {"type": "ephemeral"}, "system block with cache_control")
    msgs = body.get("messages", [])
    expect(len(msgs) == 1 and msgs[0].get("role") == "user", "one user message")
    content = msgs[0].get("content", []) if msgs else []
    expect(len(content) == 2, "image + text content")
    if len(content) == 2:
        img, txt = content
        src = img.get("source", {})
        expect(img.get("type") == "image" and src.get("type") == "base64" and src.get("media_type") == "image/png",
               "base64 png image block")
        try:
            data = base64.b64decode(src.get("data", ""), validate=True)
            expect(data[:8] == b"\x89PNG\r\n\x1a\n", "image data is a PNG")
        except Exception:  # noqa: BLE001
            problems.append("image data is valid base64")
        expect(txt.get("type") == "text" and txt.get("text"), "text block")
    if "fallbacks" in body:
        expect(body["fallbacks"] == "default", "fallbacks: default")
        expect(headers.get("anthropic-beta") == "server-side-fallback-2026-07-01", "fallback beta header")
    else:
        expect("anthropic-beta" not in headers, "no beta header without fallbacks")
    return problems


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, payload, content_type="application/json", extra=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", content_type)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, kind, message, extra=None):
        self.send(status, {"type": "error", "error": {"type": kind, "message": message}}, extra=extra)

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        scenario = parts[1] if len(parts) >= 3 and parts[0] == "scenario" else "?"
        if not self.path.endswith("/v1/messages"):
            return self.error(404, "not_found_error", f"bad path {self.path}")
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        headers = {k.lower(): v for k, v in self.headers.items()}
        REQUESTS.append((scenario, headers, body))
        n = COUNTS[scenario] = COUNTS.get(scenario, 0) + 1
        problems = check_request(headers, body)
        if problems:
            return self.error(400, "invalid_request_error", "mock: " + "; ".join(problems))
        ok = lambda blocks, **kw: self.send(200, stream(blocks, **kw), "text/event-stream")
        prompt = body["messages"][0]["content"][1]["text"]

        if scenario == "ok":
            return ok([reply(r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}")])
        if scenario == "overloaded_once":
            return self.error(529, "overloaded_error", "Overloaded") if n == 1 else ok([reply("x^2")])
        if scenario == "rate_limited_once":
            return self.error(429, "rate_limit_error", "slow down", {"retry-after": "1"}) if n == 1 else ok([reply("y^2")])
        if scenario == "fallback_rejected":
            if "fallbacks" in body:
                return self.error(400, "invalid_request_error", "fallbacks: Extra inputs are not permitted")
            return ok([reply("z^2")])
        if scenario == "auth":
            return self.error(401, "authentication_error", "invalid x-api-key")
        if scenario == "refusal":
            return ok([], stop_reason="refusal", stop_details={"type": "refusal", "category": "cyber", "explanation": None})
        if scenario == "midstream_error":
            return ok([reply(r"\alpha + \beta + \gamma + \delta")], error_after=14)
        if scenario == "fallback_block":
            return ok(["<kind>math</kind>\n<latex>\na + ", "FALLBACK", "b\n</latex>"], model="claude-opus-5")
        if scenario == "truncated_then_repaired":
            if n == 1:
                return ok(["<kind>math</kind>\n<latex>\n\\frac{1}{2"], stop_reason="max_tokens")
            assert "cut off" in prompt, prompt
            return ok([reply(r"\frac{1}{2}")])
        if scenario == "repair":
            if n == 1:
                return ok([reply(r"\frac{a}{b")])
            if "Missing closing brace" not in prompt or r"\frac{a}{b" not in prompt:
                return self.error(400, "invalid_request_error", "mock: repair prompt lacks the problem: " + prompt)
            return ok([reply(r"\frac{a}{b}")])
        if scenario == "table":
            return ok([reply("\\begin{tabular}{|c|c|}\n\\hline\na & b \\\\\n\\hline\n\\end{tabular}", kind="table")])
        return self.error(404, "not_found_error", f"unknown scenario {scenario}")


def run_app(port, scenario, *extra):
    env = dict(os.environ, ANTHROPIC_API_KEY="test-key",
               TEXSNAP_API_BASE_URL=f"http://127.0.0.1:{port}/scenario/{scenario}")
    p = subprocess.run([APP, "--recognize", IMAGE, "--engine", "api", "--json", *extra],
                       capture_output=True, text=True, env=env, timeout=120)
    out = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else None
    return p.returncode, out, p.stderr.strip()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    failures = []

    def case(name, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -- {detail}"))
        if not cond:
            failures.append(name)

    code, out, err = run_app(port, "ok")
    case("normal streamed reply", code == 0 and out["latex"] == r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"
         and out["kind"] == "math" and out["problems"] == [] and out["engine"] == "Anthropic API", f"{code} {out} {err}")
    case("request shape accepted by the mock (headers, body, image)", COUNTS.get("ok") == 1, err)

    code, out, err = run_app(port, "overloaded_once")
    case("retries after 529 overloaded", code == 0 and out["latex"] == "x^2" and COUNTS["overloaded_once"] == 2, f"{code} {err}")

    code, out, err = run_app(port, "rate_limited_once")
    case("retries after 429 with retry-after", code == 0 and out["latex"] == "y^2" and COUNTS["rate_limited_once"] == 2, f"{code} {err}")

    code, out, err = run_app(port, "fallback_rejected")
    sent = [r[2] for r in REQUESTS if r[0] == "fallback_rejected"]
    case("drops the fallback beta when rejected", code == 0 and out["latex"] == "z^2" and "fallbacks" in sent[0]
         and "fallbacks" not in sent[1], f"{code} {err}")

    code, out, err = run_app(port, "auth")
    case("401 is reported, not retried", code == 1 and "API key was rejected" in err and COUNTS["auth"] == 1, f"{code} {err}")

    code, out, err = run_app(port, "refusal")
    case("refusal stop reason is reported", code == 1 and "declined" in err, f"{code} {err}")

    code, out, err = run_app(port, "midstream_error")
    case("mid-stream error after text is reported, not retried", code == 1 and "overloaded" in err.lower()
         and COUNTS["midstream_error"] == 1, f"{code} {err} {COUNTS.get('midstream_error')}")

    code, out, err = run_app(port, "fallback_block")
    case("text continues across a fallback block", code == 0 and out["latex"] == "a + b" and out["model"] == "claude-opus-5",
         f"{code} {out} {err}")

    code, out, err = run_app(port, "truncated_then_repaired")
    case("truncated reply triggers a repair", code == 0 and out["latex"] == r"\frac{1}{2}" and out["repaired"] is True
         and COUNTS["truncated_then_repaired"] == 2, f"{code} {out} {err}")

    code, out, err = run_app(port, "repair")
    case("invalid LaTeX triggers one repair with the error", code == 0 and out["latex"] == r"\frac{a}{b}"
         and out["repaired"] is True and out["problems"] == [] and COUNTS["repair"] == 2, f"{code} {out} {err}")

    COUNTS.pop("repair")
    code, out, err = run_app(port, "repair", "--no-repair")
    case("--no-repair keeps the problem visible", code == 0 and out["latex"] == r"\frac{a}{b" and out["problems"]
         and COUNTS["repair"] == 1, f"{code} {out} {err}")

    code, out, err = run_app(port, "table")
    case("table reply with formats", code == 0 and out["kind"] == "table" and "markdown" in out["formats"]
         and out["formats"]["tsv"] == "a\tb", f"{code} {out} {err}")

    server.shutdown()
    print(f"\n{len(failures)} failed" if failures else "\nall API engine tests passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
