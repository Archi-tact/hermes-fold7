#!/data/data/com.termux/files/usr/bin/bash
# scripts/install.sh — 폰 하나로 끝: 명령 한 번 → 브라우저에서 API 키만 넣으면 사용
#
#   Termux 에서 (처음 한 번):
#     pkg install -y git && git clone https://github.com/Archi-tact/hermes-fold7 ~/hermes-fold7 && bash ~/hermes-fold7/scripts/install.sh
#
#   하는 일: Termux 준비 → Hermes 설치(공식 패키지, 안 되면 proot) → 폰 브리지 → 보안 설정 → 부팅 자동시작
#            → Hermes Fold 화면 시작 → (선택) Hermes Hands 앱 설치창 → 브라우저 열기
#   API 키는 터미널이 아니라 열린 화면의 '모델 · API 키' 에서 입력 (Hermes 설정 파일에 저장, 에이전트는 못 읽음)
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT"
say()  { printf '\n\033[1;36m━━ %s\033[0m\n' "$*"; }
ask()  { local a; [ "${HERMES_YES:-}" = 1 ] && return 0; read -r -p "$1 [Y/n] " a </dev/tty || true; [[ ! "$a" =~ ^[Nn] ]]; }
[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || { echo "❌ Termux 안에서 실행하세요"; exit 1; }
[ "$(uname -m)" = aarch64 ] || echo "⚠ $(uname -m) — 폴드7(aarch64) 기준으로 만든 설치입니다"

say "1/6 Termux 준비 (패키지 · 저장공간 권한 · 작업 폴더)"
bash scripts/00-termux-bootstrap.sh

say "2/6 Hermes 설치"
MODE=""
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then MODE=apt; echo "이미 설치됨: $(hermes --version | head -1)"
elif command -v hermes-proot >/dev/null 2>&1; then MODE=proot; echo "이미 설치됨 (proot)"
elif bash scripts/10-install-hermes-apt.sh && hermes --version >/dev/null 2>&1; then MODE=apt
else echo "공식 패키지가 안 돼서 proot(Debian) 방식으로 설치합니다 (10~20분)"; bash scripts/11-install-hermes-proot.sh; MODE=proot; fi
mkdir -p "$HOME/.hermes-bridge"; echo "$MODE" > "$HOME/.hermes-bridge/mode"

say "3/6 폰 기능 브리지 + 보안 설정"
bash scripts/30-phone-bridge.sh
HERMES_MODE="$MODE" bash scripts/20-harden.sh

say "4/6 부팅 자동시작 (Termux:Boot)"
bash scripts/50-autostart.sh "$MODE"

say "5/6 Hermes Fold 화면"
HERMES_MODE="$MODE" bash scripts/80-hermes-fold.sh setup      # 비밀번호는 화면에 한 번만 표시 (파일로 저장 안 함)
HERMES_MODE="$MODE" bash scripts/80-hermes-fold.sh start

say "6/6 (선택) Hermes Hands — 앱 화면 조작용"
if ask "Hermes Hands 앱 설치창을 열까요? (다른 앱을 대신 눌러주는 기능)"; then
  T="$(mktemp -d)"; B="https://github.com/Archi-tact/hermes-fold7/releases/download/hands-latest"
  if curl -fsSL "$B/hermes-hands.apk" -o "$T/hermes-hands.apk" && curl -fsSL "$B/hermes-hands.apk.sha256" -o "$T/sum"; then
    if [ "$(awk '{print $1}' "$T/sum")" = "$(sha256sum "$T/hermes-hands.apk" | awk '{print $1}')" ]; then
      cp "$T/hermes-hands.apk" "$HOME/storage/downloads/hermes-hands.apk" 2>/dev/null || true
      termux-open "$T/hermes-hands.apk" 2>/dev/null || termux-open "$HOME/storage/downloads/hermes-hands.apk" || true
      cat <<'EOF'
   설치 후: 앱 열기 → '접근성 설정' → Hermes Hands 켜기 → '토큰 복사' → Termux 에서:  phone-hands-pair
EOF
    else echo "❌ APK 체크섬 불일치 — 설치하지 않음"; fi
  else echo "⚠ 다운로드 실패 — 나중에 Releases 의 hands-latest 에서 받으세요"; fi
fi

[ "${HERMES_YES:-}" = 1 ] || read -r -p "Hermes Hands 설치를 마쳤거나 건너뛰려면 엔터 → 브라우저를 엽니다 " _ </dev/tty || true
termux-open-url "http://127.0.0.1:${FOLD_PORT:-9130}" 2>/dev/null || true
cat <<EOF

🎉 설치 끝!  브라우저가 열립니다 (안 열리면 Chrome 에서 http://127.0.0.1:${FOLD_PORT:-9130})
   1) 위에 나온 아이디 fold / 비밀번호로 로그인  (잊으면: bash ~/hermes-fold7/scripts/80-hermes-fold.sh password)
   2) 처음 화면에서 'API 키' 입력 — NVIDIA 무료 키 추천 (build.nvidia.com → Get API Key)
   3) Chrome ⋮ → '홈 화면에 추가' → 이제 앱처럼 사용
   폰을 껐다 켜도 자동으로 다시 켜집니다 (Termux:Boot 앱을 한 번 실행해 두세요).
EOF
