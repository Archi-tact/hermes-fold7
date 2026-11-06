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
# (/sdcard·~/storage/shared 는 바로가기라 끝에 / 를 붙여야 안으로 들어가서 찾음)
# (Android/data 처럼 못 여는 폴더가 있으면 find 가 실패 코드로 끝남 → set -e 로 조용히 꺼지지 않게 || true)
DEX="$( { find /storage/emulated/0/ "$HOME/storage/shared/" -maxdepth 4 -name rish_shizuku.dex 2>/dev/null || true; } | head -1)"
[ -n "$DEX" ] || [ -r /storage/emulated/0/Download ] || { echo "❌ 저장소 권한 없음 → termux-setup-storage 실행 후 '허용' → 다시 실행"; exit 1; }
SRC=""; [ -n "$DEX" ] && SRC="${DEX%/*}"
[ -n "$SRC" ] && [ -f "$SRC/rish" ] || SRC=""
[ -n "$SRC" ] || { echo "❌ rish 파일을 못 찾음 → Shizuku 앱 → '터미널 앱에서 Shizuku 사용' → 내보내기 → Download 안에 폴더 하나 만들어 선택"; exit 1; }
echo "찾음: $SRC" 
install -m 700 "$SRC/rish" "$PREFIX/bin/rish"
install -m 400 "$SRC/rish_shizuku.dex" "$PREFIX/bin/rish_shizuku.dex"
# rish 는 어떤 앱에서 쓰는지 알아야 함 → Termux
sed -i 's/^RISH_APPLICATION_ID=.*/RISH_APPLICATION_ID="com.termux"/; s/"PKG"/"com.termux"/' "$PREFIX/bin/rish"
grep -q 'RISH_APPLICATION_ID="com.termux"' "$PREFIX/bin/rish" || sed -i '1a export RISH_APPLICATION_ID="com.termux"' "$PREFIX/bin/rish"
# phone 브리지는 SSH 로 실행돼 안드로이드 환경변수(BOOTCLASSPATH 등)가 빠짐 → app_process 가 실패
# → 지금 Termux 의 값을 rish 안에 기본값으로 넣어 둠 (이미 있으면 그대로 사용)
{
  head -1 "$PREFIX/bin/rish"
  for v in ANDROID_ROOT ANDROID_DATA ANDROID_ART_ROOT ANDROID_I18N_ROOT ANDROID_TZDATA_ROOT BOOTCLASSPATH DEX2OATBOOTCLASSPATH SYSTEMSERVERCLASSPATH; do
    val="${!v:-}"; [ -n "$val" ] || continue
    printf '[ -n "${%s:-}" ] || export %s=%q   # hermes-fold7\n' "$v" "$v" "$val"
  done
  tail -n +2 "$PREFIX/bin/rish" | grep -v '# hermes-fold7$'
} > "$PREFIX/bin/rish.tmp" && chmod 700 "$PREFIX/bin/rish.tmp" && mv "$PREFIX/bin/rish.tmp" "$PREFIX/bin/rish"
echo "Shizuku 권한 요청 창이 뜨면 '항상 허용'을 누르세요…"
# rish 는 출력을 변수로 받으면 입력(stdin)이 끝나길 기다리며 멈춤 → </dev/null 필수
out="$(timeout 30 rish -c 'id -u' </dev/null 2>&1 || true)"
uid="$(printf '%s' "$out" | tail -1 | tr -dc '0-9')"
if [ "$uid" = 2000 ]; then
  echo "✅ Shizuku 연결됨 — 이제 5G 에서도 phone set 이 동작해요 (재부팅하면 Shizuku 앱에서 '시작'만 다시)"
  echo "---- Hermes(phone 브리지) 쪽 확인"
  phone adb-status 2>/dev/null || true
  # 재부팅 대비 ①: Shizuku 앱이 부팅 때 스스로 무선 디버깅을 켜고 시작할 수 있게 권한 부여 (Shizuku 앱에만 · Termux 에는 안 줌)
  echo "---- 재부팅 후 자동 시작 준비"
  if rish -c 'pm grant moe.shizuku.privileged.api android.permission.WRITE_SECURE_SETTINGS' </dev/null >/dev/null 2>&1; then
    echo "✅ Shizuku 에 '부팅 시 자동 시작' 권한 부여됨"
    echo "   → Shizuku 앱 → 오른쪽 위 ⚙ 설정 → '부팅 시 시작' 켜기 (한 번만)"
  else
    echo "⚠ 자동 시작 권한 부여 실패 — 재부팅 후엔 Shizuku 앱에서 '시작'을 직접 눌러 주세요"
  fi
  # 재부팅 대비 ②: 부팅 몇 분 뒤 Shizuku 가 꺼져 있으면 알림 (Termux:Boot 필요)
  mkdir -p "$HOME/.termux/boot"
  install -m 700 "$(cd "$(dirname "$0")/.." && pwd)/boot/20-shizuku" "$HOME/.termux/boot/20-shizuku"
  echo "✅ 부팅 확인 설치: 재부팅 후 Shizuku 가 안 켜졌으면 알림이 와요"
else
  echo "⚠ 아직 연결 안 됨: Shizuku 앱이 '실행 중'인지, Termux 권한을 허용했는지 확인 후 다시 실행"
  echo "---- rish 가 보낸 메시지 (원인 확인용)"; printf '%s\n' "${out:-(아무 출력 없음 — 30초 안에 응답 없음)}" | tail -15
fi
