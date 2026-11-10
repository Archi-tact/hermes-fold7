#!/usr/bin/env python3
"""EXAONE API 문서(docs.exaone.ai/ko/docs/k-exaone-2.5)대로 동작하는 가짜 서버 — 실제 Hermes 가 보내는 요청을 검사.

  python3 mock_exaone.py <port> <log.jsonl>
문서와 다른 요청(틀린 모델 ID, low/high/max 가 아닌 reasoning_effort)은 400 으로 거부.
받은 요청의 요약을 log.jsonl 에 기록 (키는 맞았는지만 기록).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
KEY = "test-exaone-key.123"
MODEL = "k-exaone_v2.5"
TRIGGER = "EXAONE_TOOL_TEST"
MARK = "exaone-tool-ok"


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def decide(body):
    """(본문, 도구 호출) — 트리거 문장이면 터미널 도구를 호출하고, 도구 결과가 오면 그 결과를 답한다."""
    msgs = body.get("messages", [])
    user = next((text_of(m.get("content")) for m in reversed(msgs) if m.get("role") == "user"), "")
    tool_out = [text_of(m.get("content")) for m in msgs if m.get("role") == "tool"]
    if TRIGGER in user:
        if tool_out:
            return ("결과: " + MARK if any(MARK in t for t in tool_out) else "도구 결과 없음"), None
        names = [t.get("function", {}).get("name") for t in body.get("tools", [])]
        if "terminal" in names:
            return "", {"name": "terminal", "arguments": json.dumps({"command": "echo " + MARK})}
    return "안녕하세요.", None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        key_ok = self.headers.get("Authorization") == "Bearer " + KEY
        kwargs = body.get("chat_template_kwargs") or {}
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "path": self.path, "key_ok": key_ok, "model": body.get("model"), "stream": bool(body.get("stream")),
                "reasoning_effort": body.get("reasoning_effort"), "preserve_thinking": kwargs.get("preserve_thinking"),
                "tools": len(body.get("tools") or []), "roles": [m.get("role") for m in body.get("messages", [])],
            }, ensure_ascii=False) + "\n")
        if self.path != "/v1/chat/completions":
            return self.send(404, {"error": {"message": "not found"}})
        if not key_ok:
            return self.send(401, {"error": {"message": "invalid api key"}})
        if body.get("model") != MODEL:
            return self.send(400, {"error": {"message": "unknown model"}})
        if body.get("reasoning_effort") not in (None, "low", "high", "max"):
            return self.send(400, {"error": {"message": "reasoning_effort must be low, high or max"}})

        text, call = decide(body)
        tool_calls = [{"index": 0, "id": "call_1", "type": "function", "function": call}] if call else None
        finish = "tool_calls" if call else "stop"
        base = {"id": "chatcmpl-mock", "model": MODEL, "created": 1}
        if not body.get("stream"):
            msg = {"role": "assistant", "reasoning_content": "생각 중", "content": ("\n\n" + text) if text else None}
            if tool_calls:
                msg["tool_calls"] = tool_calls
            return self.send(200, {**base, "object": "chat.completion",
                                   "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        deltas = [{"role": "assistant", "reasoning_content": "생각 중"}]
        if text:
            deltas.append({"content": "\n\n" + text})
        if tool_calls:
            deltas.append({"tool_calls": tool_calls})
        for i, d in enumerate(deltas + [{}]):
            done = i == len(deltas)
            chunk = {**base, "object": "chat.completion.chunk",
                     "choices": [{"index": 0, "delta": d, "finish_reason": finish if done else None}]}
            self.wfile.write(b"data: " + json.dumps(chunk, ensure_ascii=False).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
