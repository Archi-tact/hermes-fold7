# . find-python.sh → $PY = Hermes 를 실행하는 파이썬 (edge-tts 를 깔고 쓰는 곳)
# hermes 실행 파일(파이썬 진입점이든 셸 래퍼든)에서 파이썬 경로를 모으고, 알려진 venv 위치를 더한 뒤
# 'import hermes_cli' 가 되는 첫 번째를 고름. 하나도 없으면 python3.
HH="${HERMES_HOME:-$HOME/.hermes}"
PY=""
_cands=""
HB="$(command -v hermes 2>/dev/null || true)"
if [ -n "$HB" ]; then
  for f in "$HB" "$(readlink -f "$HB" 2>/dev/null)"; do
    [ -f "$f" ] || continue
    _cands="$_cands $(head -c 4000 "$f" 2>/dev/null | grep -aoE '/[^ "'"'"':]*/bin/python[0-9.]*' | tr '\n' ' ')"
  done
fi
_cands="$_cands $HH/hermes-agent/venv/bin/python $HH/hermes-agent/.venv/bin/python $HH/venv/bin/python $HH/bin/hermes-python"
_cands="$_cands $(find "$HH" "$HOME/.local/share" -maxdepth 4 -path '*/bin/python' 2>/dev/null | tr '\n' ' ')"
for c in $_cands; do
  [ -x "$c" ] && "$c" -c 'import hermes_cli' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || PY=python3
unset _cands HB f c
