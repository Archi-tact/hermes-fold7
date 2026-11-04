#!/data/data/com.termux/files/usr/bin/bash
# 70-skills-storage.sh — 스킬을 폰 저장공간(/sdcard/Hermes)에서 보고 가져오기
#
#   bash scripts/70-skills-storage.sh export   # Hermes 스킬 → /sdcard/Hermes/skills (보기용 사본, 파일 앱에서 열람)
#   bash scripts/70-skills-storage.sh import   # /sdcard/Hermes/inbox/<스킬폴더> → Hermes 스킬로 가져오기 (확인 후)
#   (폰 부팅 때마다 자동 export: boot/10-hermes 가 실행)
#
# 왜 '사본'인가: /sdcard 는 저장소 권한이 있는 다른 앱도 쓸 수 있습니다. 에이전트가 거기서 스킬을
# 바로 읽으면 다른 앱이 스킬을 바꿔 에이전트를 조종할 수 있으므로(프롬프트 인젝션), 실제 스킬은
# Termux 비공개 영역(~/.hermes/skills)에 두고, /sdcard 에는 내보낸 사본만 둡니다.
# 가져오기(import)는 사람이 내용을 확인한 뒤에만 합니다.
set -euo pipefail
H="${HERMES_CMD:-hermes}"
SHARED="${HERMES_SHARED_DIR:-$HOME/storage/shared/Hermes}"
case "$H" in
  hermes-proot) SKILLS="$PREFIX/var/lib/proot-distro/installed-rootfs/${HERMES_DISTRO:-debian}/root/.hermes/skills" ;;
  *)            SKILLS="${HERMES_HOME:-$HOME/.hermes}/skills" ;;
esac
EXTRA="$HOME/.hermes-bridge/client/skills"   # 키트 스킬(fold7-phone, fold7-hands)

[ -d "$HOME/storage/shared" ] || { echo "먼저 termux-setup-storage 로 저장소 권한을 주세요." >&2; exit 1; }
mkdir -p "$SHARED/skills" "$SHARED/inbox"

case "${1:-export}" in
  export)
    rm -rf "$SHARED/skills.new"; mkdir -p "$SHARED/skills.new"
    [ -d "$SKILLS" ] && cp -r "$SKILLS"/. "$SHARED/skills.new/" 2>/dev/null || true
    [ -d "$EXTRA" ]  && cp -r "$EXTRA"/.  "$SHARED/skills.new/" 2>/dev/null || true
    rm -rf "$SHARED/skills"; mv "$SHARED/skills.new" "$SHARED/skills"
    printf '이 폴더는 보기용 사본입니다. 여기서 고쳐도 Hermes에 반영되지 않습니다.\n수정/추가는 inbox/ 에 넣고: bash scripts/70-skills-storage.sh import\n' > "$SHARED/skills/README.txt"
    echo "✅ 내보냄: $SHARED/skills ($(find "$SHARED/skills" -name SKILL.md | wc -l)개 스킬)"
    ;;
  import)
    shopt -s nullglob
    found=0
    for d in "$SHARED"/inbox/*/; do
      [ -f "$d/SKILL.md" ] || continue
      found=1
      name="$(basename "$d")"
      [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "건너뜀(이름 형식): $name"; continue; }
      echo "──── $name/SKILL.md (앞부분) ────"; head -40 "$d/SKILL.md"
      read -r -p "'$name' 스킬을 가져올까요? [y/N] " a
      if [ "$a" = y ]; then
        mkdir -p "$SKILLS"; rm -rf "${SKILLS:?}/$name"; cp -r "$d" "$SKILLS/$name"
        rm -rf "$d"; echo "✅ 가져옴: $name"
      fi
    done
    [ $found = 1 ] || echo "inbox 가 비어 있습니다: $SHARED/inbox/<스킬이름>/SKILL.md"
    ;;
  *) echo "사용: $0 export|import" >&2; exit 1 ;;
esac
