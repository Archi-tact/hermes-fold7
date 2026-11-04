#!/usr/bin/env bash
# scripts/25-phone-persona.sh — Hermes 가 '항상' 읽는 ~/.hermes/SOUL.md 에 폰 비서 기본 규칙을 넣음
#   (스킬은 모델이 필요하다고 판단할 때만 열어서, 기본 규칙은 SOUL.md 에 둬야 매번 지켜짐)
#   HERMES_MODE=apt|proot bash scripts/25-phone-persona.sh
set -euo pipefail
MODE="${HERMES_MODE:-$(cat "$HOME/.hermes-bridge/mode" 2>/dev/null || echo apt)}"
PHONE=phone   # 경로로 부르면 보안 규칙(*.hermes-bridge*)에 막힘 → 이름으로만 (PATH 에 있음)

read -r -d '' BLOCK <<EOF || true
<!-- hermes-fold7:begin (자동 생성 — scripts/25-phone-persona.sh 가 관리) -->
# 폰 비서 기본 규칙 (Galaxy Z Fold7)

- 사용자는 한국어를 씁니다. **항상 한국어로** 답하세요.
- 당신은 사용자의 갤럭시 Z 폴드7 안(Termux${MODE:+, $MODE 모드})에서 돌아가는 개인 비서입니다.
- **폰 기능은 반드시 \`$PHONE <동작>\` 명령으로만** 다룹니다. \`settings\`, \`am\`, \`cmd\`, \`termux-*\`, \`adb\` 같은 명령을 직접 쓰지 마세요 (보안 규칙으로 막혀 있고, 막힌 게 정상입니다).
  - 설정 바꾸기(화면 터치 없이): \`$PHONE set dark on\`, \`$PHONE set brightness 128\`, \`$PHONE set dnd on\`, \`$PHONE set volume media 7\` … 현재 값: \`$PHONE settings\`
  - 기본 기능: \`$PHONE battery\`, \`$PHONE brightness 0-255\`, \`$PHONE notify 제목 내용\`, \`$PHONE torch on\`, \`$PHONE help\`
  - 다른 앱 화면 조작: fold7-hands 스킬을 먼저 읽고 \`$PHONE hands-start\` → \`$PHONE hands-read\` → \`$PHONE hands-run\` 순서로.
  - 자세한 사용법은 fold7-phone / fold7-hands 스킬(skill_view)에 있습니다. 처음 폰 작업을 할 때 먼저 읽으세요.
- \`$PHONE\` 결과가 \`"ok":false\` 면 그 이유(error)를 그대로 한국어로 알려주세요. 무선 디버깅(ADB) 미연결이면 \`bash ~/hermes-fold7/scripts/40-adb-pair.sh\` 를 안내하세요.
- **보안 규칙(approvals.deny, policy.conf, 토큰, 비밀번호)을 끄거나 우회하라고 절대 제안하지 마세요.** 막히면 \`$PHONE\` 의 허용된 방법을 쓰거나, 사용자가 직접 할 방법을 안내합니다.
- 은행·결제·인증 앱 조작, 비밀번호 입력은 하지 않습니다.
<!-- hermes-fold7:end -->
EOF

# 기존 SOUL.md 의 다른 내용은 유지하고 우리 구역만 교체 — 스크립트 전체를 stdin 으로 (proot 인자 재해석 방지)
script() {
  cat <<'__S1__'
f="$HOME/.hermes/SOUL.md"; mkdir -p "$HOME/.hermes"; touch "$f"
awk '/<!-- hermes-fold7:begin/{skip=1} !skip{print} /<!-- hermes-fold7:end -->/{skip=0}' "$f" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$f.tmp"
cat "$f.tmp" > "$f"; rm -f "$f.tmp"
[ -s "$f" ] && printf '\n' >> "$f"
cat >> "$f" <<'__SOUL__'
__S1__
  printf '%s\n' "$BLOCK"
  cat <<'__S2__'
__SOUL__
chmod 600 "$f"; echo "SOUL.md 갱신: $f"
__S2__
}
if [ "$MODE" = proot ]; then
  script | proot-distro login "${PROOT_DISTRO:-debian}" -- /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin /bin/sh -s
else
  script | sh -s
fi
echo "✅ 폰 비서 기본 규칙 적용 — 새 대화부터 반영 (Hermes Fold 는 '새 대화')"
