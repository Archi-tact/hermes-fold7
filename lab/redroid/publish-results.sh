#!/usr/bin/env bash
# lab/redroid/publish-results.sh — E2E 화면 녹화를 GIF/MP4로 만들고 GitHub 실행 결과 페이지(Summary)에 표시
#   CI 전용. 결과 이미지는 'lab-results' 브랜치에 최신 1회분만 보관(강제 push)하고 커밋 SHA로 링크한다.
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
ART="$LAB/artifacts"
[ -d "$ART" ] || { echo "artifacts 없음"; exit 0; }
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# 1) 프레임 → GIF(결과 페이지용, 가볍게) + MP4(다운로드용, 선명하게)
if ls "$ART"/frames/*.png >/dev/null 2>&1; then
  n=$(ls "$ART"/frames/*.png | wc -l)
  ffmpeg -loglevel error -y -framerate 3 -pattern_type glob -i "$ART/frames/*.png" \
    -vf "scale=320:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer" \
    "$ART/e2e.gif"
  ffmpeg -loglevel error -y -framerate 3 -pattern_type glob -i "$ART/frames/*.png" \
    -vf "scale=540:-2" -c:v libx264 -pix_fmt yuv420p "$ART/e2e.mp4"
  rm -rf "$ART/frames"
  echo "프레임 ${n}장 → e2e.gif $(du -h "$ART/e2e.gif" | cut -f1), e2e.mp4 $(du -h "$ART/e2e.mp4" | cut -f1)"
fi
# 주요 장면 스크린샷은 결과 페이지용 축소본도 생성
mkdir -p "$ART/shots-small"
for f in "$ART"/shots/*.png; do
  [ -f "$f" ] && ffmpeg -loglevel error -y -i "$f" -vf scale=300:-1 "$ART/shots-small/$(basename "$f")"
done

# 2) lab-results 브랜치에 게시 (공개 저장소 → raw 링크로 결과 페이지에 이미지 표시)
SHA=""
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  PUB="$(mktemp -d)"
  cp "$ART"/e2e.gif "$PUB/" 2>/dev/null || true
  cp "$ART"/shots-small/*.png "$PUB/" 2>/dev/null || true
  git -C "$PUB" init -q -b lab-results
  git -C "$PUB" add -A
  git -C "$PUB" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "lab results: run ${GITHUB_RUN_ID:-local}"
  git -C "$PUB" push -q -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" lab-results \
    && SHA="$(git -C "$PUB" rev-parse HEAD)" || echo "⚠ lab-results 게시 실패 (권한 확인: contents: write)"
fi
RAW="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-}/${SHA}"

# 3) 결과 페이지(Summary) 작성
{
  echo "## 📱 Android E2E 화면 (redroid + Termux + Hermes)"
  if grep -q '^RESULT:' "$ART/e2e-result.txt" 2>/dev/null; then echo; echo "**$(grep '^RESULT:' "$ART/e2e-result.txt")**"; fi
  if [ -n "$SHA" ]; then
    echo; echo "### 전체 과정 (3배속)"
    echo "<img src=\"$RAW/e2e.gif\" width=\"320\">"
    echo; echo "### 주요 장면"
    echo "<table><tr>"
    for f in "$ART"/shots-small/*.png; do
      [ -f "$f" ] || continue
      b="$(basename "$f" .png)"
      echo "<td align=\"center\"><img src=\"$RAW/$b.png\" width=\"220\"><br><sub>$b</sub></td>"
    done
    echo "</tr></table>"
  fi
  echo; echo "고화질 영상(e2e.mp4)·원본 스크린샷·Termux 로그·감사 로그: 아래 **Artifacts → android-e2e**"
  if [ -f "$ART/e2e-result.txt" ]; then
    echo; echo "<details><summary>테스트 결과 전체</summary>"; echo; echo '```'; grep -E '^(==|OK|FAIL|RESULT)' "$ART/e2e-result.txt"; echo '```'; echo "</details>"
  fi
} >> "$SUMMARY"
