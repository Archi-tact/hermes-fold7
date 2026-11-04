#!/data/data/com.termux/files/usr/bin/bash
# 50-autostart.sh — Termux:Boot 자동시작 + (선택) 텔레그램 게이트웨이
#   bash scripts/50-autostart.sh apt|proot [--gateway]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-apt}"; GW="${2:-}"
mkdir -p "$HOME/.termux/boot" "$HOME/.hermes-bridge"
echo "$MODE" > "$HOME/.hermes-bridge/mode"
install -m 700 "$HERE/boot/10-hermes" "$HOME/.termux/boot/10-hermes"

if [ "$GW" = "--gateway" ]; then
  H=hermes; [ "$MODE" = proot ] && H=hermes-proot
  echo "텔레그램 봇 설정: BotFather 토큰과 '내 텔레그램 숫자 ID'만 허용목록에 넣으세요."
  $H gateway setup
  $H config get TELEGRAM_ALLOWED_USERS >/dev/null 2>&1 \
    || echo "⚠ TELEGRAM_ALLOWED_USERS 가 비어있으면 아무도 명령할 수 없습니다(기본 거부)."
  touch "$HOME/.hermes-bridge/gateway.enabled"
fi
echo "✅ 재부팅 후 자동 시작됩니다. 지금 바로: sh ~/.termux/boot/10-hermes"
