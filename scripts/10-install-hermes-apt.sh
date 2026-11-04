#!/data/data/com.termux/files/usr/bin/bash
# 10-install-hermes-apt.sh — Plan A: Nous Research 공식 서명 Termux APT 저장소로 설치
# 공식 문서: website/docs/getting-started/termux.md
# ⚠ 2026-11-01 기준 공식 문서에 "Termux package is currently broken (fix in progress)" 경고가 있습니다.
#    설치 후 `hermes --version`/`hermes doctor`가 실패하면 Plan B(11-install-hermes-proot.sh)를 쓰세요.
set -euo pipefail

CHANNEL="${HERMES_CHANNEL:-stable}"          # stable | canary
case "$CHANNEL" in
  stable) SUITE="hermes-stable" ;;
  canary) SUITE="hermes-canary" ;;
  *) echo "HERMES_CHANNEL은 stable 또는 canary" >&2; exit 1 ;;
esac

EXPECTED_FPR="C572B5FDD1A29CCFA9A912B6840B0848E139156D"
KEYRING="$PREFIX/etc/apt/keyrings/hermes-agent.asc"
BASE="https://hermes-assets.nousresearch.com/releases/termux/$CHANNEL"

pkg install -y curl gnupg
mkdir -p "$PREFIX/etc/apt/keyrings"
curl -fsSL "$BASE/key.asc" -o "$KEYRING.tmp"

# 서명키 지문 검증 — 다르면 즉시 중단 (절대 서명검증을 끄지 마세요)
ACTUAL_FPR="$(gpg --show-keys --with-colons "$KEYRING.tmp" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
if [ "$ACTUAL_FPR" != "$EXPECTED_FPR" ]; then
  rm -f "$KEYRING.tmp"
  echo "❌ 키 지문 불일치! expected=$EXPECTED_FPR actual=${ACTUAL_FPR:-none}" >&2
  echo "   설치를 중단합니다. 공식 문서의 지문이 바뀌었는지 직접 확인하세요." >&2
  exit 1
fi
mv "$KEYRING.tmp" "$KEYRING"
echo "✅ 키 지문 확인: $ACTUAL_FPR"

printf '%s\n' \
  "deb [signed-by=$KEYRING] $BASE $SUITE main" \
  > "$PREFIX/etc/apt/sources.list.d/hermes-agent.list"

pkg update
pkg install -y hermes-agent

echo
hermes --version || { echo "❌ hermes 실행 실패 → Plan B를 사용하세요."; exit 1; }
hermes doctor </dev/null || true          # 설정 마법사가 뜨지 않게 (API 키는 Hermes Fold 화면에서)

cat <<'EOF'

✅ 설치 완료. 이어서:
  hermes setup                         # 모델/프로바이더(API 키) 설정
  bash scripts/20-harden.sh            # 보안 설정 + 작업폴더 + 폰 브리지 스킬
  hermes --tui                         # 실행
업데이트: pkg update && pkg upgrade hermes-agent   (hermes update는 APT 설치를 건드리지 않음)
EOF
