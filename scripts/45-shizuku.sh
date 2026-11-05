#!/data/data/com.termux/files/usr/bin/bash
# 45-shizuku.sh — Shizuku 연결: 와이파이에서 한 번 시작해 두면 5G 에서도 '설정 직접 변경'이 동작 (재부팅 전까지)
#   ADB 처럼 셸 권한을 쓰지만 네트워크 포트를 열지 않음. 에이전트는 rish 를 직접 못 씀(보안 규칙) → phone 브리지만 사용.
#
# 준비 (폰에서 한 번):
#   1) Play 스토어에서 'Shizuku' 설치 (개발: RikkaApps)
#   2) 와이파이 연결 → Shizuku 앱 → '무선 디버깅으로 시작' → 안내대로 페어링 → '시작'
#      (폰을 재부팅하면 이 '시작'만 다시 — 와이파이 필요, 그 뒤엔 5G 가능)
#   3) Shizuku 앱 → '터미널 앱에서 Shizuku 사용' → '파일 내보내기' → '다운로드(Download)' 폴더 선택
#   4) Termux 에서: bash ~/hermes-fold7/scripts/45-shizuku.sh
set -euo pipefail
# 안드로이드는 Download 폴더 '자체'를 고를 수 없어서 하위 폴더에 내보내는 경우가 많음 → 하위 폴더까지 찾기
SRC="$(find "$HOME/storage/shared" /sdcard -maxdepth 4 -name rish_shizuku.dex -newermt '-30 days' 2>/dev/null | head -1 | xargs -r dirname)"
[ -n "$SRC" ] && [ -f "$SRC/rish" ] || SRC=""
[ -n "$SRC" ] || { echo "❌ rish 파일을 못 찾음 → Shizuku 앱 → '터미널 앱에서 Shizuku 사용' → 내보내기 → Download 안에 폴더 하나 만들어 선택"; exit 1; }
echo "찾음: $SRC" 
install -m 700 "$SRC/rish" "$PREFIX/bin/rish"
install -m 400 "$SRC/rish_shizuku.dex" "$PREFIX/bin/rish_shizuku.dex"
# rish 는 어떤 앱에서 쓰는지 알아야 함 → Termux
sed -i 's/^RISH_APPLICATION_ID=.*/RISH_APPLICATION_ID="com.termux"/; s/"PKG"/"com.termux"/' "$PREFIX/bin/rish"
grep -q 'RISH_APPLICATION_ID="com.termux"' "$PREFIX/bin/rish" || sed -i '1a export RISH_APPLICATION_ID="com.termux"' "$PREFIX/bin/rish"
echo "Shizuku 권한 요청 창이 뜨면 '항상 허용'을 누르세요…"
uid="$(timeout 30 rish -c 'id -u' 2>/dev/null | tr -dc '0-9' || true)"
if [ "$uid" = 2000 ]; then
  echo "✅ Shizuku 연결됨 — 이제 5G 에서도 phone set 이 동작해요 (재부팅하면 Shizuku 앱에서 '시작'만 다시)"
  phone adb-status 2>/dev/null || true
else
  echo "⚠ 아직 연결 안 됨: Shizuku 앱이 '실행 중'인지, Termux 권한을 허용했는지 확인 후 다시 실행"
fi
