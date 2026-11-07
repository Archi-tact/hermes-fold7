#!/usr/bin/env bash
# scripts/90-hermes-voice.sh — 헤르메스 음성: 측면 버튼으로 불러 말로 질문·작업 시키기 (PC 없이 폰 하나로)
#
#   bash scripts/90-hermes-voice.sh setup    # 처음 한 번: API 서버 켜기 + 중계 서버 설치 + 앱 페어링
#   bash scripts/90-hermes-voice.sh start    # 시작 (재부팅 후에는 자동)
#   bash scripts/90-hermes-voice.sh stop | status
#   bash scripts/90-hermes-voice.sh pair     # 앱에 페어링 토큰 다시 전달 (앱을 지웠다 깔았을 때)
#   bash scripts/90-hermes-voice.sh update   # git pull 뒤 중계 서버 코드 갱신
#   bash scripts/90-hermes-voice.sh edge     # (선택) 고품질 Edge 음성용 edge-tts 설치 — 답변 문장이 Microsoft 로 전송됨
#
# 구조 (모두 폰 안, 127.0.0.1 에만 열림):
#   헤르메스 음성 앱 ──HTTP(페어링 토큰)──▶ 중계 서버 127.0.0.1:8787 (voice/hermes_voice_relay.py)
#                                          └─▶ Hermes API 서버 127.0.0.1:8642 (hermes gateway, API_SERVER_KEY)
#   음성으로 시킨 작업도 같은 Hermes(같은 스킬·폰 브리지·Hands·승인 규칙)로 실행됩니다.
#   위험한 작업은 Hermes 승인 요청 → 앱이 소리로 묻고 분명한 "네" 만 승인. approvals.deny 는 그대로.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${HERMES_MODE:-$(cat "$HOME/.hermes-bridge/mode" 2>/dev/null || echo apt)}"
STATE="${VOICE_STATE:-$HOME/.hermes-voice}"          # Termux 쪽 상태(pid, 로그)
RELAY_PORT="${RELAY_PORT:-8787}"
API_PORT="${API_SERVER_PORT:-8642}"
APP_PKG="ai.hermesfold7.voice"
APP_MAIN="$APP_PKG/com.architact.hermesvoice.MainActivity"
mkdir -p "$STATE"; chmod 700 "$STATE"

if [ "$MODE" = proot ]; then
  HC=hermes-proot; HH="/root/.hermes"; V_GUEST="/root/.hermes-voice"
  G() { proot-distro login "${PROOT_DISTRO:-debian}" -- /usr/bin/env -i HOME=/root PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin "$@"; }
else
  HC="${HERMES_CMD:-hermes}"; HH="${HERMES_HOME:-$HOME/.hermes}"; V_GUEST="$HOME/.hermes-voice-srv"
  G() { "$@"; }
fi
# proot-distro 는 인자를 셸로 다시 해석할 수 있음 → '$' 가 든 스크립트는 stdin 으로
guest_sh() { G /bin/sh -s; }
say() { printf '\033[1;36m[voice]\033[0m %s\n' "$*"; }

put_relay() {
  tar -C "$KIT/voice" -cf - hermes_voice_relay.py | G sh -c "mkdir -p '$V_GUEST' && chmod 700 '$V_GUEST' && tar -xf - -C '$V_GUEST'"
}

# ~/.hermes/.env 에 API 서버 설정 (이미 있으면 키는 그대로 둠). 키·토큰은 화면/로그에 출력하지 않음.
configure() {
  sed -e "s#__HH__#$HH#g" -e "s#__VG__#$V_GUEST#g" -e "s#__PORT__#$API_PORT#g" <<'__CFG__' | guest_sh
set -e
umask 077
ENV="__HH__/.env"; mkdir -p "__HH__"; touch "$ENV"; chmod 600 "$ENV"
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 43; }
setkv() {  # setkv KEY VALUE — 있으면 바꾸고 없으면 추가
  if grep -q "^$1=" "$ENV"; then
    grep -v "^$1=" "$ENV" > "$ENV.tmp"; printf '%s=%s\n' "$1" "$2" >> "$ENV.tmp"; mv "$ENV.tmp" "$ENV"
  else printf '%s=%s\n' "$1" "$2" >> "$ENV"; fi
}
setkv API_SERVER_ENABLED true
setkv API_SERVER_HOST 127.0.0.1
setkv API_SERVER_PORT __PORT__
grep -q '^API_SERVER_KEY=..' "$ENV" || setkv API_SERVER_KEY "$(rand)"
chmod 600 "$ENV"
mkdir -p "__VG__"; chmod 700 "__VG__"
[ -s "__VG__/relay_token" ] || rand > "__VG__/relay_token"
chmod 600 "__VG__/relay_token"
__CFG__
}

relay_running() { [ -f "$STATE/relay.pid" ] && kill -0 "$(cat "$STATE/relay.pid")" 2>/dev/null; }
api_up() { curl -s -o /dev/null -m 3 "http://127.0.0.1:$API_PORT/health"; }
relay_up() { curl -s -o /dev/null -m 3 "http://127.0.0.1:$RELAY_PORT/"; }
gateway_running() { pgrep -f "gateway run" >/dev/null 2>&1; }

start_gateway() {
  if api_up; then return 0; fi
  if gateway_running; then
    say "게이트웨이가 API 서버 없이 실행 중 → 재시작해서 API 서버 켜기"
    pkill -f "gateway run" 2>/dev/null || true; sleep 3
  fi
  say "Hermes API 서버 시작 (hermes gateway · 127.0.0.1:$API_PORT)"
  command -v termux-wake-lock >/dev/null && termux-wake-lock 2>/dev/null || true
  nohup $HC gateway run > "$STATE/gateway.log" 2>&1 &
  echo $! > "$STATE/gateway.pid"
  for _ in $(seq 1 120); do api_up && return 0; sleep 1; done
  echo "❌ Hermes API 서버가 응답하지 않음 — 로그:"; tail -30 "$STATE/gateway.log"; exit 1
}

start_relay() {
  if relay_running && relay_up; then return 0; fi
  say "음성 중계 서버 시작 (127.0.0.1:$RELAY_PORT)"
  # Hermes 의 파이썬(edge-tts 포함)을 우선 사용, 없으면 python3. .env 의 API_SERVER_KEY 를 환경으로만 넘김
  sed -e "s#__HH__#$HH#g" -e "s#__VG__#$V_GUEST#g" -e "s#__RP__#$RELAY_PORT#g" -e "s#__AP__#$API_PORT#g" > "$STATE/run-relay.sh" <<'__RUN__'
PY=python3
for c in "__HH__/hermes-agent/venv/bin/python" "__HH__/hermes-agent/.venv/bin/python" "__HH__/bin/hermes-python"; do
  [ -x "$c" ] && { PY="$c"; break; }
done
API_SERVER_KEY="$(grep '^API_SERVER_KEY=' "__HH__/.env" | tail -1 | cut -d= -f2-)"
export API_SERVER_KEY
export HERMES_API_URL="http://127.0.0.1:__AP__" RELAY_HOST=127.0.0.1 RELAY_PORT=__RP__ RELAY_TOKEN_FILE="__VG__/relay_token"
exec "$PY" -u "__VG__/hermes_voice_relay.py"
__RUN__
  nohup bash -c "$(declare -f G); G /bin/sh -s" < "$STATE/run-relay.sh" > "$STATE/relay.log" 2>&1 &
  echo $! > "$STATE/relay.pid"
  for _ in $(seq 1 30); do
    relay_up && { say "준비됨 → 측면 버튼(또는 '헤르메스 음성' 앱)으로 말하기"; return 0; }
    relay_running || break
    sleep 1
  done
  echo "❌ 음성 중계 서버 시작 실패 — 로그:"; tail -20 "$STATE/relay.log"; exit 1
}

stop_relay() {
  relay_running && kill "$(cat "$STATE/relay.pid")" 2>/dev/null || true
  pkill -f "hermes_voice_relay.py" 2>/dev/null || true
  rm -f "$STATE/relay.pid"
}

pair() {
  local tok; tok="$(G cat "$V_GUEST/relay_token" 2>/dev/null || true)"
  [ -n "$tok" ] || { echo "❌ 토큰 없음 — 먼저: bash scripts/90-hermes-voice.sh setup"; exit 1; }
  if ! command -v am >/dev/null 2>&1; then
    echo "(이 환경엔 am 이 없어 앱 페어링 생략 — 폰 Termux 에서 pair 실행)"; return 0
  fi
  if am start -n "$APP_MAIN" --es pairing_token "$tok" >/dev/null 2>&1; then
    say "앱에 페어링 토큰 전달 → 앱에 '페어링되었습니다' 가 보이면 완료"
  else
    echo "❌ '헤르메스 음성' 앱이 없음 → 먼저 설치:"
    echo "   https://github.com/Archi-tact/hermes-fold7/releases/download/voice-latest/hermes-voice.apk"
    exit 1
  fi
}

install_boot() {
  [ -d "$HOME/.termux" ] || return 0
  mkdir -p "$HOME/.termux/boot"
  install -m 700 "$KIT/boot/30-voice" "$HOME/.termux/boot/30-voice"
}

status() {
  api_up && echo "Hermes API 서버: 켜짐 (127.0.0.1:$API_PORT)" || echo "Hermes API 서버: 꺼짐"
  relay_up && echo "음성 중계 서버: 켜짐 (127.0.0.1:$RELAY_PORT)" || echo "음성 중계 서버: 꺼짐"
}

case "${1:-}" in
  setup)
    say "설정 ($MODE): API 서버 키·페어링 토큰 생성 (화면에 표시하지 않음)"
    configure; put_relay; install_boot
    start_gateway; start_relay; pair
    cat <<'EOF'

✅ 헤르메스 음성 설치 완료
   측면 버튼으로 부르기 (한 번만 설정):
     1) 설정 → 애플리케이션 → 기본 앱 선택 → 디지털 어시스턴트 앱 → '헤르메스 음성'
     2) 설정 → 유용한 기능 → 측면 버튼 → 길게 누르기 → 디지털 어시스턴트 호출
   예) "오늘 일정 알려줘", "설정 앱 열어서 와이파이 보여줘" — 위험한 작업은 소리로 확인 후 "네" 라고 답하면 진행
EOF
    ;;
  start) configure; put_relay; start_gateway; start_relay ;;
  stop) stop_relay; say "음성 중계 서버 중지 (Hermes 게이트웨이는 그대로)" ;;
  status) status ;;
  pair) pair ;;
  update) put_relay; install_boot; if relay_running; then stop_relay; start_relay; fi; say "음성 중계 서버 갱신 완료" ;;
  edge)
    printf 'for c in %s/hermes-agent/venv/bin/python %s/hermes-agent/.venv/bin/python; do [ -x "$c" ] && { "$c" -m pip install -q edge-tts && echo OK; exit 0; }; done\npython3 -m pip install -q --user --break-system-packages edge-tts && echo OK\n' "$HH" "$HH" | guest_sh
    stop_relay; start_relay
    say "Edge 음성 준비 → 앱 메뉴 '고품질 음성(Edge) 사용'" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
