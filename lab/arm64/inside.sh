#!/usr/bin/env bash
# 컨테이너 내부: Hermes 설치 → 20-harden과 같은 설정 적용 → 차단 규칙 동작 확인
set -euo pipefail
echo "arch=$(uname -m) python=$(python3 -V)"
if [ ! -x /opt/venv/bin/hermes ]; then
  # Hermes는 wheel 빌드를 막아두었으므로 소스 + uv.lock(고정 버전)으로 동기화
  pip install -q uv
  rm -rf /opt/hermes-src; cp -r /src /opt/hermes-src   # 볼륨에 보존
  cd /opt/hermes-src
  UV_PROJECT_ENVIRONMENT=/opt/venv uv sync --frozen --no-dev --python "$(command -v python3)"
  cd /
fi
export PATH=/opt/venv/bin:$PATH HOME=/root
hermes --version
mkdir -p /root/work
WS=/root/work
set_cfg() { echo "+ hermes config set $1"; hermes config set "$1" "$2"; }
set_cfg approvals.mode manual
set_cfg approvals.timeout 120
set_cfg approvals.cron_mode deny
set_cfg approvals.single_query_mode deny
set_cfg approvals.unattended_mode deny
# 차단 목록은 실제 폰과 같게: scripts/20-harden.sh 의 DENY_JSON 을 그대로 읽어 씀 (복사본을 두면 어긋남)
DENY="$(python3 - <<'PY'
import json, re
s = open('/kit/scripts/20-harden.sh', encoding='utf-8').read()
m = re.search(r"DENY_JSON=\"\$\(jq -cn '(\[.*?\])'\)\"", s, re.S)
print(json.dumps(json.loads(m.group(1)), separators=(',', ':')))
PY
)"
[ -n "$DENY" ] || { echo "20-harden.sh 에서 차단 목록을 못 읽음"; exit 1; }
set_cfg approvals.deny "$DENY"
set_cfg terminal.cwd "$WS"
set_cfg HERMES_WRITE_SAFE_ROOT "$WS"
mkdir -p /root/skills && cp -r /kit/skills/. /root/skills/
set_cfg skills.external_dirs '["/root/skills"]'
set_cfg skills.guard_agent_created true
set_cfg unauthorized_dm_behavior ignore
echo "---- config.yaml (approvals/terminal/skills)"
sed -n '/^approvals:/,/^[a-z]/p' /root/.hermes/config.yaml | head -40
grep -nE '^\s+cwd:|external_dirs|guard_agent_created|unauthorized_dm_behavior' /root/.hermes/config.yaml
grep HERMES_WRITE_SAFE_ROOT /root/.hermes/.env
(cd /opt/hermes-src && python3 /kit/lab/arm64/check_deny.py)
echo "---- 스킬 인식 확인"
SL="$(hermes skills list 2>&1)"
for sk in fold7-phone fold7-hands; do grep -qi "$sk" <<<"$SL" && echo "SKILL $sk: OK" || { echo "SKILL $sk: NOT FOUND"; exit 1; }; done
