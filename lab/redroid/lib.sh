# shellcheck shell=bash
# lab/redroid/lib.sh — redroid 안의 Termux를 호스트에서 조종하는 헬퍼 (source 해서 사용)
# 테스트 전용: adb root 권한을 사용합니다. 실제 폰에서는 쓰지 마세요.

SERIAL="${REDROID_SERIAL:-127.0.0.1:5555}"
TPKG=com.termux
TFILES=/data/data/com.termux/files
TH=$TFILES/home
TP=$TFILES/usr

A()  { adb -s "$SERIAL" "$@"; }
AS() { adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
log() { printf '\033[1;35m[lab]\033[0m %s\n' "$*"; }

adb_root() {
  adb connect "$SERIAL" >/dev/null 2>&1 || true
  [ "$(AS id -u)" = 0 ] && return 0
  A root >/dev/null 2>&1 || true; sleep 2
  adb connect "$SERIAL" >/dev/null 2>&1 || true
  [ "$(AS id -u)" = 0 ] || { echo "adb root 실패" >&2; return 1; }
}

termux_uid() { AS stat -c %u "$TFILES" 2>/dev/null; }

# 호스트 파일을 Termux 홈 아래로 복사 (소유자 + SELinux 컨텍스트를 Termux 홈과 동일하게)
push_termux() {  # push_termux <host_src> <dest_rel_to_home> [mode]
  local src="$1" dest="$TH/$2" mode="${3:-600}" uid ctx
  uid="$(termux_uid)"; ctx="$(AS ls -Zd "$TH" | awk '{print $1}')"
  A push "$src" /data/local/tmp/.lab-push >/dev/null
  AS "mkdir -p '$(dirname "$dest")' && cp /data/local/tmp/.lab-push '$dest' && rm /data/local/tmp/.lab-push \
      && chmod $mode '$dest' && chown $uid:$uid '$dest' '$(dirname "$dest")' && chcon '$ctx' '$dest' '$(dirname "$dest")'"
}

# Termux 앱 컨텍스트에서 스크립트 실행 (RUN_COMMAND 인텐트) — 결과는 ~/.lab/<name>.log / .rc
tx_start() {  # tx_start <name> <script_file_on_host>
  local name="$1" f="$2"
  AS rm -f "$TH/.lab/$name.rc" "$TH/.lab/$name.log"
  push_termux "$f" ".lab/$name.sh" 700
  local args=(-n com.termux/com.termux.app.RunCommandService -a com.termux.RUN_COMMAND
    --es com.termux.RUN_COMMAND_PATH "$TP/bin/bash"
    --esa com.termux.RUN_COMMAND_ARGUMENTS "$TH/.lab/runner,$name"
    --es com.termux.RUN_COMMAND_WORKDIR "$TH"
    --ez com.termux.RUN_COMMAND_BACKGROUND true)
  local r
  r="$(adb -s "$SERIAL" shell am start-foreground-service --user 0 "${args[@]}" 2>&1 | tr -d '\r')"
  if [[ "$r" == *Error* || "$r" == *Exception* ]]; then
    r="$(adb -s "$SERIAL" shell am startservice --user 0 "${args[@]}" 2>&1 | tr -d '\r')"
  fi
  [[ "$r" == *Error* || "$r" == *Exception* ]] && { echo "[lab] RUN_COMMAND 실패: $r" >&2; return 1; }
  return 0
}
tx_wait() {   # tx_wait <name> [timeout_sec] → 종료코드 반환, 로그 출력
  local name="$1" t="${2:-1800}" i rc
  for ((i=0; i<t; i+=3)); do
    rc="$(AS cat "$TH/.lab/$name.rc" 2>/dev/null | grep -Eo '^[0-9]+$' || true)"
    [ -n "$rc" ] && break
    sleep 3
  done
  AS cat "$TH/.lab/$name.log" 2>/dev/null | tail -n "${TX_TAIL:-40}"
  [ -n "$rc" ] || { echo "[lab] $name 시간초과"; return 124; }
  return "$rc"
}
tx_run() { tx_start "$1" "$2" && tx_wait "$1" "${3:-1800}"; }
tx_done() { AS cat "$TH/.lab/$1.rc" 2>/dev/null | grep -Eq '^[0-9]+$'; }

# 화면의 UI 요소를 텍스트(정규식)로 찾아 탭 — 확인창 '예/아니오' 자동 응답용
tap_text() {  # tap_text <regex> [timeout_sec]
  local re="$1" t="${2:-30}" i xy
  for ((i=0; i<t; i+=2)); do
    AS uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
    xy="$(AS cat /data/local/tmp/ui.xml | python3 -c '
import sys,re,xml.etree.ElementTree as ET
pat=re.compile(sys.argv[1])
for n in ET.fromstring(sys.stdin.read()).iter("node"):
    if pat.search(n.get("text","")):
        x1,y1,x2,y2=map(int,re.findall(r"\d+",n.get("bounds")))
        print((x1+x2)//2,(y1+y2)//2); break
' "$re" 2>/dev/null)"
    if [ -n "$xy" ]; then AS input tap $xy; return 0; fi
    sleep 2
  done
  return 1
}
screen_has() { AS uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; AS cat /data/local/tmp/ui.xml | grep -q "$1"; }
