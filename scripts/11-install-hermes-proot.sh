#!/data/data/com.termux/files/usr/bin/bash
# 11-install-hermes-proot.sh — Plan B: Termux 안에 proot Debian(glibc arm64)을 만들고
# 데스크톱/서버용 공식 install.sh(linux-arm64 지원)로 Hermes 전체 기능을 설치.
#
# 장점: Termux APT판보다 넓은 기능(데스크톱 extras, Debian chromium 브라우저 도구 등)
# 한계: proot는 '호환 레이어'이지 보안 샌드박스가 아닙니다. 루트 없는 Android에서
#       Docker는 불가. 성능은 네이티브보다 다소 느립니다.
set -euo pipefail

DISTRO="${HERMES_DISTRO:-debian}"
WORKSPACE="${HERMES_WORKSPACE:-$HOME/work}"
mkdir -p "$WORKSPACE"

pkg install -y proot-distro openssh

if [ ! -d "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" ]; then
  proot-distro install "$DISTRO"
fi

# 게스트 안에서 실행할 설치 스크립트
GUEST_SETUP='
set -euo pipefail
unset PREFIX TERMUX_VERSION LD_PRELOAD   # Termux 변수가 새면 install.sh가 Termux로 오인해 거부함
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git sudo xz-utils \
  ripgrep jq openssh-client procps libatomic1 chromium python3 tzdata
# 공식 설치 스크립트를 먼저 내려받아 확인 후 실행 (파이프 직결 X)
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh
echo "---- install.sh sha256: $(sha256sum /tmp/hermes-install.sh | cut -d" " -f1)"
if ! bash /tmp/hermes-install.sh; then
  echo "---- 진단: 남은 ANDROID/TERMUX 환경변수"; env | grep -iE "android|termux|^prefix=" || echo "(없음)"
  echo "---- 진단: /system /apex 존재"; ls -d /system /apex 2>&1
  echo "---- 진단: uv 관리 Python"; ls ~/.local/share/uv/python 2>&1
  exit 1
fi
'

echo "==> proot $DISTRO 안에서 Hermes 설치"
# env -i: Termux/안드로이드 환경변수(ANDROID_ROOT 등)가 게스트로 새면 Hermes가 glibc Debian을
#         Android(bionic)로 오인해 의존성 설치를 거부함 → 깨끗한 환경으로 실행
proot-distro login "$DISTRO" --bind "$WORKSPACE:/root/work" -- /usr/bin/env -i \
  HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 \
  PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/bash -c "$GUEST_SETUP"

# Termux에서 바로 부르는 런처
mkdir -p "$HOME/.hermes-bridge/client"
cat > "$PREFIX/bin/hermes-proot" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# proot $DISTRO 안의 Hermes 실행. 작업폴더($WORKSPACE) = 게스트 /root/work
# 폰 브리지 클라이언트 키/스크립트 = 게스트 /root/.hermes-bridge-client (읽기 전용 용도)
exec proot-distro login "$DISTRO" \\
  --bind "$WORKSPACE:/root/work" \\
  --bind "\$HOME/.hermes-bridge/client:/root/.hermes-bridge-client" \\
  -- /usr/bin/env -i HOME=/root TERM="\${TERM:-xterm}" LANG=C.UTF-8 PATH="/root/.local/bin:/root/.hermes-bridge-client:/usr/local/bin:/usr/bin:/bin" \\
  /bin/bash -c 'cd /root/work && exec hermes "\$@"' hermes "\$@"
EOF
chmod 700 "$PREFIX/bin/hermes-proot"

cat <<'EOF'

✅ 설치 완료. 이어서 (Termux에서):
  hermes-proot setup                         # 모델/API 키 설정
  bash scripts/30-phone-bridge.sh            # 폰 기능 브리지(SSH 강제명령) 설치
  HERMES_MODE=proot bash scripts/20-harden.sh  # 보안 설정
  hermes-proot --tui
EOF
