#!/usr/bin/env bash
# lab/redroid/setup-server.sh — ARM64 클라우드 VM에 'Fold7 테스트용 안드로이드(redroid)' 구축
#
# 대상: Ubuntu 22.04 / 24.04 arm64 (Oracle Cloud Ampere A1, AWS Graviton, Hetzner CAX 등)
# 실행: sudo bash lab/redroid/setup-server.sh
#
# 보안 원칙
#  - adb(5555)는 127.0.0.1 에만 바인딩. 외부 공개 절대 금지 (redroid 공식 경고: 호스트까지 장악될 수 있음)
#  - 접속은 SSH 터널로만:  ssh -L 5555:127.0.0.1:5555 <서버>   →  PC에서 scrcpy
#  - 방화벽: 들어오는 연결은 SSH만 허용. SSH는 키 인증만.
set -euo pipefail

ANDROID_VERSION="${REDROID_VERSION:-16.0.0_64only}"   # Fold7 = Android 16 (One UI 8)
NAME="${REDROID_NAME:-hermes-redroid}"
DATA_DIR="${REDROID_DATA:-/srv/redroid/data}"
# Fold7 펼친 화면(1968x2184) 근사. 커버 화면 테스트: REDROID_W=1080 REDROID_H=2520
W="${REDROID_W:-1968}"; H="${REDROID_H:-2184}"; DPI="${REDROID_DPI:-420}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "sudo로 실행하세요" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || echo "ℹ x86_64 호스트: Termux x86_64판 + Plan B(proot)로 테스트합니다 (Plan A 공식 패키지는 aarch64 전용)."
CI="${LAB_CI:-0}"   # 1 = GitHub Actions 등 일회용 러너: 방화벽/SSH 설정 생략
PAGE="$(getconf PAGESIZE)"
[ "$PAGE" = 4096 ] || { echo "❌ 커널 페이지 크기 $PAGE — redroid는 4K 페이지 커널이 필요합니다." >&2; exit 1; }

say "1. 패키지"
export DEBIAN_FRONTEND=noninteractive
apt-get update
if [ "$CI" = 1 ]; then
  apt-get install -y adb curl jq ca-certificates   # 러너에는 docker가 이미 있음
else
  apt-get install -y docker.io adb curl jq ufw unattended-upgrades ca-certificates
  systemctl enable --now docker
fi

say "2. binder 커널 모듈"
apt-get install -y "linux-modules-extra-$(uname -r)" || echo "(modules-extra 패키지 없음 — 아래에서 확인)"
if ! modprobe binder_linux devices="binder,hwbinder,vndbinder"; then
  cat >&2 <<EOF
❌ binder_linux 모듈을 불러오지 못했습니다 (커널: $(uname -r)).
   클라우드 전용 커널(oracle/aws)에 모듈이 없을 수 있습니다. 해결:
     sudo apt-get install -y linux-generic && sudo reboot
   재부팅 후 'uname -r'이 -generic 인지 확인하고 이 스크립트를 다시 실행하세요.
EOF
  exit 1
fi
modprobe ashmem_linux 2>/dev/null || true      # 5.18+ 커널엔 없음(정상) → memfd 사용
echo binder_linux > /etc/modules-load.d/redroid.conf
echo 'options binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modprobe.d/redroid.conf

say "3. 방화벽 (SSH만 허용) + SSH 키 인증만"
if [ "$CI" = 1 ]; then echo "(CI 러너: 생략)"; else
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable
SSHD_DROPIN=/etc/ssh/sshd_config.d/60-hermes-lab.conf
if [ -s /root/.ssh/authorized_keys ] || ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > "$SSHD_DROPIN"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  echo "⚠ authorized_keys가 없어 비밀번호 로그인 차단을 건너뜁니다 (잠김 방지)."
fi
fi
# Oracle Cloud 이미지는 iptables 규칙이 별도로 있음 — 5555를 열지 않으므로 손대지 않음

start_redroid() {  # start_redroid <version>
  say "4. redroid 실행 (Android $1, ${W}x${H}@${DPI}dpi)"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"; mkdir -p "$DATA_DIR"    # 이전 버전 데이터와 섞이지 않게
  docker run -d --name "$NAME" --privileged --restart unless-stopped \
    --pull always \
    -v "$DATA_DIR:/data" \
    -p 127.0.0.1:5555:5555 \
    "redroid/redroid:$1-latest" \
    androidboot.redroid_width="$W" androidboot.redroid_height="$H" androidboot.redroid_dpi="$DPI" \
    androidboot.use_memfd=true
}
wait_boot() {  # wait_boot <timeout_sec> → 0: 부팅 완료 + 패키지 서비스 준비
  local t="$1" i
  for ((i=0; i<t; i+=5)); do
    adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
    if [ "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] \
       && adb -s 127.0.0.1:5555 shell pm path android >/dev/null 2>&1; then
      echo "부팅 완료 (${i}s)"; return 0
    fi
    sleep 5
  done
  return 1
}
diag() {   # 진단은 실패해도 스크립트를 멈추지 않음 (set -e 우회)
  set +e
  echo "---- 진단: docker ps / logs"; docker ps -a --filter "name=$NAME"; docker logs --tail 50 "$NAME" 2>&1
  echo "---- 진단: getprop boot"; adb -s 127.0.0.1:5555 shell getprop 2>/dev/null | grep -E 'boot|init.svc.(zygote|surfaceflinger|servicemanager)' | head -30
  echo "---- 진단: logcat (E/F)"; adb -s 127.0.0.1:5555 logcat -d -b all '*:E' 2>/dev/null | tail -60
  echo "---- 진단: dmesg"; dmesg 2>/dev/null | grep -iE 'binder|avc|redroid|segfault' | tail -30
  echo "---- 진단: binder"; ls -la /dev/binder* /dev/binderfs 2>&1 | head; lsmod | grep -E 'binder|ashmem'
  set -e
  return 0
}

# 시도할 버전: 지정 버전 → (실패 시) 안정 버전들로 자동 대체
VERSIONS=("$ANDROID_VERSION")
[ -n "${REDROID_FALLBACKS-14.0.0_64only 13.0.0_64only}" ] && read -r -a FB <<< "${REDROID_FALLBACKS-14.0.0_64only 13.0.0_64only}" && VERSIONS+=("${FB[@]}")
BOOTED=""
for v in "${VERSIONS[@]}"; do
  start_redroid "$v"
  say "5. 부팅 대기 (Android $v)"
  if wait_boot "${REDROID_BOOT_TIMEOUT:-480}"; then BOOTED="$v"; break; fi
  echo "⚠ Android $v 부팅 실패"; diag
done
[ -n "$BOOTED" ] || { echo "❌ 모든 버전 부팅 실패 — 위 진단 참고" >&2; exit 1; }
[ "$BOOTED" = "$ANDROID_VERSION" ] || echo "ℹ 요청 버전($ANDROID_VERSION) 대신 $BOOTED 로 실행 중"
adb -s 127.0.0.1:5555 shell getprop ro.build.version.release | sed 's/^/Android /'
docker ps --filter "name=$NAME" --format '{{.Names}}  {{.Ports}}'
if ss -ltn | grep -q '0.0.0.0:5555'; then echo "❌ 5555가 외부에 열려 있습니다! 중단하세요." >&2; exit 1; fi

cat <<EOF

✅ redroid 준비 완료 (adb: 127.0.0.1:5555, 외부 비공개)
다음:  sudo bash lab/redroid/install-termux.sh

PC에서 화면 보기 (PC에 adb + scrcpy 설치):
  ssh -N -L 5555:127.0.0.1:5555 <user>@<서버IP>
  adb connect 127.0.0.1:5555 && scrcpy -s 127.0.0.1:5555
EOF
