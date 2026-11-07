#!/usr/bin/env python3
"""헤르메스 음성 종단 테스트: 앱이 보내는 것과 같은 요청을 폰 안의 중계 서버(127.0.0.1:8787)로 → 실제 Hermes API 서버 → 실제 모델.

  python3 voice-e2e.py <relay_token_file>
환경: HAS_KEY=1 이면 실제 모델 대화·작업까지, 아니면 연결·보안만 검사.
"""
import json
import os
import socket
import sys
import time
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

RELAY = "http://127.0.0.1:%s" % os.environ.get("RELAY_PORT", "8787")
TOKEN = open(sys.argv[1]).read().strip()
PASS = FAIL = 0


def ok(cond, msg, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("OK   " + msg)
    else:
        FAIL += 1
        print("FAIL " + msg + (("  — " + detail) if detail else ""))


def post(path, body, token=TOKEN, timeout=600):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(RELAY + path, data=json.dumps(body, ensure_ascii=False).encode(), headers=headers)
    try:
        with urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except HTTPError as e:
        return e.code, e.read()


def ask(text, conversation=None):
    """앱처럼 한 번 말하기 → NDJSON 이벤트 목록, 최종 답변."""
    body = {"requestId": str(uuid.uuid4()), "text": text}
    if conversation:
        body["conversationId"] = conversation
    t = time.time()
    status, raw = post("/v1/voice-requests", body)
    events = [json.loads(l) for l in raw.decode().splitlines() if l.strip()] if status == 200 else []
    done = next((e for e in events if e.get("type") == "done"), None)
    err = next((e for e in events if e.get("type") == "error"), None)
    kinds = sorted({e.get("type") for e in events})
    print("     · %.0f초, 이벤트 %s%s" % (time.time() - t, kinds, (" 오류 " + err["error"]) if err else ""))
    return events, (done or {}).get("reply", "")


# 1) 보안 — 토큰 없거나 틀리면 거부, 와이파이 쪽(0.0.0.0)에 안 열림
s, _ = post("/v1/voice-requests", {"requestId": str(uuid.uuid4()), "text": "안녕"}, token=None)
ok(s == 401, "토큰 없이 음성 요청 거부 (%s)" % s)
s, _ = post("/v1/voice-requests", {"requestId": str(uuid.uuid4()), "text": "안녕"}, token="wrong-token-123456")
ok(s == 401, "틀린 토큰 거부 (%s)" % s)
ips = [a for a in os.popen("hostname -I").read().split() if not a.startswith("127.")]
for port, name in ((8787, "음성 중계 서버"), (8642, "Hermes API 서버")):
    reachable = False
    for ip in ips[:1]:
        try:
            socket.create_connection((ip, port), timeout=2).close()
            reachable = True
        except OSError:
            pass
    ok(not reachable, "%s는 외부 주소(%s)에서 안 열림" % (name, ips[0] if ips else "-"))
s, _ = post("/v1/voice-approvals", {"requestId": str(uuid.uuid4()), "approvalId": "run_fake", "approve": True})
ok(s == 404, "요청하지 않은 승인은 거부 (%s)" % s)

if os.environ.get("HAS_KEY") != "1":
    print("   (NVIDIA_API_KEY 없음 → 실제 모델 대화 검사 생략)")
else:
    # 2) 말로 묻고 답 듣기 (문장 단위 스트리밍)
    ev, reply = ask("안녕! 한 문장으로 짧게 인사해 줘.")
    ok(bool(reply) and any(e.get("type") == "text" for e in ev), "음성 질문 → 답변 (문장 단위로 도착)", reply[:80])
    print("     답변: " + reply[:120])

    # 3) 이어지는 대화 (같은 Hermes 세션)
    conv = uuid.uuid4().hex[:16]
    ask("내 별명은 '은하수'야. 기억해 줘. 짧게 대답해.", conv)
    _, reply = ask("방금 내가 말한 내 별명이 뭐였지? 별명만 말해 줘.", conv)
    ok("은하수" in reply, "이어지는 대화 — 앞 내용 기억", reply[:80])

    # 4) 말로 작업 시키기 — 실제 도구(터미널) 실행 후 결과 보고
    year = time.strftime("%Y")
    ev, reply = ask("터미널에서 date +%Y 명령을 실제로 실행하고, 출력된 연도 숫자만 말해 줘.")
    ran = any(e.get("type") in ("progress", "approval") for e in ev)
    ok(year in reply and ran, "음성으로 작업 시키기 — 명령 실행 후 결과 보고 (%s)" % year, reply[:80])
    if any(e.get("type") == "approval" for e in ev):
        print("     (참고: 이 명령에 승인 요청이 왔음)")

print("RESULT: PASS=%d FAIL=%d  (헤르메스 음성)" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
