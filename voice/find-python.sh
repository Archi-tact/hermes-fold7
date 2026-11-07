# . find-python.sh → $PY = Hermes 를 실행하는 파이썬 (edge-tts 를 깔고 쓰는 곳)
# 순서: hermes 실행 파일의 #! 줄 → 알려진 venv 위치 → python3
HH="${HERMES_HOME:-$HOME/.hermes}"
PY=""
HB="$(command -v hermes 2>/dev/null || true)"
if [ -n "$HB" ]; then
  HB="$(readlink -f "$HB" 2>/dev/null || echo "$HB")"
  c="$(head -1 "$HB" 2>/dev/null | sed -n 's/^#! *\([^ ]*python[^ ]*\).*/\1/p')"
  [ -n "$c" ] && [ -x "$c" ] && PY="$c"
fi
for c in "$HH/hermes-agent/venv/bin/python" "$HH/hermes-agent/.venv/bin/python" "$HH/bin/hermes-python"; do
  [ -z "$PY" ] && [ -x "$c" ] && PY="$c"
done
[ -n "$PY" ] || PY=python3
