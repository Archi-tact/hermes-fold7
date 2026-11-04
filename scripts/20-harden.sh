#!/data/data/com.termux/files/usr/bin/bash
# 20-harden.sh — Hermes 보안 기본값 + 작업폴더 + 폰 스킬 연결 (Termux에서 실행)
#   HERMES_MODE=apt   (기본, Plan A)  → hermes
#   HERMES_MODE=proot (Plan B)        → hermes-proot
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${HERMES_MODE:-apt}"
WORKSPACE_HOST="${HERMES_WORKSPACE:-$HOME/work}"
BH="$HOME/.hermes-bridge"
mkdir -p "$WORKSPACE_HOST" "$BH/client/skills"

case "$MODE" in
  apt)   H=(hermes);       WS="$WORKSPACE_HOST"; SKILLS_DIR="$BH/client/skills"
         HH="$HOME/.hermes" ;;
  proot) H=(hermes-proot); WS="/root/work";      SKILLS_DIR="/root/.hermes-bridge-client/skills"
         HH="$PREFIX/var/lib/proot-distro/installed-rootfs/${HERMES_DISTRO:-debian}/root/.hermes" ;;
  *) echo "HERMES_MODE=apt|proot" >&2; exit 1 ;;
esac
set_cfg() { echo "  config set $1"; "${H[@]}" config set "$1" "$2" >/dev/null; }

echo "==> 1. 위험 명령 승인: 항상 사람에게 묻기, 무인 실행은 거부"
set_cfg approvals.mode manual
set_cfg approvals.timeout 120
set_cfg approvals.cron_mode deny
set_cfg approvals.single_query_mode deny
set_cfg approvals.unattended_mode deny

echo "==> 2. 절대 금지 명령 (YOLO 모드에서도 차단)"
DENY_JSON="$(jq -cn '[
  "termux-*", "adb", "adb *", "*phone-bridge*", "*.hermes-bridge*",
  "*authorized_keys*", "*sshd_config*", "*.hermes/config.yaml*", "*.hermes/.env*",
  "su", "su *", "pm uninstall*", "pm clear*", "phone-hands-pair*", "*hands.token*", "*desktop.token*", "*80-hermes-fold.sh password*",
  "rm -rf ~*", "rm -rf /sdcard*", "rm -rf /storage*", "rm -rf /data*",
  "git push --force*", "git push -f*",
  "*curl*|*sh*", "*wget*|*sh*", "*curl*|*bash*", "*wget*|*bash*"
]')"
set_cfg approvals.deny "$DENY_JSON"

echo "==> 3. 작업 폴더 고정 + 파일쓰기 샌드박스"
set_cfg terminal.cwd "$WS"
set_cfg HERMES_WRITE_SAFE_ROOT "$WS"      # write_file/patch는 작업폴더 밖에 못 씀 (.env에 저장)

echo "==> 4. 스킬: 폰 브리지 스킬 연결 + 에이전트 생성 스킬 검사"
for sk in "$HERE"/skills/*/; do      # fold7-phone, fold7-hands …
  rm -rf "$BH/client/skills/$(basename "$sk")"
  cp -r "$sk" "$BH/client/skills/"
done
set_cfg skills.external_dirs "[\"$SKILLS_DIR\"]"
set_cfg skills.guard_agent_created true

echo "==> 5. 메신저 게이트웨이: 모르는 사용자는 무시"
set_cfg unauthorized_dm_behavior ignore

echo "==> 6. 비밀파일 권한"
[ -d "$HH" ] && chmod 700 "$HH" || true
[ -f "$HH/.env" ] && chmod 600 "$HH/.env" || true
chmod 700 "$BH"; chmod 600 "$BH"/policy.conf 2>/dev/null || true

"${H[@]}" doctor || true
cat <<EOF

✅ 하드닝 완료
 - 작업폴더: $WORKSPACE_HOST  (에이전트 기준 경로: $WS)
 - 위험 명령은 매번 승인 요청, cron/원샷/웹훅은 위험 명령 자동 거부
 - 폰 기능은 'phone <동작>' 으로만 (정책: $BH/policy.conf, 로그: $BH/audit.log)
 ⚠ 위 설정은 '정책'입니다. 터미널 도구는 같은 OS 사용자 권한으로 실행되므로
   완전한 샌드박스가 아닙니다. 중요한 데이터는 작업폴더에 두지 마세요.
EOF
