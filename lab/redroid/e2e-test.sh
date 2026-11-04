#!/usr/bin/env bash
# lab/redroid/e2e-test.sh — redroid(진짜 안드로이드) 위 Termux에서 키트 전체 동작을 종단 검증
#   확인창 '예/아니오'는 호스트가 uiautomator로 화면을 읽어 직접 탭한다 (사람 대신).
set -uo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$LAB/lib.sh"
adb_root
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { echo "OK   $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
out()  { AS cat "$TH/.lab/$1.log" 2>/dev/null; }
mk()   { printf '%s\n' "$2" > "$WORK/$1.sh"; }   # mk <name> <script>
MODE="$(AS cat "$TH/.hermes-bridge/mode" 2>/dev/null || echo apt)"
H=hermes; [ "$MODE" = proot ] && H=hermes-proot
YES='^(Yes|YES|예|확인|OK)$'; NO='^(No|NO|아니요|아니오|취소|Cancel)$'
AS input keyevent KEYCODE_WAKEUP; AS am start -n com.termux/.app.TermuxActivity >/dev/null

echo "== Hermes 설치 ($MODE)"
mk ver "$H --version"
tx_run ver "$WORK/ver.sh" 300 >/dev/null && ok "$H --version: $(out ver | head -1)" || bad "$H --version"
mk cfg "$H config get approvals.mode; $H config get approvals.deny"
tx_run cfg "$WORK/cfg.sh" 300 >/dev/null
out cfg | grep -q manual && out cfg | grep -q 'termux-' && ok "승인 manual + deny 규칙 적용" || { bad "하드닝 설정"; out cfg; }

echo "== 폰 기능 (Termux:API, 실제 안드로이드)"
mk bat 'phone battery'
tx_run bat "$WORK/bat.sh" 120 >/dev/null; out bat | grep -q percentage && ok "battery (allow)" || { bad "battery"; out bat; }
mk notif 'phone notify "Hermes lab" "e2e 알림 테스트"'
tx_run notif "$WORK/notif.sh" 120 >/dev/null
AS dumpsys notification --noredact | grep -q 'Hermes lab' && ok "notify → 안드로이드 알림 생성" || bad "notify"
mk pol 'phone help'
tx_run pol "$WORK/pol.sh" 60 >/dev/null; out pol | grep -q 'adb-shell=deny' && ok "정책 조회" || bad "정책 조회"

echo "== 화면 확인창 (confirm)"
mk cset 'phone clipboard-set "lab-secret-123"'; tx_run cset "$WORK/cset.sh" 60 >/dev/null
mk cget1 'phone clipboard-get'; tx_start cget1 "$WORK/cget1.sh"
if tap_text "$NO" 40; then
  tx_wait cget1 90 >/dev/null; out cget1 | grep -q 'did not approve' && ! out cget1 | grep -q lab-secret \
    && ok "확인창 '아니오' → 거부, 데이터 미노출" || { bad "거부 처리"; out cget1; }
else bad "확인창이 화면에 나타나지 않음 (SYSTEM_ALERT_WINDOW 확인)"; fi

mk cget2 'phone clipboard-get'; tx_start cget2 "$WORK/cget2.sh"
sleep 4
mk lockbat 'phone battery'; tx_start lockbat "$WORK/lockbat.sh"     # 확인창 대기 중 다른 요청
sleep 8
tx_done lockbat && bad "전역 잠금: 확인창 대기 중 다른 동작이 실행됨" || ok "전역 잠금: 확인창 대기 중 다른 동작 대기"
if tap_text "$YES" 40; then
  tx_wait cget2 90 >/dev/null; out cget2 | grep -q 'lab-secret-123' && ok "확인창 '예' → 실행" || { bad "승인 처리"; out cget2; }
else bad "확인창(2) 미표시"; fi
tx_wait lockbat 90 >/dev/null; out lockbat | grep -q percentage && ok "잠금 해제 후 대기 동작 완료" || bad "잠금 해제"

echo "== 시스템 조작 (Termux의 adb → 자기 자신)"
mk adbst 'phone adb-status'
tx_run adbst "$WORK/adbst.sh" 120 >/dev/null; out adbst | grep -q 'device' && ok "adb-status" || { bad "adb-status"; out adbst; }
mk shot 'phone adb-screenshot'; tx_start shot "$WORK/shot.sh"
tap_text "$YES" 60 || true
tx_wait shot 120 >/dev/null
P="$(out shot | jq -r '.path // empty' 2>/dev/null)"
if [ -n "$P" ] && [ "$(AS stat -c %s "$TH/work/$P" 2>/dev/null || echo 0)" -gt 1000 ]; then
  A pull "$TH/work/$P" "$LAB/last-screenshot.png" >/dev/null && ok "adb-screenshot → $LAB/last-screenshot.png"
else bad "adb-screenshot"; out shot; fi
mk ash 'phone adb-shell id'
tx_run ash "$WORK/ash.sh" 60 >/dev/null; out ash | grep -q 'denied by policy' && ok "adb-shell 차단" || bad "adb-shell 차단"

echo "== 감사 로그"
AS cat "$TH/.hermes-bridge/audit.log" | tail -12
AS cat "$TH/.hermes-bridge/audit.log" | grep -q REJECTED && ok "감사 로그에 거부 기록" || bad "감사 로그"

# 결과물 수집 (CI 아티팩트용)
ART="$LAB/artifacts"; mkdir -p "$ART"
for f in $(AS ls "$TH/.lab/" 2>/dev/null | grep '\.log$'); do A pull "$TH/.lab/$f" "$ART/$f" >/dev/null 2>&1; done
AS cat "$TH/.hermes-bridge/audit.log" > "$ART/audit.log" 2>/dev/null
A exec-out screencap -p > "$ART/final-screen.png" 2>/dev/null
[ -f "$LAB/last-screenshot.png" ] && cp "$LAB/last-screenshot.png" "$ART/"

echo; echo "RESULT: PASS=$PASS FAIL=$FAIL  (mode=$MODE)"
[ $FAIL -eq 0 ]
