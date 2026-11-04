#!/data/data/com.termux/files/usr/bin/bash
# 40-adb-pair.sh — 무선 디버깅으로 '폰 자기 자신'에 ADB 연결 (루트 불필요)
# 폴드7 팁: Termux와 설정 앱을 '분할 화면'으로 띄우면 페어링 코드가 사라지지 않습니다.
#
# 준비: 설정 > 휴대전화 정보 > 소프트웨어 정보 > '빌드번호' 7회 탭 → 개발자 옵션 활성화
#       설정 > 개발자 옵션 > 무선 디버깅 ON (Wi-Fi 연결 필요)
#       '페어링 코드로 기기 페어링' 누르기 → 코드/포트 표시
set -euo pipefail
pkg install -y android-tools

read -r -p "페어링 포트 (예: 37123): " PAIR_PORT
read -r -p "페어링 코드 6자리: " PAIR_CODE
adb pair "127.0.0.1:$PAIR_PORT" "$PAIR_CODE"

echo "무선 디버깅 화면의 'IP 주소 및 포트'의 포트 번호(페어링 포트와 다름)"
read -r -p "연결 포트: " CONN_PORT
adb connect "127.0.0.1:$CONN_PORT"
adb devices -l

cat <<'EOF'

✅ 페어링 완료. 이후엔 무선 디버깅만 켜두면 브리지가 자동 재연결(mDNS)합니다.
보안 메모:
 - `adb tcpip 5555`는 쓰지 마세요 (Wi-Fi 전체에 인증 없는 포트가 열림).
 - 무선 디버깅은 쓸 때만 켜고, 끝나면 끄는 것을 권장합니다.
 - 브리지는 각 adb 동작 후 adb 서버를 종료해서 다른 프로세스의 재사용을 막습니다.
EOF
