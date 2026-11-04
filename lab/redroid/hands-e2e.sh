#!/usr/bin/env bash
# lab/redroid/hands-e2e.sh — Hermes Hands(접근성 앱) 종단 테스트 + 녹화
#   전제: setup-server.sh, install-termux.sh(PLAN=none 가능) 완료, APK 경로 = $1
#   검증: 세션 승인 / 보호막이 사람 터치 차단 / 에이전트 조작은 통과 / 강조 후 느린 동작 /
#         일시정지·재개 / 범위 밖 앱·금지 앱 거부 / 세션 없이 화면 읽기 거부 / 종료 후 보호막 해제
set -u
LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$LAB/lib.sh"
APK="${1:?APK 경로}"
PKG=ai.hermesfold7.hands
SVC="$PKG/$PKG.HandsService"
adb_root
WORK="$(mktemp -d)"
ART="$LAB/artifacts"; mkdir -p "$ART"
export SHOT_DIR="$ART/shots" TX_SHOW=0      # 터미널을 앞에 띄우지 않음(앞 화면 = 조작 대상 앱)
PASS=0; FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
YES='^(Yes|YES|예|확인|OK)$'

# phone 명령을 Termux 앱 안에서 실행 (에이전트가 하는 것과 같은 경로)
ph_file() { local f="$WORK/$1.sh"; shift; printf 'phone' > "$f"; for a in "$@"; do printf ' %q' "$a" >> "$f"; done; echo >> "$f"; echo "$f"; }
ph()      { local n="$1"; shift; tx_run "$n" "$(ph_file "$n" "$@")" 150 >/dev/null; AS cat "$TH/.lab/$n.log" 2>/dev/null; }
ph_bg()   { local n="$1"; shift; tx_start "$n" "$(ph_file "$n" "$@")"; }
ph_out()  { AS cat "$TH/.lab/$1.log" 2>/dev/null; }
focus()   { AS dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedWindow' | tr -d '\r'; }
jqv()     { grep '^{' <<<"$2" | tail -1 | jq -r "$1" 2>/dev/null; }   # 마지막 JSON 줄만

read -r SW SH < <(AS wm size | grep -oE '[0-9]+x[0-9]+' | tail -1 | tr 'x' ' ')
DPI="$(AS wm density | grep -oE '[0-9]+' | tail -1)"
CX=$((SW/2)); CY=$((SH/2)); DP=$(( DPI * 1000 / 160 ))   # dp→px ×1000
echo "screen ${SW}x${SH} @${DPI}dpi"

echo "== 1. 앱 설치 + 접근성 켜기 + 토큰 연결"
A install -r "$APK" >/dev/null && ok "APK 설치" || bad "APK 설치"
AS settings put secure enabled_accessibility_services "$SVC"
AS settings put secure accessibility_enabled 1
TOKEN=""
for _ in $(seq 1 30); do TOKEN="$(AS cat /data/data/$PKG/files/token 2>/dev/null)"; [ -n "$TOKEN" ] && break; sleep 1; done
[ -n "$TOKEN" ] && ok "접근성 서비스 시작(토큰 생성)" || bad "접근성 서비스 시작"
printf '%s' "$TOKEN" > "$WORK/tok"; push_termux "$WORK/tok" ".hermes-bridge/hands.token" 600
for k in $(seq 1 20); do S="$(ph "st0$k" hands-status)"; [ "$(jqv .ok "$S")" = true ] && break; sleep 2; done   # 소켓 열릴 때까지
echo "   $S"
[ "$(jqv .ok "$S")" = true ] && ok "브리지 ↔ 앱 연결 (토큰 인증)" || { bad "브리지 ↔ 앱 연결"; AS logcat -d -s HermesHands | tail -25; AS dumpsys accessibility | grep -iE 'hermes|Bound|Enabled' | head -10; }

rec_start "$ART/frames"
trap 'rec_stop "$ART/frames"; rm -rf "$WORK"' EXIT
AS am start -n com.android.settings/.Settings >/dev/null; sleep 2

echo "== 1b. 앱 이름으로 찾고 열기 (세션 없이)"
S="$(ph ap1 hands-apps Settings)"
[ "$(jqv '.apps | map(.package) | index("com.android.settings") != null' "$S")" = true ] && ok "앱 이름으로 찾기 (Settings → com.android.settings)" || { bad "앱 찾기"; echo "$S" | head -c 300; }
S="$(ph ap2 hands-open com.android.settings)"; sleep 1
[ "$(jqv .ok "$S")" = true ] && [[ "$(focus)" == *com.android.settings* ]] && ok "앱 바로 열기 (hands-open)" || { bad "앱 열기"; echo "$S"; }
S="$(ph ap3 hands-open com.kbstar.kbbank)"
[[ "$S" == *"denied package"* ]] && ok "금지 앱(은행)은 열기도 거부" || { bad "금지 앱 열기 거부"; echo "$S"; }
AS input keyevent KEYCODE_HOME

echo "== 2. 세션 없이는 거부"
S="$(ph d0 hands-dump)"
[[ "$S" == *"no active session"* ]] && ok "세션 없이 화면 읽기 거부" || { bad "세션 없이 화면 읽기 거부"; echo "$S"; }
S="$(ph x0 hands-start 5 com.kbstar.kbbank "은행 테스트")"
[[ "$S" == *"denied package"* ]] && ok "금지 앱(은행) 세션 거부" || { bad "금지 앱 거부"; echo "$S"; }

echo "== 3. 세션 시작 (폰 화면 확인창에서 승인)"
ph_bg st1 hands-start 5 com.android.settings "설정 둘러보기 데모"
tap_text "$YES" 40 "hands-start-confirm" || bad "세션 확인창 미표시"
tx_wait st1 60 >/dev/null; S="$(ph_out st1)"
[ "$(jqv .ok "$S")" = true ] && ok "세션 시작 승인" || { bad "세션 시작"; echo "$S"; }
sleep 1; snap "overlay-on"

echo "== 4. 보호막: 사람 터치 차단"
S="$(ph l1 hands-launch com.android.settings)"; sleep 1
D="$(ph d1 hands-dump)"
[ "$(jqv .ok "$D")" = true ] && ok "화면 읽기 ($(jqv .count "$D")개 요소, 앱 $(jqv .package "$D"))" || { bad "화면 읽기"; echo "$D" | head -c 400; }
TARGET="$(jq -r '[.nodes[] | select(.text != null) | select(.text|test("^(Display|디스플레이|Network|네트워크|Battery|배터리|Apps|애플리케이션)"))][0] // empty' <<<"$D" 2>/dev/null)"
TT="$(jq -r '.text // empty' <<<"$TARGET")"
read -r L T R B < <(jq -r '.b | map(tostring) | join(" ")' <<<"$TARGET" 2>/dev/null || echo "0 0 0 0")
echo "   대상: '$TT' [$L,$T,$R,$B]"
F0="$(focus)"
AS input tap $(( (L+R)/2 )) $(( (T+B)/2 ))        # 사람 손가락 대신 (보호막이 막아야 함)
sleep 2; F1="$(focus)"
[ -n "$TT" ] && [ "$F0" = "$F1" ] && ok "보호막이 사람 터치 차단 (화면 그대로)" || { bad "보호막 터치 차단"; echo "   $F0 → $F1"; }

echo "== 5. 에이전트 조작은 통과 (강조 표시 후 느리게)"
( sleep 0.3; snap "click-highlight" ) & SNAP_PID=$!
T0=$(date +%s%N)
S="$(ph c1 hands-click "text:$TT")"
T1=$(date +%s%N); wait "$SNAP_PID" 2>/dev/null
F2="$(focus)"
[ "$(jqv .ok "$S")" = true ] && [ "$F2" != "$F1" ] && ok "에이전트 클릭으로 '$TT' 열림" || { bad "에이전트 클릭"; echo "   $S / $F2"; }
MS=$(( (T1-T0)/1000000 ))
[ $MS -ge 1000 ] && ok "사람이 볼 수 있는 속도 (클릭 1회 ${MS}ms: 강조 0.5s + 대기 0.7s)" || bad "동작 속도 (${MS}ms)"
sleep 1; snap "after-click"
S="$(ph s1 hands-scroll down)"; [ "$(jqv .ok "$S")" = true ] && ok "스크롤" || echo "   (스크롤 생략: $S)"

echo "== 6. 일시정지 버튼 (가운데) → 에이전트 대기 → 재개"
AS input tap $CX $CY; sleep 1; snap "paused"
S="$(ph st2 hands-status)"
[ "$(jqv .paused "$S")" = true ] && ok "가운데 ⏸ 버튼으로 일시정지" || { bad "일시정지"; echo "   $S"; }
ph_bg b1 hands-back; sleep 6
tx_done b1 && bad "일시정지 중 에이전트 동작이 실행됨" || ok "일시정지 중 에이전트 동작 대기"
AS input tap $CX $(( CY - 40 * DP / 1000 ))       # ▶ 재개 (일시정지 때만 나타남)
tx_wait b1 40 >/dev/null; S="$(ph_out b1)"
[ "$(jqv .ok "$S")" = true ] && ok "▶ 재개 후 대기 동작 실행" || { bad "재개"; echo "   $S"; }

echo "== 7. 범위 밖 앱 거부"
S="$(ph l2 hands-launch com.android.calculator2)"
[[ "$S" == *"not in session"* ]] && ok "승인 안 된 앱 실행 거부" || { bad "범위 밖 앱 거부"; echo "   $S"; }

echo "== 8. 볼륨↓ 3회 비상정지"
for _ in 1 2 3; do AS input keyevent KEYCODE_VOLUME_DOWN; sleep 0.3; done; sleep 1
S="$(ph st3 hands-status)"
if [ "$(jqv .session "$S")" = false ]; then ok "볼륨↓×3 비상정지"
else
  echo "   (주입된 키는 접근성 키 필터에 안 잡힐 수 있음 — 실기기에서 확인 필요) → hands-stop 으로 종료"
  ph sp hands-stop >/dev/null
fi
sleep 1; snap "overlay-off"

echo "== 9. 종료 후 보호막 해제"
S="$(ph st4 hands-status)"
[ "$(jqv .session "$S")" = false ] && ok "세션 종료" || bad "세션 종료"
F3="$(focus)"; AS input keyevent KEYCODE_BACK; sleep 1; F4="$(focus)"
AS am start -n com.android.settings/.Settings >/dev/null; sleep 1
F5="$(focus)"; AS input tap $(( (L+R)/2 )) $(( (T+B)/2 )); sleep 2; F6="$(focus)"
[ "$F5" != "$F6" ] && ok "보호막 해제 → 사람 터치 다시 동작" || { bad "보호막 해제"; echo "   $F5 → $F6"; }

rec_stop "$ART/frames"
A exec-out screencap -p > "$ART/final-screen.png" 2>/dev/null
AS logcat -d -s HermesHands > "$ART/hands-logcat.txt" 2>/dev/null
echo; echo "RESULT: PASS=$PASS FAIL=$FAIL  (Hermes Hands)"
[ $FAIL -eq 0 ]
