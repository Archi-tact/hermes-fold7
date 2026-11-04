#!/usr/bin/env bash
# lab/redroid/install-termux.sh — redroid에 Termux 3종 설치 후, 키트를 '폰에서 하듯' 그대로 실행
#   sudo PLAN=auto bash lab/redroid/install-termux.sh      # auto: A 시도 → 실패 시 B
#   PLAN=apt | proot 로 고정 가능
#   (선택) lab/redroid/secrets.env 에 OPENROUTER_API_KEY=... 등을 넣으면 Hermes 실제 대화 스모크 테스트까지 수행
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$LAB/../.." && pwd)"
# shellcheck source=lib.sh
. "$LAB/lib.sh"
PLAN="${PLAN:-auto}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

adb_root

# ---------- 1. APK 다운로드 (GitHub 공식 릴리스, 3개 모두 같은 서명 출처) ----------
gh_asset() {  # gh_asset <owner/repo> <name-regex> <out>
  local json url name
  json="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "https://api.github.com/repos/$1/releases/latest")"
  name="$(jq -r --arg re "$2" '[.assets[].name | select(test($re))][0] // empty' <<<"$json")"
  [ -n "$name" ] || { echo "❌ $1 에서 $2 에 맞는 APK 없음" >&2; return 1; }
  url="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$json")"
  curl -fsSL "$url" -o "$3"
  # 릴리스에 체크섬 파일이 있으면 검증
  local sums
  sums="$(jq -r '[.assets[] | select(.name|test("sha256";"i")) | .browser_download_url][0] // empty' <<<"$json")"
  if [ -n "$sums" ]; then
    curl -fsSL "$sums" -o "$WORK/sums"
    grep -F "$name" "$WORK/sums" | awk '{print $1}' | grep -qx "$(sha256sum "$3" | awk '{print $1}')" \
      && echo "  ✓ sha256 일치: $name" || { echo "❌ sha256 불일치: $name" >&2; return 1; }
  else
    echo "  (체크섬 파일 없음) $name sha256=$(sha256sum "$3" | awk '{print $1}')"
  fi
}
ABI="$(AS getprop ro.product.cpu.abi)"
case "$ABI" in
  arm64-v8a) APK_RE='arm64-v8a.*\.apk$|universal.*\.apk$' ;;
  x86_64)    APK_RE='x86_64.*\.apk$|universal.*\.apk$'
             [ "$PLAN" = apt ] && { echo "❌ Plan A(공식 Termux 패키지)는 aarch64 전용 — x86_64에선 PLAN=proot" >&2; exit 1; }
             PLAN=proot; export LAB_X86=1 ;;
  *) echo "❌ 지원하지 않는 ABI: $ABI" >&2; exit 1 ;;
esac
log "APK 다운로드 (ABI=$ABI, PLAN=$PLAN)"
gh_asset termux/termux-app  "$APK_RE" "$WORK/termux.apk"
gh_asset termux/termux-api  '\.apk$' "$WORK/termux-api.apk"
gh_asset termux/termux-boot '\.apk$' "$WORK/termux-boot.apk"

# ---------- 2. 설치 + 권한 (실제 폰에서 사용자가 누르는 것들을 미리 허용) ----------
log "APK 설치"
for a in termux termux-api termux-boot; do A install -r -g "$WORK/$a.apk" >/dev/null; done
for p in POST_NOTIFICATIONS ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION CAMERA READ_CONTACTS READ_SMS SEND_SMS CALL_PHONE; do
  AS pm grant com.termux.api "android.permission.$p" 2>/dev/null || true
done
AS pm grant com.termux android.permission.POST_NOTIFICATIONS 2>/dev/null || true
AS appops set com.termux MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true
# termux-dialog(확인창)가 백그라운드에서 뜨려면 '다른 앱 위에 표시' 필요 — 실폰에서도 동일!
AS appops set com.termux SYSTEM_ALERT_WINDOW allow
AS appops set com.termux.api SYSTEM_ALERT_WINDOW allow
AS dumpsys deviceidle whitelist +com.termux >/dev/null

# ---------- 3. Termux 첫 실행(부트스트랩) ----------
log "Termux 부트스트랩"
AS am start -n com.termux/.app.TermuxActivity >/dev/null
for i in $(seq 1 100); do AS test -x "$TP/bin/bash" && break; sleep 3; done
AS test -x "$TP/bin/bash" || { echo "❌ Termux 부트스트랩 실패" >&2; exit 1; }
sleep 5

# RUN_COMMAND 허용 (테스트 서버 전용 설정 — 실폰에선 필요 없음)
printf 'allow-external-apps = true\n' > "$WORK/termux.properties"
push_termux "$WORK/termux.properties" ".termux/termux.properties" 600
cat > "$WORK/runner" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME"
bash "$HOME/.lab/$1.sh" > "$HOME/.lab/$1.log" 2>&1
echo $? > "$HOME/.lab/$1.rc"
EOF
push_termux "$WORK/runner" ".lab/runner" 700
AS am force-stop com.termux; sleep 1
AS am start -n com.termux/.app.TermuxActivity >/dev/null; sleep 4

# ---------- 4. 키트를 폰에 복사 ----------
log "키트 복사"
tar -C "$(dirname "$KIT")" -czf "$WORK/kit.tar.gz" --exclude='lab/redroid/secrets.env' "$(basename "$KIT")"
push_termux "$WORK/kit.tar.gz" ".lab/kit.tar.gz" 600

# ---------- 5. 키트 단계 실행 (폰에서 사용자가 치는 명령 그대로) ----------
cat > "$WORK/s1.sh" <<'EOF'
set -e
rm -rf ~/hermes-fold7 && tar -xzf ~/.lab/kit.tar.gz -C ~
cd ~/hermes-fold7
HERMES_NONINTERACTIVE=1 HERMES_LAB_ALLOW_X86=1 bash scripts/00-termux-bootstrap.sh
EOF
log "00-termux-bootstrap"; tx_run s1 "$WORK/s1.sh" 3600

MODE=""
if [ "$PLAN" = apt ] || [ "$PLAN" = auto ]; then
  printf 'cd ~/hermes-fold7 && bash scripts/10-install-hermes-apt.sh\n' > "$WORK/s2a.sh"
  log "Plan A: 10-install-hermes-apt"
  if tx_run s2a "$WORK/s2a.sh" 3600; then MODE=apt
  else log "Plan A 실패 (rc=$?)"; [ "$PLAN" = apt ] && exit 1; fi
fi
if [ -z "$MODE" ]; then
  printf 'cd ~/hermes-fold7 && bash scripts/11-install-hermes-proot.sh\n' > "$WORK/s2b.sh"
  log "Plan B: 11-install-hermes-proot"
  tx_run s2b "$WORK/s2b.sh" 5400; MODE=proot
fi
echo "$MODE" > "$WORK/mode"; push_termux "$WORK/mode" ".hermes-bridge/mode" 600

cat > "$WORK/s3.sh" <<EOF
set -e
cd ~/hermes-fold7
bash scripts/30-phone-bridge.sh
# redroid는 무선 디버깅 대신 자체 adbd(5555) 사용 → 브리지에 고정 엔드포인트 지정
echo 127.0.0.1:5555 > ~/.hermes-bridge/adb-endpoint
adb start-server >/dev/null 2>&1; adb kill-server >/dev/null 2>&1 || true
HERMES_MODE=$MODE bash scripts/20-harden.sh
EOF
log "30-phone-bridge + 20-harden ($MODE)"; tx_run s3 "$WORK/s3.sh" 1800

# Termux의 adb 키를 redroid adbd 에 등록 (실폰의 '무선 디버깅 페어링'에 해당)
PUB="$(AS cat "$TH/.android/adbkey.pub" 2>/dev/null || true)"
if [ -n "$PUB" ]; then
  AS "grep -qF '${PUB%% *}' /data/misc/adb/adb_keys 2>/dev/null || echo '$PUB' >> /data/misc/adb/adb_keys; chmod 640 /data/misc/adb/adb_keys; chown system:shell /data/misc/adb/adb_keys"
fi

# ---------- 6. (선택) API 키 + 실제 에이전트 스모크 테스트 ----------
if [ -f "$LAB/secrets.env" ]; then
  log "API 키 설정 + 에이전트 스모크 테스트"
  push_termux "$LAB/secrets.env" ".lab/secrets.env" 600
  H=hermes; [ "$MODE" = proot ] && H=hermes-proot
  cat > "$WORK/s4.sh" <<EOF
set -e
while IFS='=' read -r k v; do
  [[ -z "\$k" || "\$k" == \#* ]] && continue
  $H config set "\$k" "\$v" >/dev/null
done < ~/.lab/secrets.env
shred -u ~/.lab/secrets.env 2>/dev/null || rm -f ~/.lab/secrets.env
[ -n "\${LAB_MODEL:-}" ] && $H config set model.default "\$LAB_MODEL" >/dev/null || true
$H chat -q "Use the fold7-phone skill: run 'phone battery' and reply with only the battery percentage number."
EOF
  tx_run s4 "$WORK/s4.sh" 900 || log "스모크 테스트 실패 — 모델/키 설정 확인 (hermes setup)"
fi

log "완료: MODE=$MODE  →  sudo bash lab/redroid/e2e-test.sh"
