#!/usr/bin/env bash
# lab/redroid/apps-e2e.sh — 실제 앱을 Hermes Hands 로 조작하는 시나리오 테스트 (+ 녹화)
#   에이전트가 쓰는 것과 똑같은 명령(phone hands-*)만 사용: 화면 읽기 → 요소 찾기 → 누르기/입력 → 결과 확인
#   시나리오: ① 설정 다크 모드 켜기 ② 계산기 12+34 ③ 메모 앱에 메모 쓰고 다시 열어 확인 ④ 위키백과 검색
#             ⑤ 게임 2048 — 버튼이 아닌 직접 스와이프 조작  ⑥ 인터넷 브라우저 — 주소 입력·이동·링크 누르기
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
jqv()     { grep '^{' <<<"$2" | tail -1 | jq -r "$1" 2>/dev/null; }   # 마지막 JSON 줄만

# ---- 에이전트처럼: 화면 읽기 / 요소 찾기 / 누르기 ----
D=""; I=""
dump()  { D="$(ph "d$((++NC))" hands-dump | grep '^{' | tail -1)"; }
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
type_i()   { local r; r="$(ph "t$((++NC))" hands-type "$@")"; [ "$(jqv .ok "$r")" = true ] || { echo "     type → $r"; return 1; }; }
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
GAME=""   # F-Droid 에서 '2048' 검색 → 받아지는 첫 게임
CANDS="$(curl -fsSL -m 60 'https://search.f-droid.org/?q=2048&lang=en' 2>/dev/null | grep -oE '/en/packages/[A-Za-z0-9_.]+' | sed 's|.*/||' | awk '!s[$0]++' | head -5)"
echo "     F-Droid 검색 '2048' → $(echo $CANDS)"
for p in $CANDS; do fdroid_install "$p" && { GAME="$p"; break; }; done
[ -n "$GAME" ] && ok "앱 설치: 게임 $GAME" || bad "앱 설치: 2048 게임"
BROWSER=""  # 시스템 WebView 기반 가벼운 오픈소스 브라우저 → 안 되면 Firefox 계열
for p in acr.browser.lightning com.stoutner.privacybrowser.standard org.mozilla.fennec_fdroid; do fdroid_install "$p" && { BROWSER="$p"; break; }; done
[ -n "$BROWSER" ] && ok "앱 설치: 브라우저 $BROWSER" || bad "앱 설치: 브라우저"
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

echo "== 세션 시작 (설정·계산기·메모·위키백과·2048·브라우저만 허용, 15분)"
ph_bg st hands-start 15 "com.android.settings,org.fossify.math,org.fossify.notes,org.wikipedia,${GAME:-com.tpcstld.twozerogame},${BROWSER:-acr.browser.lightning}" "실제 앱 6개 조작 테스트"
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
  for k in 1 2 3 4 5; do        # 검색 입력 칸이 나올 때까지: 팝업 닫기 → 검색창 → 하단 Search 탭
    dump; has '.edit == true' && break
    i="$(idx "$(T '^(Close|Not now|No thanks|닫기|나중에)$')")"
    [ -n "$i" ] || i="$(idx "$(T '^(Search Wikipedia|위키백과 검색)')")"
    [ -n "$i" ] || i="$(idx '((.id // "") | test("nav_tab_search$"))')"
    [ -n "$i" ] || break
    echo "     (누름: $(jq -r ".nodes[$i].text // .nodes[$i].desc // .nodes[$i].id" <<<"$D"))"; click_i "$i"; sleep 1.5
  done
  if true; then
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
print(hashlib.md5(b[hdr+w*4*int(h*.30):hdr+w*4*int(h*.85)]).hexdigest()[:12])' 2>>"$ART/board_sig.err"
}
score_sig() { dump; jq -r '[.nodes[] | (.text // "") | select(test("^[0-9]+$"))] | join(",")' <<<"$D"; }
echo "== ⑤ 게임 2048 → 스와이프로 직접 플레이"
if [ -n "$GAME" ] && launch "$GAME"; then
  sleep 3; dismiss
  # 메뉴 화면이면 '새 게임' 누르기 (에이전트처럼 화면을 보고 판단)
  if tap_el "$(T '^(START NEW GAME|New game|Play|Start|새 게임|시작)$')"; then echo "     ('새 게임' 누름)"; sleep 2; fi
  dump; show 15
  snap "game-start"
  read -r SW SH < <(AS wm size | grep -oE '[0-9]+x[0-9]+' | tail -1 | tr 'x' ' ')
  GX=$((SW/2)); GY=$((SH*57/100)); R=$((SW/4))
  MOVED=0; SWIPES=0; prev="$(board_sig)"; echo "     판 해시 시작: '$prev'  숫자: $(score_sig)"
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
    if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then MOVED=$((MOVED+1)); echo "     스와이프 $dir → 판 움직임 ($cur)"
    else echo "     스와이프 $dir → 변화 없음(그 방향으로 못 움직이는 판일 수 있음)"; fi
    prev="$cur"
  done
  snap "game-after"
  echo "     스와이프 성공 $SWIPES/10, 판이 바뀐 횟수 $MOVED, 끝 숫자: $(score_sig)"; head -3 "$ART/board_sig.err" 2>/dev/null
  [ $SWIPES -eq 10 ] && ok "⑤ 스와이프 제스처 10회 실행" || bad "⑤ 스와이프 실행 ($SWIPES/10)"
  [ $MOVED -ge 5 ] && ok "⑤ 게임 판이 실제로 움직임 ($MOVED/10회)" || bad "⑤ 게임 반응 ($MOVED/10회)"
else bad "⑤ 2048 실행"; fi

# ---------- ⑥ 인터넷 브라우저: 주소 입력 → 이동 → 페이지 읽기 → 링크 누르기 ----------
echo "== ⑥ 브라우저 → example.com 열기 → 링크 눌러 다음 페이지"
if [ -n "$BROWSER" ] && launch "$BROWSER"; then
  sleep 3; dismiss
  for k in 1 2 3 4; do         # 주소창(입력 칸)이 보일 때까지: 첫 실행 안내 넘기기 / 주소창 누르기
    dump; has '.edit == true' && break
    i="$(idx "$(T '^(Skip|Continue|Done|Got it|OK|Not now|No thanks|Close|Start browsing|Accept|Agree)$')")"
    [ -n "$i" ] || i="$(idx "$(T '^(Search or type|Search or enter|Enter URL|Search|주소)')")"
    [ -n "$i" ] || i="$(idx '((.id // "") | test("url|search|address|location"; "i"))')"
    [ -n "$i" ] || break
    echo "     (누름: $(jq -r ".nodes[$i].text // .nodes[$i].desc // .nodes[$i].id" <<<"$D"))"; click_i "$i"; sleep 1.5
  done
  show 20
  # 주소창 우선: 웹페이지 안 검색칸이 아닌, 브라우저 자체 입력칸(id 있음: url/search/address)
  dump; I="$(idx '.edit == true and ((.id // "") | test("url|search|address|location"; "i"))')"
  [ -n "$I" ] || I="$(idx '.edit == true')"
  echo "     주소창: [$I] $(jq -r ".nodes[${I:-0}].id // .nodes[${I:-0}].cls" <<<"$D")"
  if [ -n "$I" ]; then
    if type_i "$I" "https://example.com" enter; then
      ok "⑥ 주소 입력 + Enter(이동)"
      LOADED=0; for k in 1 2 3 4 5 6; do sleep 3; dump; has "$(T 'This domain is for use')" && { LOADED=1; break; }; done
      snap "browser-example"
      if [ $LOADED = 1 ]; then
        ok "⑥ 웹페이지 본문 읽기 ('This domain is for use…')"
        if tap_el "$(T '^(More information|Learn more|Find out more|IANA)')" 3; then   # 링크가 아래에 있으면 스크롤하며 찾기
          NEXT=0; for k in 1 2 3 4 5 6; do sleep 3; dump; has "$(T 'IANA|Internet Assigned Numbers|example domains')" && { NEXT=1; break; }; done
          snap "browser-link"
          [ $NEXT = 1 ] && ok "⑥ 웹페이지 링크 눌러 다음 페이지 이동 (iana.org)" || { bad "⑥ 링크 이동 확인"; show 25; }
        else bad "⑥ 페이지 안 링크 못 찾음"; show 25; fi
      else bad "⑥ 페이지 로드 확인"; show 25; fi
    else bad "⑥ 주소 입력"; fi
  else bad "⑥ 주소창 못 찾음"; fi
else bad "⑥ 브라우저 실행"; fi

# ---------- ⑧ 코드처럼 읽고 → 스크립트 한 번에 실행 → 레시피로 저장·재실행 (Aside 방식) ----------
echo "== ⑧ hands-read + hands-run (여러 단계를 한 번에) + 레시피"
OUT="$(ph rd1 hands-launch org.fossify.math >/dev/null; ph rd2 hands-read)"
echo "$OUT" | head -8 | sed 's/^/     /'
grep -q '#btn_7 {click}' <<<"$OUT" && ok "⑧ 화면을 코드처럼 읽기 (hands-read, $(wc -l <<<"$OUT")줄)" || bad "⑧ hands-read"
cat > "$WORK/calc-mul.json" <<'J'
[ {"do":"launch","package":"org.fossify.math"},
  {"do":"click","match":"^(OK|Got it)$","optional":true},
  {"do":"click","match":"btn_clear$"},
  {"do":"click","match":"btn_7$"}, {"do":"click","match":"btn_multiply$"}, {"do":"click","match":"btn_8$"},
  {"do":"click","match":"btn_equals$"},
  {"do":"assert","match":"^56$"} ]
J
push_termux "$WORK/calc-mul.json" "work/recipes/calc-mul.json" 600
T0=$(date +%s); R="$(ph run1 hands-run @calc-mul)"; T1=$(date +%s)
echo "     $(grep '^{' <<<"$R" | tail -1 | jq -c '{ok,done,error}' 2>/dev/null)  (${T1}-${T0}=$((T1-T0))초)"
[ "$(jqv .ok "$R")" = true ] && [ "$(jqv .done "$R")" = 8 ] && ok "⑧ 레시피 한 번 호출로 8단계 실행 → 7×8=56 확인 ($((T1-T0))초)" || { bad "⑧ hands-run 레시피"; echo "$R" | tail -3; }
snap "recipe-56"
R="$(ph run2 hands-run '[{"do":"launch","package":"org.fossify.math"},{"do":"click","match":"btn_clear$"},{"do":"assert","match":"^999$"}]')"
[ "$(jqv .ok "$R")" = false ] && [[ "$R" == *"step 2"* ]] && ok "⑧ 확인(assert) 실패 시 그 단계에서 멈추고 보고" || { bad "⑧ assert 실패 보고"; echo "$R" | tail -2; }
R="$(ph run3 hands-run '[{"do":"launch","package":"com.android.calculator2"}]')"
[[ "$R" == *"not in session"* ]] && ok "⑧ 스크립트도 허용 안 된 앱은 실행 못 함" || { bad "⑧ 스크립트 범위 검사"; echo "$R" | tail -2; }

# ---------- ⑦ 설정 직접 변경: 화면 터치 없이 값만 바꾸기 (phone set) ----------
echo "== ⑦ 설정 직접 변경 (터치 없이)"
ph sp0 hands-stop >/dev/null      # 화면 조작 세션과 무관함을 보여주려고 먼저 종료
S="$(ph g0 settings)"; echo "     현재: $(grep '^{' <<<"$S" | tail -1 | jq -c '{dark,brightness,screen_timeout_ms,auto_rotate,font_scale,stay_awake,dnd_zen_mode}' 2>/dev/null)"
setchk() {  # setchk 설명 '확인할 셸 명령' 기대정규식 -- phone set 인자들
  local desc="$1" chk="$2" want="$3"; shift 4
  local r got; r="$(ph "set$((++NC))" set "$@")"; got="$(AS $chk 2>/dev/null | tr -d '\r')"
  if [ "$(jqv .ok "$r")" = true ] && [[ "$got" =~ $want ]]; then ok "⑦ $desc → 실제 값 '$got'"
  else bad "⑦ $desc (응답 $(grep '^{' <<<"$r" | tail -1), 실제 '$got')"; fi
}
setchk "다크 모드 끄기"      "cmd uimode night"                        "no"   -- dark off
setchk "다크 모드 켜기"      "cmd uimode night"                        "yes"  -- dark on
setchk "밝기 77"             "settings get system screen_brightness"   "^77$" -- brightness 77
setchk "화면 꺼짐 45초"      "settings get system screen_off_timeout"  "^45000$" -- timeout 45
setchk "자동 회전 끄기"      "settings get system accelerometer_rotation" "^0$" -- rotate off
setchk "글자 크기 1.15"      "settings get system font_scale"          "^1\.15$" -- font 1.15
setchk "애니메이션 0.5배"    "settings get global animator_duration_scale" "^0\.5$" -- animations 0.5
setchk "충전 중 화면 켜둠"   "settings get global stay_on_while_plugged_in" "^7$" -- stay-awake on
setchk "방해 금지 켜기"      "settings get global zen_mode"            "^[1-3]$" -- dnd on
setchk "방해 금지 끄기"      "settings get global zen_mode"            "^0$" -- dnd off
R="$(ph setx set brightness 999)"; [[ "$R" == *"범위"* ]] && ok "⑦ 범위 밖 값 거부 (밝기 999)" || bad "⑦ 범위 검사: $R"
R="$(ph sety set 'dark;reboot' on)"; [[ "$R" == *"모르는 설정"* ]] && ok "⑦ 이상한 이름 거부 (명령 끼워넣기 차단)" || bad "⑦ 이름 검사: $R"
AS settings put system font_scale 1.0; AS settings put global animator_duration_scale 1; AS settings put global window_animation_scale 1; AS settings put global transition_animation_scale 1
snap "settings-direct"

echo "== 세션 종료"
ph sp hands-stop >/dev/null; sleep 1
S="$(ph st9 hands-status)"; [ "$(jqv .session "$S")" = false ] && ok "세션 종료 · 보호막 해제" || bad "세션 종료"
snap "done"
rec_stop "$ART/frames"
AS logcat -d -s HermesHands > "$ART/hands-logcat.txt" 2>/dev/null
echo; echo "RESULT: PASS=$PASS FAIL=$FAIL  (실제 앱 조작)"
[ $FAIL -eq 0 ]
