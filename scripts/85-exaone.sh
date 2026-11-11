#!/usr/bin/env bash
# scripts/85-exaone.sh — K-EXAONE 2.5 (LG AI연구원 API) 를 Hermes 모델로 연결
#
#   bash scripts/85-exaone.sh              # 등록 + 키 입력(화면에 안 보임) + 연결 확인 + 기본 모델로 지정
#   bash scripts/85-exaone.sh test         # 저장된 키로 연결만 확인
#   bash scripts/85-exaone.sh effort low   # 추론 강도: low(빠름) | high(기본) | max(정확·느림) — Hermes Fold 위쪽 🧠 버튼으로도 바꿈
#
# 메모:
#   · OpenAI 호환 API → Hermes 의 이름 붙은 제공자(custom:exaone) 로 등록. 키는 .env(600) 의 EXAONE_API_KEY 에만.
#   · Hermes 는 강도를 지정하지 않으면 reasoning_effort=medium 을 보내는데 EXAONE 은 low/high/max 만 받음
#     → agent.reasoning_effort 를 high 로 맞춤 (Fold 화면 🧠 버튼이 바꾸는 값과 같음 · 화면은 EXAONE 일 때 보통을 숨김)
#   · 연결 확인이 실패하면 기본 모델은 바꾸지 않음 (쓰던 모델이 그대로 동작).
#   · proot-distro 는 인자를 셸로 다시 해석할 수 있어 키는 인자가 아니라 stdin 스크립트로 전달.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${HERMES_MODE:-$(cat "$HOME/.hermes-bridge/mode" 2>/dev/null || echo apt)}"
BASE="${EXAONE_BASE:-https://api.exaone.ai/v1}"
MODEL="k-exaone_v2.5"
if [ "$MODE" = proot ]; then
  HC=hermes-proot; HH=/root/.hermes
  G() { proot-distro login "${PROOT_DISTRO:-debian}" -- /usr/bin/env -i HOME=/root PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin "$@"; }
else
  HC="${HERMES_CMD:-hermes}"; HH="${HERMES_HOME:-$HOME/.hermes}"
  G() { "$@"; }
fi
guest_sh() { G /bin/sh -s; }
say() { printf '\033[1;36m[exaone]\033[0m %s\n' "$*"; }

register() {
  $HC config set providers.exaone.api "$BASE" >/dev/null
  $HC config set providers.exaone.key_env EXAONE_API_KEY >/dev/null
  $HC config set providers.exaone.transport chat_completions >/dev/null
  $HC config set providers.exaone.default_model "$MODEL" >/dev/null
  $HC config set providers.exaone.context_length 524288 >/dev/null
  $HC config set providers.exaone.discover_models false >/dev/null
  $HC config unset providers.exaone.extra_body.reasoning_effort >/dev/null 2>&1 || true   # 예전 버전이 고정해 둔 값 (화면에서 바꿔도 안 먹던 원인)
  $HC config set providers.exaone.extra_body.chat_template_kwargs.preserve_thinking true >/dev/null   # 문서 권장 (에이전트·멀티턴)
}

has_key() { printf 'grep -q "^EXAONE_API_KEY=." "%s/.env" 2>/dev/null\n' "$HH" | guest_sh; }

save_key() {
  { printf 'KEY="$(cat <<'"'"'__K__'"'"'\n%s\n__K__\n)"\nENV="%s/.env"\n' "$1" "$HH"; cat <<'__S__'
set -e
umask 077
mkdir -p "$(dirname "$ENV")"; touch "$ENV"
{ grep -v '^EXAONE_API_KEY=' "$ENV" || true; printf 'EXAONE_API_KEY=%s\n' "$KEY"; } > "$ENV.tmp"
mv "$ENV.tmp" "$ENV"; chmod 600 "$ENV"
__S__
  } | guest_sh
}

test_api() {   # 키는 curl -K - (stdin) 로만 전달 → 프로세스 목록에 안 나옴
  { printf 'ENV="%s/.env"\nURL="%s/chat/completions"\nMODEL="%s"\n' "$HH" "$BASE" "$MODEL"; cat <<'__S__'
KEY="$(sed -n 's/^EXAONE_API_KEY=//p' "$ENV" | tail -1)"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
BODY='{"model":"'"$MODEL"'","max_tokens":800,"reasoning_effort":"low","messages":[{"role":"user","content":"Reply with one short greeting."}]}'
CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -sS --max-time 120 -o "$OUT" -w '%{http_code}' -K - -H 'Content-Type: application/json' -d "$BODY" "$URL" || echo 000)"
case "$CODE" in
  200) echo "✅ 연결 성공 (HTTP 200)"; exit 0 ;;
  401|403) echo "❌ 키가 맞지 않습니다 (HTTP $CODE). 키를 다시 복사해 실행해 주세요." ;;
  429) echo "❌ 호출 한도 초과 (HTTP 429). 잠시 뒤 다시 실행해 주세요." ;;
  000) echo "❌ 서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요." ;;
  *) echo "❌ 서버 오류 (HTTP $CODE): $(head -c 300 "$OUT")" ;;
esac
exit 1
__S__
  } | guest_sh
}

effort_now() { $HC config get agent.reasoning_effort 2>/dev/null | tr -d " \"'" | grep -oE '(none|minimal|low|medium|high|xhigh|max|ultra)$' | tail -1; }

set_main() {
  case "$(effort_now)" in low|high|max) ;; *) $HC config set agent.reasoning_effort "${EXAONE_EFFORT:-high}" >/dev/null ;; esac
  $HC config set model.provider custom:exaone >/dev/null
  $HC config set model.default "$MODEL" >/dev/null
  $HC config set model.base_url "" >/dev/null 2>&1 || true   # 전에 쓰던 제공자 주소가 남아 있으면 그쪽으로 요청이 감
}

restart_fold() {   # .env 는 화면 서버가 시작할 때 읽음. 음성 쪽(gateway)은 매 턴 다시 읽어서 재시작 불필요
  local p="$HOME/.hermes-fold/server.pid"
  if [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then
    say "Hermes Fold 화면 서버 재시작"
    bash "$KIT/scripts/80-hermes-fold.sh" stop >/dev/null 2>&1 || true
    bash "$KIT/scripts/80-hermes-fold.sh" start >/dev/null 2>&1 || echo "⚠ 화면 서버 재시작 실패: bash scripts/80-hermes-fold.sh start"
  fi
}

setup() {
  say "EXAONE 제공자 등록 ($MODEL)"
  register
  local key="${EXAONE_API_KEY:-}"
  if [ -z "$key" ]; then
    read -rsp "EXAONE API 키 붙여넣기 (화면에 안 보여요 · 이미 저장했으면 그냥 Enter): " key || true
    echo
  fi
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  if [ -n "$key" ]; then
    case "$key" in
      *[!A-Za-z0-9._~+/=:-]*) echo "❌ 키에 쓸 수 없는 글자가 있습니다. 키만 정확히 복사해 주세요." >&2; exit 1 ;;
    esac
    save_key "$key"
  elif ! has_key; then
    echo "❌ 키가 없습니다. https://docs.exaone.ai 에서 로그인해 발급한 키를 넣어 주세요." >&2; exit 1
  fi
  say "연결 확인 중 (최대 2분)"
  if ! test_api; then echo "기본 모델은 바꾸지 않았습니다." >&2; exit 1; fi
  set_main
  restart_fold
  cat <<EOF

✅ K-EXAONE 2.5 준비 완료 — 새 대화부터 적용돼요 (Hermes Fold · 음성 모두)
   답변이 느리면: bash scripts/85-exaone.sh effort low
   다른 AI 로 돌아가기: Hermes Fold 위쪽 모델 이름 누르기
EOF
}

case "${1:-setup}" in
  setup) setup ;;
  test) test_api ;;
  effort)
    case "${2:-}" in low|high|max) ;; *) echo "사용법: bash scripts/85-exaone.sh effort low|high|max" >&2; exit 1 ;; esac
    $HC config set agent.reasoning_effort "$2" >/dev/null
    say "추론 강도: $2 (새 대화부터 · 지금 대화는 Fold 화면 🧠 버튼으로)" ;;
  *) sed -n 2,6p "$0"; exit 1 ;;
esac
