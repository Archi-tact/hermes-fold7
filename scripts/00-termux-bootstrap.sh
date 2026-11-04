#!/data/data/com.termux/files/usr/bin/bash
# 00-termux-bootstrap.sh — Termux 기본 환경 준비 (Galaxy Fold7 / aarch64)
# 실행 위치: Termux 앱 (F-Droid 또는 GitHub 릴리스판). Play 스토어판은 쓰지 마세요.
set -euo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if [ -z "${PREFIX:-}" ] || [ "${PREFIX}" != "/data/data/com.termux/files/usr" ]; then
  echo "이 스크립트는 표준 Termux 앱 안에서만 실행하세요. (PREFIX=${PREFIX:-unset})" >&2
  exit 1
fi
# HERMES_LAB_ALLOW_X86=1 : 테스트 서버(x86_64 redroid/GitHub Actions) 전용 예외. 실폰은 aarch64.
if [ "$(uname -m)" != "aarch64" ] && [ "${HERMES_LAB_ALLOW_X86:-0}" != 1 ]; then
  echo "aarch64 기기만 지원합니다. (현재: $(uname -m))" >&2
  exit 1
fi

say "패키지 저장소 갱신"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew)
pkg update -y
apt-get "${APT_OPTS[@]}" upgrade

say "기본 도구 설치"
# termux-api: 폰 기능 브리지 / openssh: proot<->Termux 브리지 + 원격 접속
# android-tools: 무선 디버깅(adb)으로 시스템 조작 / proot-distro: Plan B
apt-get "${APT_OPTS[@]}" install curl gnupg git openssh termux-api android-tools proot-distro \
  ripgrep jq coreutils procps which nano tmux

say "공유 저장소 권한 요청 (팝업에서 '허용')"
if [ "${HERMES_NONINTERACTIVE:-0}" = 1 ]; then
  echo "(비대화형 모드: 저장소 권한 요청 생략)"
else
  termux-setup-storage || true
fi

say "작업 폴더 생성"
WORKSPACE="${HERMES_WORKSPACE:-$HOME/work}"
mkdir -p "$WORKSPACE" "$HOME/.hermes-bridge" "$HOME/.termux/boot"
chmod 700 "$HOME/.hermes-bridge"
echo "작업 폴더: $WORKSPACE"

say "Termux:API 연결 확인"
if timeout 15 termux-battery-status >/dev/null 2>&1; then
  echo "Termux:API OK"
else
  echo "⚠ Termux:API 앱이 없거나 권한이 없습니다. Termux와 같은 출처(F-Droid/GitHub)의 Termux:API 앱을 설치하세요."
fi

cat <<'EOF'

다음 단계 (폰 설정에서 직접):
  1. 설정 > 애플리케이션 > Termux / Termux:API / Termux:Boot > 배터리 > '제한 없음'
  2. 설정 > 배터리 > 백그라운드 사용 제한 > '절전 예외 앱'에 위 3개 추가
  3. Termux:Boot 앱을 한 번 실행(부팅 자동시작 활성화)

그 다음:  bash scripts/10-install-hermes-apt.sh   (Plan A, 공식 Termux 패키지)
   또는:  bash scripts/11-install-hermes-proot.sh (Plan B, proot Debian + 데스크톱용 설치)
EOF
