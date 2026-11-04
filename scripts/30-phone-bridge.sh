#!/data/data/com.termux/files/usr/bin/bash
# 30-phone-bridge.sh — 폰 기능 브리지 설치 (Plan A/B 공통, Termux에서 실행)
#  - ~/.hermes-bridge/phone-bridge  : 허용목록 게이트웨이
#  - ~/.hermes-bridge/policy.conf    : 동작별 allow/confirm/deny
#  - Plan B용: 로컬 전용 sshd + 강제명령 키 (proot → Termux 호출 경로)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BH="$HOME/.hermes-bridge"
mkdir -p "$BH/client"; chmod 700 "$BH" "$BH/client"

pkg install -y openssh jq termux-api coreutils

install -m 700 "$HERE/bridge/phone-bridge" "$BH/phone-bridge"
install -m 755 "$HERE/bridge/phone" "$PREFIX/bin/phone"       # Plan A: Termux에서 바로 사용
# Termux에는 /usr/bin/env가 없음. 대화형 셸에선 termux-exec가 우회해주지만
# Termux:Boot·RUN_COMMAND·크론 같은 자동 실행에선 실패하므로 shebang을 Termux 경로로 고정
sed -i "1s|^#!/usr/bin/env bash|#!$PREFIX/bin/bash|" "$PREFIX/bin/phone"
install -m 755 "$HERE/bridge/phone" "$BH/client/phone"         # Plan B: proot 게스트 PATH에 노출
install -m 700 "$HERE/bridge/phone-hands-pair" "$PREFIX/bin/phone-hands-pair"   # Hermes Hands 토큰 연결(사람 전용)
[ -f "$BH/policy.conf" ] || install -m 600 "$HERE/bridge/policy.conf.example" "$BH/policy.conf"

# ---- sshd: 로컬호스트 전용, 키 인증만 ----
SSHD_CFG="$PREFIX/etc/ssh/sshd_config"
cp -n "$SSHD_CFG" "$SSHD_CFG.orig" 2>/dev/null || true
if ! grep -q '# hermes-fold7 hardening' "$SSHD_CFG"; then
  cat >> "$SSHD_CFG" <<'EOF'

# hermes-fold7 hardening
ListenAddress 127.0.0.1
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 3
EOF
fi
echo "※ PC에서 폰으로 SSH 접속이 필요하면 ListenAddress를 직접 조정하세요(기본은 로컬 전용)."

# ---- 브리지 전용 키 (강제명령, 포워딩 금지, 127.0.0.1 에서만) ----
if [ ! -f "$BH/client/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N '' -C 'hermes-phone-bridge' -f "$BH/client/id_ed25519" >/dev/null
fi
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
PUB="$(cat "$BH/client/id_ed25519.pub")"
grep -vF 'hermes-phone-bridge' "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp" || true
printf 'command="%s",restrict,from="127.0.0.1" %s\n' "$BH/phone-bridge" "$PUB" >> "$HOME/.ssh/authorized_keys.tmp"
mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"

# ---- sshd 재시작 + 호스트키 고정(known_hosts) ----
pkill -x sshd 2>/dev/null || true
sshd
sleep 1
ssh-keyscan -p 8022 -t ed25519 127.0.0.1 2>/dev/null > "$BH/client/known_hosts"
chmod 600 "$BH/client/known_hosts"

echo "==> 자체 테스트"
phone battery && echo "✅ Plan A 경로 OK"
if ssh -q -T -p 8022 -i "$BH/client/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
     -o UserKnownHostsFile="$BH/client/known_hosts" 127.0.0.1 "$(printf battery | base64)" >/dev/null; then
  echo "✅ Plan B(SSH 강제명령) 경로 OK"
fi
echo "감사 로그: $BH/audit.log"
