#!/bin/bash
# ARM64 컨테이너 내부: Termux 쪽(sshd + phone-bridge)과 proot 게스트 쪽(phone 클라이언트)을 재현해
# Plan B의 SSH 강제명령 경로와 보안 제약을 검증한다. termux-* 는 스텁(가짜)이다.
set -uo pipefail
PASS=0; FAIL=0
check() { if eval "$2"; then echo "OK   $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# --- Termux 경로/사용자 재현 ---
mkdir -p /data/data/com.termux/files/usr/bin
ln -sf /bin/bash /data/data/com.termux/files/usr/bin/bash
adduser -D -h /home/termux termux >/dev/null 2>&1
sed -i 's/^termux:!/termux:*/' /etc/shadow
TH=/home/termux; BH=$TH/.hermes-bridge
mkdir -p $BH/client $TH/.ssh $TH/work
install -m 700 /kit/bridge/phone-bridge $BH/phone-bridge
install -m 600 /kit/bridge/policy.conf.example $BH/policy.conf

# --- termux-* 스텁 ---
cat > /usr/local/bin/termux-battery-status <<'EOF'
#!/bin/sh
echo '{"percentage":77,"status":"DISCHARGING"}'
EOF
cat > /usr/local/bin/termux-dialog <<'EOF'
#!/bin/sh
echo "{\"code\":-1,\"text\":\"$(cat /tmp/dialog-answer 2>/dev/null || echo no)\"}"
EOF
cat > /usr/local/bin/termux-sms-send <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/sms-sent
EOF
chmod 755 /usr/local/bin/termux-*

# --- 30-phone-bridge.sh 와 같은 sshd 하드닝 + 강제명령 키 ---
ssh-keygen -q -A
cat > /etc/ssh/sshd_lab <<'EOF'
Port 8022
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 3
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
ssh-keygen -q -t ed25519 -N '' -C hermes-phone-bridge -f $BH/client/id_ed25519
printf 'command="%s",restrict,from="127.0.0.1" %s\n' "$BH/phone-bridge" "$(cat $BH/client/id_ed25519.pub)" > $TH/.ssh/authorized_keys
chown -R termux:termux $TH; chmod 700 $TH/.ssh $BH; chmod 600 $TH/.ssh/authorized_keys
/usr/sbin/sshd.pam -f /etc/ssh/sshd_lab -E /tmp/sshd.log
sleep 1

# --- proot 게스트 쪽 클라이언트 재현 ---
CK=/root/.hermes-bridge-client; mkdir -p $CK
cp $BH/client/id_ed25519 $CK/; chmod 600 $CK/id_ed25519
ssh-keyscan -p 8022 -t ed25519 127.0.0.1 2>/dev/null > $CK/known_hosts
install -m 755 /kit/bridge/phone /usr/local/bin/phone
SSH=(ssh -q -T -p 8022 -i $CK/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$CK/known_hosts termux@127.0.0.1)
export PHONE_BRIDGE_USER=termux

echo "== 기능"
out=$(phone battery);                         check "battery 허용(allow)"            '[[ "$out" == *percentage* ]]'
echo no > /tmp/dialog-answer
out=$(phone sms-send 010-1234-5678 "테스트 \$(id)")
check "sms-send: 화면 확인 거부 → 미발송"   '[[ "$out" == *"did not approve"* && ! -s /tmp/sms-sent ]]'
echo yes > /tmp/dialog-answer
out=$(phone sms-send 010-1234-5678 "테스트 \$(id)")
check "sms-send: 화면 확인 승인 → 발송"     '[[ "$out" == *\"ok\":true* ]] && grep -qF "테스트 \$(id)" /tmp/sms-sent'
out=$(phone adb-shell id);                    check "adb-shell 기본 금지(deny)"        '[[ "$out" == *"denied by policy"* ]]'
out=$(phone help);                            check "help 정책 출력"                   '[[ "$out" == *"sms-send=confirm"* ]]'

echo "== 우회 시도"
out=$("${SSH[@]}" 'battery; id' 2>&1);        check "원시 명령/메타문자 주입 차단"      '[[ "$out" == *"malformed token"* && "$out" != *uid=* ]]'
out=$("${SSH[@]}" "$(printf 'id' | base64)" 2>&1); check "목록 밖 동작 차단"            '[[ "$out" == *"unknown action"* ]]'
out=$(printf 'id\nexit\n' | ssh -p 8022 -i $CK/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$CK/known_hosts -T termux@127.0.0.1 2>&1)
check "대화형 셸 불가(강제명령, stdin 무시)"  '[[ "$out" == *"empty request"* && "$out" != *uid=* ]]'
out=$(ssh -p 8022 -i $CK/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$CK/known_hosts -tt termux@127.0.0.1 2>&1 </dev/null)
check "PTY 할당 거부(restrict)"               '[[ "$out" == *"PTY allocation request failed"* ]]'
out=$(timeout 15 ssh -p 8022 -i $CK/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$CK/known_hosts -W 127.0.0.1:8022 termux@127.0.0.1 2>&1 </dev/null); rc=$?
check "포트 포워딩(-W) 거부"                 '[ $rc -eq 255 ] && [[ "$out" == *"prohibited"* ]]'
out=$(ssh -p 8022 -o BatchMode=yes -o PubkeyAuthentication=no -o UserKnownHostsFile=$CK/known_hosts termux@127.0.0.1 true 2>&1); rc=$?
check "비밀번호 로그인 불가"                  '[ $rc -ne 0 ]'
check "8022는 127.0.0.1에만 바인딩"          '! netstat -ltn 2>/dev/null | grep -q "0.0.0.0:8022" && netstat -ltn 2>/dev/null | grep -q "127.0.0.1:8022"'
check "감사 로그 기록"                        'grep -q APPROVED $BH/audit.log && grep -q REJECTED $BH/audit.log'

echo; echo "---- audit.log"; cat $BH/audit.log
echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
