#!/usr/bin/env bash
# scripts/80-hermes-fold.sh — Hermes Fold: 폰 전용 화면(웹앱) + PC Hermes Desktop 원격 연결
#
#   bash scripts/80-hermes-fold.sh setup       # 화면 설치 + 비밀번호/토큰 생성 (처음 한 번)
#   bash scripts/80-hermes-fold.sh start       # 서버 시작 → 폰 Chrome 에서 http://127.0.0.1:9130
#   bash scripts/80-hermes-fold.sh stop | status
#   bash scripts/80-hermes-fold.sh remote-on   # PC Hermes Desktop 연결 허용 (Tailscale 안에서만)
#   bash scripts/80-hermes-fold.sh remote-off
#   bash scripts/80-hermes-fold.sh password    # 새 비밀번호 발급
#   bash scripts/80-hermes-fold.sh update      # 화면 파일만 최신으로 (git pull 뒤)
#   bash scripts/80-hermes-fold.sh notify-setup  # 화면을 닫았을 때 답변 완료 알림
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
  HC=hermes-proot; H_GUEST="/root/.hermes-fold"
  # 게스트 파일은 proot-distro 로 직접 읽고 씀 (버전마다 rootfs 위치가 달라서 경로를 가정하지 않음)
  G() { proot-distro login "${PROOT_DISTRO:-debian}" -- /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin "$@"; }
else
  HC="${HERMES_CMD:-hermes}"; H_GUEST="$HOME/.hermes-fold-srv"
  G() { "$@"; }
fi
WEB_GUEST="$H_GUEST/web"; TOKEN_GUEST="$H_GUEST/desktop.token"
put_web() {   # ui/fold → Hermes 가 보는 위치
  tar -C "$KIT/ui/fold" -cf - . | G sh -c "rm -rf '$WEB_GUEST' && mkdir -p '$WEB_GUEST' && tar -xf - -C '$WEB_GUEST' && chmod -R go-w '$H_GUEST'"
}
# 파일 첨부 플러그인 (POST /api/plugins/fold-upload/upload · 로그인 필요) → Hermes 플러그인 폴더. 서버 재시작 후 적용
if [ "$MODE" = proot ]; then PLUGIN_GUEST="/root/.hermes/plugins/fold-upload"; else PLUGIN_GUEST="${HERMES_HOME:-$HOME/.hermes}/plugins/fold-upload"; fi
put_plugin() {
  tar -C "$KIT/ui/fold-plugin" -cf - . | G sh -c "rm -rf '$PLUGIN_GUEST' && mkdir -p '$PLUGIN_GUEST' && tar -xf - -C '$PLUGIN_GUEST' && chmod -R go-w '$PLUGIN_GUEST'"
}
# 최신 Hermes 는 사용자 플러그인을 plugins.enabled 허용 목록에 있어야만 켬 → 기존 목록은 그대로 두고 fold-upload 만 추가
#   반환: 0 = 이번에 새로 추가함(서버 재시작 필요), 1 = 이미 있음
enable_plugin() {
  local cur names json
  cur="$(get_value plugins.enabled 2>/dev/null || true)"
  names="$(printf '%s\n' "$cur" | grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*' | grep -vxE 'None|null|none|plugins|enabled|true|false' || true)"
  printf '%s\n' "$names" | grep -qx 'fold-upload' && return 1
  json="[$(printf '%s\nfold-upload\n' "$names" | grep . | sort -u | sed 's/.*/"&"/' | paste -sd, -)]"   # 이름은 안전한 글자만이라 그대로 JSON
  $HC config set plugins.enabled "$json" >/dev/null
  return 0
}
token() { G cat "$TOKEN_GUEST" 2>/dev/null; }
make_token() {
  token | grep -q . && return 0
  openssl rand -base64 36 | tr -d '\n/+=' | G sh -c "umask 077; mkdir -p '$H_GUEST'; cat > '$TOKEN_GUEST'"
}

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

# proot-distro 는 명령 인자를 셸로 다시 해석할 수 있어 '$' 가 든 값(비밀번호 해시)이 깨짐 → 스크립트를 stdin 으로 전달
guest_sh() { G /bin/sh -s; }
set_secret_value() {  # set_secret_value 키 값
  if [ "$MODE" = proot ]; then
    printf 'PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin\ncd /root\nhermes config set %s "$(cat <<'"'"'__HV__'"'"'\n%s\n__HV__\n)" >/dev/null\n' "$1" "$2" | guest_sh
  else
    $HC config set "$1" "$2" >/dev/null
  fi
}
get_value() {
  if [ "$MODE" = proot ]; then printf 'PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin\ncd /root\nhermes config get %s\n' "$1" | guest_sh 2>/dev/null
  else $HC config get "$1" 2>/dev/null; fi
}

notify_setup() {  # 답변 완료 알림 훅: Hermes 가 턴을 끝낼 때(on_session_end) — 화면이 닫혀 있을 때만 폰 알림
  sed "s/__PORT__/$PORT/" <<'__NS__' | guest_sh
HH="${HERMES_HOME:-$HOME/.hermes}"; mkdir -p "$HH/agent-hooks"
cat > "$HH/agent-hooks/fold-notify.sh" <<'__HOOK__'
#!/bin/sh
# Hermes Fold: 답변이 끝났는데 화면(브라우저)이 닫혀 있으면 폰 알림. 화면을 보고 있으면 조용히.
HH="${HERMES_HOME:-$HOME/.hermes}"
payload="$(cat)"
case "$payload" in
  *'"interrupted": true'*) exit 0 ;;
  *'"failed": true'*) msg="작업이 실패했어요 · 눌러서 확인" ;;
  *'"completed": true'*) msg="답변이 도착했어요 · 눌러서 확인" ;;
  *) exit 0 ;;
esac
hb="$HH/state/dashboard_clients.heartbeat"
if [ -f "$hb" ]; then age=$(( $(date +%s) - $(stat -c %Y "$hb") )); [ "$age" -lt 25 ] && exit 0; fi
PATH="/root/.hermes-bridge-client:$PATH" phone notify "Hermes" "$msg" "http://127.0.0.1:__PORT__" >/dev/null 2>&1 || true
__HOOK__
chmod 700 "$HH/agent-hooks/fold-notify.sh"
# 훅 등록(config) + 이 훅 하나만 승인(allowlist) — 파이썬 없이 hermes config / jq 로
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
CMD="$HH/agent-hooks/fold-notify.sh"
hermes config set hooks.on_session_end "[{\"command\": \"$CMD\", \"timeout\": 20}]" >/dev/null
AL="$HH/shell-hooks-allowlist.json"; [ -s "$AL" ] || echo '{"approvals": []}' > "$AL"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg c "$CMD" --arg t "$NOW" '.approvals = ([(.approvals // [])[] | select(.command != $c)] + [{event: "on_session_end", command: $c, approved_at: $t, script_mtime_at_approval: $t}])' "$AL" > "$AL.tmp" && mv "$AL.tmp" "$AL"
chmod 600 "$AL"
hermes hooks list 2>/dev/null | grep -q 'fold-notify.sh' && echo "알림 훅 설정: $CMD" || { echo "알림 훅 등록 확인 실패" >&2; exit 1; }
__NS__
}

new_password() {
  need openssl openssl-tool
  local pw h got; pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 4)"
  h="$(scrypt_hash "$pw")"
  case "$h" in scrypt\$16384\$8\$1\$?*\$?*) ;; *) echo "❌ 비밀번호 해시 생성 실패 (openssl kdf 확인: pkg install openssl-tool)" >&2; exit 1 ;; esac
  $HC config set dashboard.basic_auth.username fold >/dev/null
  set_secret_value dashboard.basic_auth.password_hash "$h"
  $HC config set dashboard.basic_auth.password "" >/dev/null 2>&1 || true
  got="$(get_value dashboard.basic_auth.password_hash | tr -d "[:space:]\"'" | grep -o 'scrypt.*' || true)"
  if [ -n "$got" ] && [ "$got" != "$h" ]; then echo "❌ 저장된 비밀번호 해시가 깨졌습니다 (저장: '${got:0:24}…')" >&2; exit 1; fi
  [ -n "$got" ] || echo "(참고: 저장값 확인 생략 — config get 결과 없음)" >&2
  echo "$pw"
}

setup() {
  need openssl openssl-tool
  say "화면 파일 설치 → $WEB_GUEST ($MODE)"
  put_web
  put_plugin
  enable_plugin || true
  say "PC Desktop 연결용 토큰"
  make_token
  local ts; ts="$(tailscale_ip || true)"
  # 비-루프백 public_url → Hermes 가 '로그인 필수' 모드로 동작 (Tailscale 주소면 PC 접속 Host 도 허용됨)
  local pub="http://${ts:-hermes-fold.invalid}:$PORT"
  $HC config set dashboard.public_url "$pub" >/dev/null
  $HC config set dashboard.basic_auth.secret "$(openssl rand -hex 32)" >/dev/null
  $HC config set dashboard.basic_auth.session_ttl_seconds 2592000 >/dev/null   # 폰에서 30일 로그인 유지
  $HC config set HERMES_WEB_DIST "$WEB_GUEST" >/dev/null
  $HC config set HERMES_DASHBOARD_SESSION_TOKEN "file:$TOKEN_GUEST" >/dev/null
  notify_setup || echo "⚠ 답변 알림 설정 실패 (나중에: bash scripts/80-hermes-fold.sh notify-setup)"
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
  G test -f "$WEB_GUEST/index.html" || setup
  if running; then say "이미 실행 중 (pid $(cat "$STATE/server.pid"))"; return; fi
  say "Hermes 서버 시작 (127.0.0.1:$PORT)"
  command -v termux-wake-lock >/dev/null && termux-wake-lock 2>/dev/null || true   # 화면을 꺼도/앱을 내려도 계속 동작
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
  # proot 안에서 뜬 서버는 바깥 pid 를 죽여도 남을 수 있음 → 명령줄로 한 번 더 정리
  pkill -f "dashboard --skip-build --no-open --host 127.0.0.1 --port $PORT" 2>/dev/null || true
  for _ in 1 2 3 4 5; do curl -s -o /dev/null "http://127.0.0.1:$PORT/" || break; sleep 1; done
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
     Session token : $(token)
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
  update) put_web
          # 파일 첨부 플러그인이 새로 생기거나 바뀌었으면 서버를 다시 켜야 적용됨
          before="$({ G sh -c "cat '$PLUGIN_GUEST/dashboard/plugin_api.py' '$PLUGIN_GUEST/dashboard/manifest.json' 2>/dev/null" || true; } | cksum)"
          put_plugin
          after="$({ G sh -c "cat '$PLUGIN_GUEST/dashboard/plugin_api.py' '$PLUGIN_GUEST/dashboard/manifest.json' 2>/dev/null" || true; } | cksum)"
          enable_plugin && before="(새로 켬)"
          if [ "$before" != "$after" ] && running; then say "파일 첨부 기능 설치 → 서버 재시작"; stop >/dev/null; start >/dev/null; fi
          say "화면 파일 갱신 완료 → 앱 다시 열기(브라우저는 새로고침)" ;;
  notify-setup) notify_setup; say "답변 알림 설정 완료 — 서버 재시작 후 적용"; running && { stop; start; } ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  remote-on) remote_on ;;
  remote-off) remote_off ;;
  password) pw="$(new_password)"; stop >/dev/null; start >/dev/null; echo "새 비밀번호: $pw  (아이디 fold) — 서버 재시작 완료, 이 비밀번호로 로그인" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
