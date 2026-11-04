#!/usr/bin/env bash
# scripts/80-hermes-fold.sh — Hermes Fold: 폰 전용 화면(웹앱) + PC Hermes Desktop 원격 연결
#
#   bash scripts/80-hermes-fold.sh setup       # 화면 설치 + 비밀번호/토큰 생성 (처음 한 번)
#   bash scripts/80-hermes-fold.sh start       # 서버 시작 → 폰 Chrome 에서 http://127.0.0.1:9130
#   bash scripts/80-hermes-fold.sh stop | status
#   bash scripts/80-hermes-fold.sh remote-on   # PC Hermes Desktop 연결 허용 (Tailscale 안에서만)
#   bash scripts/80-hermes-fold.sh remote-off
#   bash scripts/80-hermes-fold.sh password    # 새 비밀번호 발급
#
# 구조 (서버 하나):
#   hermes dashboard --host 127.0.0.1 --port 9130   ← Hermes 공식 서버. 화면만 Hermes Fold 로 교체(HERMES_WEB_DIST)
#     · 폰 브라우저  : http://127.0.0.1:9130  → 비밀번호 로그인(쿠키) → /api/ws (1회용 티켓)
#     · PC Desktop   : http://<Tailscale IP>:9130 → 세션 토큰. remote-on 일 때만 socat 이 Tailscale IP 에서 중계
# 보안:
#   · 서버는 127.0.0.1 에만 열림 (와이파이·카페 네트워크에서 안 보임). 원격은 Tailscale(암호화) IP 에서만 중계
#   · public_url 설정으로 '로그인 필수' 모드 강제 → 폰의 다른 앱이 127.0.0.1 로 접근해도 비밀번호 없이는 못 씀
#   · 비밀번호는 scrypt 해시로만 저장, 토큰은 600 권한 파일
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${FOLD_PORT:-9130}"
MODE="${HERMES_MODE:-$(cat "$HOME/.hermes-bridge/mode" 2>/dev/null || echo apt)}"
STATE="${FOLD_STATE:-$HOME/.hermes-fold}"            # Termux 쪽 상태(pid, 로그, 표시용 정보)
mkdir -p "$STATE"; chmod 700 "$STATE"

# Hermes 실행 명령 + Hermes 가 보는 경로(proot 는 게스트 안 경로가 다름)
if [ "$MODE" = proot ]; then
  HC=hermes-proot
  ROOTFS="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/${PROOT_DISTRO:-debian}"
  H_HOST="$ROOTFS/root/.hermes-fold"; H_GUEST="/root/.hermes-fold"
else
  HC="${HERMES_CMD:-hermes}"
  H_HOST="$HOME/.hermes-fold-srv"; H_GUEST="$H_HOST"
fi
WEB_HOST="$H_HOST/web"; WEB_GUEST="$H_GUEST/web"
TOKEN_HOST="$H_HOST/desktop.token"; TOKEN_GUEST="$H_GUEST/desktop.token"

say() { printf '\033[1;35m[fold]\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { [ -n "${PREFIX:-}" ] && pkg install -y "$2" >/dev/null 2>&1; }; command -v "$1" >/dev/null 2>&1 || { echo "❌ $1 필요 (pkg install $2)" >&2; exit 1; }; }

tailscale_ip() {  # 안드로이드 Tailscale 앱이 만든 100.64.0.0/10 주소
  [ -n "${TS_IP:-}" ] && { echo "$TS_IP"; return; }
  { ip -4 addr 2>/dev/null; ifconfig 2>/dev/null; } | grep -oE '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' | head -1
}

scrypt_hash() {  # Hermes basic_auth 와 같은 형식: scrypt$N$r$p$salt_b64$dk_b64
  local pw="$1" f hex sb dk; f="$(mktemp)"; openssl rand 16 > "$f"
  hex="$(od -An -v -tx1 "$f" | tr -d ' \n')"; sb="$(base64 < "$f" | tr -d '\n')"; rm -f "$f"
  dk="$(openssl kdf -binary -keylen 32 -kdfopt "pass:$pw" -kdfopt "hexsalt:$hex" \
        -kdfopt n:16384 -kdfopt r:8 -kdfopt p:1 SCRYPT | base64 | tr -d '\n')"
  printf 'scrypt$16384$8$1$%s$%s' "$sb" "$dk"
}

new_password() {
  need openssl openssl-tool
  local pw; pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)"
  $HC config set dashboard.basic_auth.username fold >/dev/null
  $HC config set dashboard.basic_auth.password_hash "$(scrypt_hash "$pw")" >/dev/null
  $HC config set dashboard.basic_auth.password "" >/dev/null 2>&1 || true
  echo "$pw"
}

setup() {
  need openssl openssl-tool
  say "화면 파일 설치 → $WEB_HOST"
  mkdir -p "$WEB_HOST"; rm -rf "${WEB_HOST:?}"/*
  cp -R "$KIT/ui/fold/." "$WEB_HOST/"
  chmod -R go-w "$H_HOST"
  say "PC Desktop 연결용 토큰"
  [ -s "$TOKEN_HOST" ] || { umask 077; openssl rand -base64 36 | tr -d '\n/+=' > "$TOKEN_HOST"; }
  chmod 600 "$TOKEN_HOST"
  local ts; ts="$(tailscale_ip || true)"
  # 비-루프백 public_url → Hermes 가 '로그인 필수' 모드로 동작 (Tailscale 주소면 PC 접속 Host 도 허용됨)
  local pub="http://${ts:-hermes-fold.invalid}:$PORT"
  $HC config set dashboard.public_url "$pub" >/dev/null
  $HC config set dashboard.basic_auth.secret "$(openssl rand -hex 32)" >/dev/null
  $HC config set dashboard.basic_auth.session_ttl_seconds 2592000 >/dev/null   # 폰에서 30일 로그인 유지
  $HC config set HERMES_WEB_DIST "$WEB_GUEST" >/dev/null
  $HC config set HERMES_DASHBOARD_SESSION_TOKEN "file:$TOKEN_GUEST" >/dev/null
  local pw; pw="$(new_password)"
  printf '%s\n' "$pub" > "$STATE/public_url"
  cat <<EOF

✅ Hermes Fold 설치 완료
   폰 화면 : bash scripts/80-hermes-fold.sh start  →  Chrome 에서 http://127.0.0.1:$PORT
   로그인  : 아이디 fold / 비밀번호 $pw
             (지금 한 번만 표시 — 잊으면: bash scripts/80-hermes-fold.sh password)
   Chrome 메뉴 ⋮ → '홈 화면에 추가' 하면 앱처럼 전체화면으로 열립니다.
EOF
  [ -n "$ts" ] || echo "   (Tailscale 주소를 못 찾음 → PC 연결은 Tailscale 켠 뒤 setup 을 다시 실행)"
}

running() { [ -f "$STATE/server.pid" ] && kill -0 "$(cat "$STATE/server.pid")" 2>/dev/null; }

start() {
  [ -d "$WEB_HOST" ] || setup
  if running; then say "이미 실행 중 (pid $(cat "$STATE/server.pid"))"; return; fi
  say "Hermes 서버 시작 (127.0.0.1:$PORT)"
  nohup $HC dashboard --skip-build --no-open --host 127.0.0.1 --port "$PORT" > "$STATE/server.log" 2>&1 &
  echo $! > "$STATE/server.pid"
  for _ in $(seq 1 90); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    running || { echo "❌ 서버가 바로 종료됨 — 로그:"; tail -30 "$STATE/server.log"; exit 1; }
    sleep 1
  done
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" || { echo "❌ 서버 응답 없음"; tail -30 "$STATE/server.log"; exit 1; }
  say "준비됨 → 폰 Chrome: http://127.0.0.1:$PORT"
}

stop() {
  remote_off >/dev/null 2>&1 || true
  if running; then kill "$(cat "$STATE/server.pid")" 2>/dev/null || true; sleep 1; fi
  rm -f "$STATE/server.pid"; say "중지됨"
}

remote_on() {
  need socat socat
  running || start
  local ts; ts="$(tailscale_ip || true)"
  [ -n "$ts" ] || { echo "❌ Tailscale 주소 없음: 폰에서 Tailscale 을 켜세요 (또는 TS_IP=100.x.y.z 지정)"; exit 1; }
  grep -q "$ts" "$STATE/public_url" 2>/dev/null || { say "Tailscale 주소가 바뀜 → 설정 갱신 후 재시작"; $HC config set dashboard.public_url "http://$ts:$PORT" >/dev/null; echo "http://$ts:$PORT" > "$STATE/public_url"; stop; start; }
  [ -f "$STATE/remote.pid" ] && kill "$(cat "$STATE/remote.pid")" 2>/dev/null || true
  # Tailscale 주소에만 바인드 → 같은 와이파이의 다른 기기는 접근 불가
  nohup socat "TCP-LISTEN:$PORT,bind=$ts,fork,reuseaddr" "TCP:127.0.0.1:$PORT" > "$STATE/remote.log" 2>&1 &
  echo $! > "$STATE/remote.pid"
  sleep 1
  cat <<EOF

✅ PC 연결 허용 (Tailscale 안에서만)
   PC 에서 Hermes Desktop → 'Connect to existing Hermes'
     URL           : http://$ts:$PORT
     Session token : $(cat "$TOKEN_HOST")
   끄기: bash scripts/80-hermes-fold.sh remote-off
EOF
}

remote_off() { [ -f "$STATE/remote.pid" ] && kill "$(cat "$STATE/remote.pid")" 2>/dev/null || true; rm -f "$STATE/remote.pid"; say "PC 연결 닫음"; }

status() {
  running && echo "서버: 실행 중 (pid $(cat "$STATE/server.pid")) → http://127.0.0.1:$PORT" || echo "서버: 꺼짐"
  [ -f "$STATE/remote.pid" ] && kill -0 "$(cat "$STATE/remote.pid")" 2>/dev/null && echo "PC 연결: 켜짐 ($(cat "$STATE/public_url"))" || echo "PC 연결: 꺼짐"
}

case "${1:-}" in
  setup) setup ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  remote-on) remote_on ;;
  remote-off) remote_off ;;
  password) pw="$(new_password)"; echo "새 비밀번호: $pw  (아이디 fold) — 서버 재시작 필요"; running && { stop; start; } ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
