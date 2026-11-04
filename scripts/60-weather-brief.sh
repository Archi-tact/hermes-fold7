#!/usr/bin/env bash
# 60-weather-brief.sh — 매일 아침 날씨 브리핑 자동화 (Hermes cron 작업 등록)
#
# 폰(Termux):   bash scripts/60-weather-brief.sh            # Plan A
#               HERMES_CMD=hermes-proot bash scripts/60-weather-brief.sh   # Plan B
#   → 예약 실행은 게이트웨이가 돌고 있어야 함: bash scripts/50-autostart.sh apt|proot --gateway
# 바로 한 번 실행:  RUN_NOW=1 bash scripts/60-weather-brief.sh
#
# 환경변수
#   WEATHER_CITY   (기본: 서울)
#   WEATHER_TIME   cron 형식, 기본 "50 6 * * *" = 매일 06:50
#   WEATHER_DELIVER 기본 local(~/.hermes/cron/output). 텔레그램 연결 후엔 telegram:<chat_id> 등
#   NVIDIA_MODEL   기본 nvidia/nemotron-3-ultra-550b-a55b (NVIDIA_API_KEY는 hermes config set 으로 .env에)
set -euo pipefail
H="${HERMES_CMD:-hermes}"
CITY="${WEATHER_CITY:-서울}"
WHEN="${WEATHER_TIME:-50 6 * * *}"
TZ_NAME="${WEATHER_TZ:-Asia/Seoul}"
DELIVER="${WEATHER_DELIVER:-local}"
NAME="weather-brief"

PROMPT="오늘 ${CITY} 날씨를 웹에서 찾아 한국어로 브리핑해 줘.
- web_search / web_extract 도구로 최신 정보를 확인 (예: wttr.in, open-meteo, 기상청). 추측하지 말 것.
- 형식 (6줄, 첫 줄 제목 반드시 포함):
  ☀️ ${CITY} 날씨 브리핑 (YYYY-MM-DD 요일)
  현재: 기온/체감, 하늘 상태
  오늘: 최저/최고, 강수확률
  공기: 미세먼지(확인 가능할 때만)
  조언: 옷차림·우산 한 줄
  출처: URL 1개
- 확인하지 못한 항목은 '확인 불가'라고 쓸 것."

# 에이전트가 보는 '현재 시각'을 현지 시간대로 (기본은 서버 시간, 폰/서버가 UTC면 날짜가 어긋남)
"$H" config set timezone "$TZ_NAME" >/dev/null

# 같은 이름 작업이 있으면 교체
if "$H" cron list 2>/dev/null | grep -q "$NAME"; then
  "$H" cron remove "$NAME" >/dev/null 2>&1 || true
fi
"$H" cron create "$WHEN" --name "$NAME" --timezone "$TZ_NAME" --deliver "$DELIVER" "$PROMPT"
"$H" cron list

if [ "${RUN_NOW:-0}" = 1 ]; then
  echo "==> 지금 한 번 실행"
  "$H" cron run "$NAME"
  "$H" cron tick
  echo "==> 결과"
  OUT_DIR="${HERMES_HOME:-$HOME/.hermes}/cron/output"
  f="$(ls -t "$OUT_DIR"/*/* 2>/dev/null | head -1 || true)"
  if [ -n "$f" ]; then cat "$f"; else echo "(출력 파일 없음 — '$H cron runs $NAME' 확인)"; "$H" cron runs "$NAME" --limit 3 || true; fi
fi
