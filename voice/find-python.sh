# . find-python.sh → $PY = Hermes 를 실행하는 파이썬 (edge-tts 를 깔고 쓰는 곳)
# 후보: 실행 중인 Hermes 프로세스의 파이썬, hermes 실행 파일(진입점·셸 래퍼) 안의 경로, Hermes 폴더 안의 venv.
# 실행 중인 Hermes 의 파이썬을 우선, 없으면 Hermes 의존성(openai, yaml)이 import 되는 것. 그래도 없으면 python3.
HH="${HERMES_HOME:-$HOME/.hermes}"
PY=""
_cands=""
for _p in $(pgrep -f "hermes" 2>/dev/null); do
  _a="$(tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null | head -1)"
  case "$_a" in */python*) [ -z "$PY" ] && [ -x "$_a" ] && PY="$_a" ;; esac   # 지금 Hermes 를 돌리는 파이썬이 정답
done
_hb="$(command -v hermes 2>/dev/null || true)"
if [ -n "$_hb" ]; then
  for _f in "$_hb" "$(readlink -f "$_hb" 2>/dev/null)"; do
    [ -f "$_f" ] || continue
    _cands="$_cands $(head -c 8000 "$_f" 2>/dev/null | grep -aoE '/[^ "'"'"':=]*/bin/python[0-9.]*' | tr '\n' ' ')"
    # 셸 래퍼가 가리키는 다른 실행 파일(같은 bin 폴더의 python) 도 후보
    _cands="$_cands $(dirname "$_f")/python"
  done
fi
_cands="$_cands $HH/hermes-agent/venv/bin/python $HH/hermes-agent/.venv/bin/python $HH/venv/bin/python"
_cands="$_cands $(find "$HH" "$HOME/.local/share/hermes" -maxdepth 6 -path '*/bin/python' 2>/dev/null | tr '\n' ' ')"
for _c in $_cands; do
  [ -z "$PY" ] || break
  [ -x "$_c" ] || continue
  "$_c" -c 'import openai, yaml' >/dev/null 2>&1 && { PY="$_c"; break; }
done
[ -n "$PY" ] || PY=python3
unset _cands _hb _f _c _p _a
