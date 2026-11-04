#!/usr/bin/env bash
# lab/redroid/apps-e2e.sh — 실제 앱을 Hermes Hands 로 조작하는 시나리오 테스트 (+ 녹화)
#   에이전트가 쓰는 것과 똑같은 명령(phone hands-*)만 사용: 화면 읽기 → 요소 찾기 → 누르기/입력 → 결과 확인
#   시나리오: ① 설정 다크 모드 켜기 ② 계산기 12+34 ③ 메모 앱에 메모 쓰고 다시 열어 확인 ④ 위키백과 검색
#             ⑤ 게임 2048 — 버튼이 아닌 직접 스와이프 조작
#   전제: setup-server.sh, install-termux.sh(PLAN=none) 완료, Hermes Hands APK 경로 = $1
set -u
LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$LAB/lib.sh"
APK="${1:?Hermes Hands APK 경로}"
PKG=ai.hermesfold7.hands
ART="${ART_DIR:-$LAB/artifacts-apps}"; mkdir -p "$ART"
WORK="$(mktemp -d)"
export SHOT_DIR="$ART/shots" TX_SHOW=0
PASS=0; FAIL=0; NC=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
adb_root

ph_file() { local f="$WORK/$1.sh"; shift; printf 'phone' > "$f"; for a in "$@"; do printf ' %q' "$a" >> "$f"; done; echo >> "$f"; echo "$f"; }
ph()      { local n="$1"; shift; tx_run "$n" "$(ph_file "$n" "$@")" 150 >/dev/null; AS cat "$TH/.lab/$n.log" 2>/dev/null; }
ph_bg()   { local n="$1"; shift; tx_start "$n" "$(ph_file "$n" "$@")"; }
jqv()     { jq -r "$1" 2>/dev/null <<<"$2" | tail -1; }

# ---- 에이전트처럼: 화면 읽기 / 요소 찾기 / 누르기 ----
D=""; I=""
dump()  { D="$(ph "d$((++NC))" hands-dump)"; }
show()  { jq -r '.nodes[] | "     [\(.i)] \(.cls) \(.text // .desc // "" | .[0:40]) \(.id // "" | sub(".*:id/";"#"))\(if .click then " ·click" else "" end)\(if .edit then " ·edit" else "" end)\(if .checked != null then " ·checked=\(.checked)" else "" end)"' <<<"$D" 2>/dev/null | head -"${1:-30}"; }
T()     { printf '((.text // .desc // "") | test("%s"; "i"))' "$1"; }          # 글자/설명 정규식 필터
idx()   { jq -r "[.nodes[] | select($1)][0].i // empty" <<<"$D" 2>/dev/null; }
has()   { [ -n "$(idx "$1")" ]; }
find_el() {  # find_el <jq필터> [스크롤횟수] → I
  local f="$1" n="${2:-0}" k
  for ((k=0; k<=n; k++)); do
    dump; I="$(idx "$f")"; [ -n "$I" ] && return 0
    [ $k -lt $n ] && ph "s$((++NC))" hands-scroll down >/dev/null
  done
  return 1
}
click_i()  { local r; r="$(ph "c$((++NC))" hands-click "$1")"; [ "$(jqv .ok "$r")" = true ] || { echo "     click $1 → $r"; return 1; }; }
tap_el()   { find_el "$1" "${2:-0}" && click_i "$I"; }
type_i()   { local r; r="$(ph "t$((++NC))" hands-type "$1" "$2")"; [ "$(jqv .ok "$r")" = true ] || { echo "     type → $r"; return 1; }; }
launch()   { local r; r="$(ph "l$((++NC))" hands-launch "$1")"; sleep 2; [ "$(jqv .ok "$r")" = true ] || { echo "     launch → $r"; return 1; }; }
dismiss()  {  # 첫 실행 팝업(안내·권한·평가 요청 등) 닫기
  local k i
  for k in 1 2 3 4; do
    dump; i="$(idx "$(T '^(OK|Got it|Skip|Continue|Close|Not now|No thanks|Later|Accept|Allow|Dismiss|확인|건너뛰기|닫기|나중에|허용)$')")"
    [ -n "$i" ] || return 0
    echo "     (팝업 닫기: $(jq -r ".nodes[$i].text // .nodes[$i].desc" <<<"$D"))"; click_i "$i"; sleep 1
  done
}

# ---------- 0. 실제 앱 설치 (F-Droid 공식 저장소) ----------
fdroid_install() {  # fdroid_install <package>
  local p="$1" j vc f="$WORK/$1.apk"
  local C=(curl -fsSL --retry 5 --retry-delay 20 --retry-all-errors -m 300)
  sleep "${FDROID_GAP:-0}"; FDROID_GAP=15             # F-Droid 요청 제한(연속 요청 시 502/429) 회피
  echo "     F-Droid $p: API HTTP $(curl -s -o /dev/null -w '%{http_code}' "https://f-droid.org/api/v1/packages/$p")"
  # 1순위: F-Droid API / 2순위(API 장애 시): 앱 소개 페이지에 있는 APK 링크
  j="$("${C[@]}" "https://f-droid.org/api/v1/packages/$p" 2>/dev/null)"
  vcs="$(jq -r '.suggestedVersionCode, (.packages[].versionCode)' <<<"$j" 2>/dev/null)"
  [ -n "$vcs" ] || vcs="$("${C[@]}" "https://f-droid.org/en/packages/$p/" 2>/dev/null | grep -oE "${p//./\\.}_[0-9]+\.apk" | grep -oE '_[0-9]+\.apk' | tr -dc '0-9\n')"
  [ -n "$vcs" ] || { echo "     F-Droid 조회 실패: $p"; return 1; }
  for vc in $(awk 'NF && !s[$0]++' <<<"$vcs" | head -6); do
    "${C[@]}" "https://f-droid.org/repo/${p}_${vc}.apk" -o "$f" || continue
    if A install -r -g "$f" >/dev/null 2>&1; then
      echo "     $p (versionCode $vc, sha256 $(sha256sum "$f" | cut -c1-16)…)"; return 0
    fi
  done
  return 1
}
echo "== 0. 실제 앱 설치 + Hermes Hands 연결"
AS cmd uimode night no >/dev/null 2>&1          # 시작 상태: 라이트 모드 (Hands 켜기 전에 바꿔 둠)
for p in org.fossify.math org.fossify.notes org.wikipedia; do fdroid_install "$p" && ok "앱 설치: $p" || bad "앱 설치: $p"; done
GAME=""   # 오픈소스 2048 게임 (첫 번째로 받아지는 것)
for p in com.tpcstld.twozerogame com.uberspot.a2048; do fdroid_install "$p" && { GAME="$p"; break; }; done
[ -n "$GAME" ] && ok "앱 설치: 게임 $GAME" || bad "앱 설치: 2048 게임"
A install -r "$APK" >/dev/null && ok "Hermes Hands 설치" || bad "Hermes Hands 설치"
AS settings put secure enabled_accessibility_services "$PKG/$PKG.HandsService"
AS settings put secure accessibility_enabled 1
TOKEN=""; for _ in $(seq 1 30); do TOKEN="$(AS cat /data/data/$PKG/files/token 2>/dev/null)"; [ -n "$TOKEN" ] && break; sleep 1; done
printf '%s' "$TOKEN" > "$WORK/tok"; push_termux "$WORK/tok" ".hermes-bridge/hands.token" 600
READY=0   # 접근성 서비스가 뜬 뒤 로컬 소켓이 열릴 때까지 대기
for k in $(seq 1 15); do S="$(ph "w$k" hands-status)"; [ "$(jqv .ok "$S")" = true ] && { READY=1; break; }; sleep 2; done
[ $READY = 1 ] && ok "브리지 ↔ Hermes Hands 연결" || { bad "Hermes Hands 응답 없음"; echo "$S"; }
AS input keyevent KEYCODE_HOME

rec_start "$ART/frames"
trap 'rec_stop "$ART/frames"; rm -rf "$WORK"' EXIT

echo "== 세션 시작 (설정·계산기·메모·위키백과·2048만 허용, 15분)"
ph_bg st hands-start 15 "com.android.settings,org.fossify.math,org.fossify.notes,org.wikipedia,${GAME:-com.tpcstld.twozerogame}" "실제 앱 5개 조작 테스트"
tap_text '^(Yes|YES|예|확인|OK)$' 40 "session-confirm" || bad "세션 확인창 미표시"
tx_wait st 60 >/dev/null; S="$(AS cat "$TH/.lab/st.log")"
[ "$(jqv .ok "$S")" = true ] && ok "세션 승인" || { bad "세션 시작"; echo "$S"; AS logcat -d -s HermesHands | tail -20; }

# ---------- ① 설정: 다크 모드 켜기 ----------
echo "== ① 설정 → 디스플레이 → 다크 모드 켜기"
if launch com.android.settings; then
  dump; show 12
  if tap_el "$(T '^(Display|디스플레이)')" 4; then
    sleep 1
    if tap_el "$(T '^(Dark theme|Dark mode|다크 모드|어두운 테마)')" 3; then
      sleep 1; dump
      # 다크 모드 상세 화면이면 'Use Dark theme' 스위치까지 누름 (에이전트처럼 화면을 보고 판단)
      if has '(.checked == false) and ((.id // "") | test("switch"))'; then
        tap_el "$(T '^(Use Dark theme|다크 모드 사용|어두운 테마 사용)')" || tap_el '(.checked == false) and ((.id // "") | test("switch"))'
      fi
      sleep 2; snap "settings-dark"
      AS cmd uimode night 2>/dev/null | grep -qi 'yes' && ok "① 다크 모드 켜짐 (시스템 설정 확인)" \
        || { bad "① 다크 모드 (설정값 안 바뀜: $(AS cmd uimode night 2>/dev/null))"; dump; show; }
    else bad "① '다크 모드' 항목 못 찾음"; show; fi
  else bad "① '디스플레이' 항목 못 찾음"; show; fi
else bad "① 설정 실행"; fi

# ---------- ② 계산기: 12 + 34 = 46 ----------
echo "== ② 계산기 → 12 + 34 ="
if launch org.fossify.math; then
  dismiss; show 40
  KEYS_OK=1
  for k in 1 2 + 3 4 =; do
    case "$k" in
      +) f="$(T '^([+]|plus)$')" ;;
      =) f="$(T '^(=|equals)$')" ;;
      *) f="((.text // .desc // \"\") == \"$k\")" ;;
    esac
    tap_el "$f" || { KEYS_OK=0; echo "     '$k' 버튼 못 찾음"; break; }
  done
  sleep 1; dump; snap "calculator-46"
  RES="$(jq -r '[.nodes[] | select((.id // "") | test("result$"))][0].text // empty' <<<"$D")"
  echo "     결과 칸: '$RES'"
  if [ $KEYS_OK = 1 ] && { [[ "$RES" =~ ^46$ ]] || has '((.text // "") == "46")'; }; then ok "② 계산기 12+34 = 46"
  else bad "② 계산기 결과"; show 40; fi
else bad "② 계산기 실행"; fi

# ---------- ③ 메모: 쓰고 → 앱 닫고 → 다시 열어서 확인 ----------
MEMO="헤르메스가 쓴 메모 $(date +%H%M%S)"
echo "== ③ 메모 → '$MEMO' 저장 후 다시 열어 확인"
if launch org.fossify.notes; then
  dismiss; show 25
  if find_el '.edit == true'; then
    type_i "$I" "$MEMO"; sleep 1; dump; snap "notes-typed"
    has "$(T "$MEMO")" && ok "③ 메모 입력 (화면에 글자 보임)" || { bad "③ 메모 입력"; show 10; }
    ph "h$((++NC))" hands-home >/dev/null; sleep 4    # 앱이 백그라운드로 가며 저장할 시간
    AS am force-stop org.fossify.notes                 # 앱 완전 종료 → 저장됐는지 확인
    launch org.fossify.notes; dismiss
    if has "$(T "$MEMO")"; then ok "③ 앱을 다시 열어도 메모가 남아 있음"; snap "notes-reopened"
    else bad "③ 메모 저장 확인"; show 25; fi
  else bad "③ 입력 칸 못 찾음"; fi
else bad "③ 메모 실행"; fi

# ---------- ④ 위키백과: 'Seoul' 검색해서 문서 열기 (인터넷 필요) ----------
echo "== ④ 위키백과 → 'Seoul' 검색 → 문서 열기"
if launch org.wikipedia; then
  sleep 2
  for k in 1 2 3 4 5 6 7; do   # 첫 실행 안내 화면 넘기기 (Skip / Forward / Get started …)
    dump; has "$(T '^(Search Wikipedia|위키백과 검색)')" && break
    i="$(idx "$(T '^(Skip|Get started|Continue|Done|Forward|건너뛰기|시작하기|계속)$')")"
    [ -n "$i" ] || i="$(idx "$(T '^(OK|Got it|Not now|No thanks|Close|Dismiss|확인|닫기|나중에)$')")"
    [ -n "$i" ] || break
    echo "     (안내 화면: $(jq -r ".nodes[$i].text // .nodes[$i].desc" <<<"$D") 누름)"; click_i "$i"; sleep 1.5
  done
  show 25
  if tap_el "$(T '^(Search Wikipedia|위키백과 검색|Search)')" 1; then
    sleep 1
    if find_el '.edit == true'; then
      type_i "$I" "Seoul"; sleep 4
      if tap_el "$(T '^Seoul$')" || tap_el "$(T '^Seoul')"; then
        sleep 6; dump; snap "wikipedia-seoul"
        if has "$(T 'capital|South Korea|대한민국')"; then ok "④ 위키백과 'Seoul' 문서 열림"
        else bad "④ 문서 내용 확인"; show 30; fi
      else bad "④ 검색 결과 못 찾음"; show 30; fi
    else bad "④ 검색 입력 칸 못 찾음"; show 30; fi
  else bad "④ 검색창 못 찾음"; fi
else bad "④ 위키백과 실행"; fi

# ---------- ⑤ 게임 2048: 화면을 직접 스와이프해서 플레이 ----------
#   버튼이 없어서 '누르기'로는 못 하는 조작 → 좌표 제스처(hands-swipe). 판이 바뀌었는지는 화면 픽셀로 확인
board_sig() {  # 화면 가운데(판 영역) 픽셀의 해시 — 상태바 시계 변화는 제외
  A exec-out screencap 2>/dev/null | python3 -c '
import sys,hashlib,struct
b=sys.stdin.buffer.read(); w,h=struct.unpack("<II",b[:8]); hdr=len(b)-w*h*4
print(hashlib.md5(b[hdr+w*4*int(h*.30):hdr+w*4*int(h*.85)]).hexdigest())'
}
echo "== ⑤ 게임 2048 → 스와이프로 직접 플레이"
if [ -n "$GAME" ] && launch "$GAME"; then
  sleep 3; dismiss; show 15
  snap "game-start"
  read -r SW SH < <(AS wm size | grep -oE '[0-9]+x[0-9]+' | tail -1 | tr 'x' ' ')
  GX=$((SW/2)); GY=$((SH*57/100)); R=$((SW/4))
  MOVED=0; SWIPES=0; prev="$(board_sig)"
  for dir in up right down left up right down left left down; do
    case $dir in
      up)    a=($GX $((GY+R)) $GX $((GY-R))) ;;
      down)  a=($GX $((GY-R)) $GX $((GY+R))) ;;
      left)  a=($((GX+R)) $GY $((GX-R)) $GY) ;;
      right) a=($((GX-R)) $GY $((GX+R)) $GY) ;;
    esac
    r="$(ph "g$((++NC))" hands-swipe "${a[@]}" 250)"
    [ "$(jqv .ok "$r")" = true ] && SWIPES=$((SWIPES+1)) || echo "     swipe $dir → $r"
    sleep 0.6; cur="$(board_sig)"
    if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then MOVED=$((MOVED+1)); echo "     스와이프 $dir → 판 움직임"
    else echo "     스와이프 $dir → 변화 없음(그 방향으로 못 움직이는 판일 수 있음)"; fi
    prev="$cur"
  done
  snap "game-after"
  echo "     스와이프 성공 $SWIPES/10, 판이 바뀐 횟수 $MOVED"
  [ $SWIPES -eq 10 ] && ok "⑤ 스와이프 제스처 10회 실행" || bad "⑤ 스와이프 실행 ($SWIPES/10)"
  [ $MOVED -ge 5 ] && ok "⑤ 게임 판이 실제로 움직임 ($MOVED/10회)" || bad "⑤ 게임 반응 ($MOVED/10회)"
else bad "⑤ 2048 실행"; fi

echo "== 세션 종료"
ph sp hands-stop >/dev/null; sleep 1
S="$(ph st9 hands-status)"; [ "$(jqv .session "$S")" = false ] && ok "세션 종료 · 보호막 해제" || bad "세션 종료"
snap "done"
rec_stop "$ART/frames"
AS logcat -d -s HermesHands > "$ART/hands-logcat.txt" 2>/dev/null
echo; echo "RESULT: PASS=$PASS FAIL=$FAIL  (실제 앱 조작)"
[ $FAIL -eq 0 ]
