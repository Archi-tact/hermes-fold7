"""PC Hermes Desktop 이 쓰는 원격 연결 경로 검사: Tailscale 주소(중계) → 세션 토큰 → /api/ws JSON-RPC.
   usage: python desktop-remote.py http://<ts-ip>:9130 <token>"""
import asyncio, json, sys
import websockets

base, token = sys.argv[1], sys.argv[2]
ws_base = base.replace("http://", "ws://") + "/api/ws"
P = F = 0
def ok(m):
    global P; P += 1; print("OK   " + m)
def bad(m):
    global F; F += 1; print("FAIL " + m)

async def rpc(ws, i, method, params=None):
    await ws.send(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}}))
    while True:
        f = json.loads(await asyncio.wait_for(ws.recv(), 30))
        if f.get("id") == i:
            return f

async def main():
    # 1) 올바른 토큰
    try:
        async with websockets.connect(f"{ws_base}?token={token}", open_timeout=20) as ws:
            first = json.loads(await asyncio.wait_for(ws.recv(), 20))
            ok(f"토큰으로 원격 연결 → 첫 신호 {first.get('params', {}).get('type') or first.get('method')}")
            r = await rpc(ws, "d1", "session.list", {"limit": 5})
            if "result" in r:
                ok(f"원격에서 대화 목록 조회 ({len(r['result'].get('sessions', []))}개)")
            else:
                bad(f"session.list {r}")
    except Exception as e:
        bad(f"토큰 원격 연결 실패: {e!r}")
    # 2) 틀린 토큰은 거부
    try:
        async with websockets.connect(f"{ws_base}?token=wrong-{token[:4]}", open_timeout=20) as ws:
            m = await asyncio.wait_for(ws.recv(), 10)
            bad(f"틀린 토큰이 연결됨: {m[:80]}")
    except Exception as e:
        ok(f"틀린 토큰 거부 ({type(e).__name__})")
    # 3) 토큰 없이도 거부
    try:
        async with websockets.connect(ws_base, open_timeout=20) as ws:
            m = await asyncio.wait_for(ws.recv(), 10)
            bad(f"토큰 없이 연결됨: {m[:80]}")
    except Exception as e:
        ok(f"토큰 없는 연결 거부 ({type(e).__name__})")

asyncio.run(main())
print(f"\nRESULT: PASS={P} FAIL={F}  (PC Desktop 원격 경로)")
sys.exit(1 if F else 0)
