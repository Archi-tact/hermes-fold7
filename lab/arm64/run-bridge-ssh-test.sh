#!/usr/bin/env bash
# lab/arm64/run-bridge-ssh-test.sh — Plan B 폰 브리지(SSH 강제명령) 보안 테스트를 ARM64 컨테이너에서 실행 (네트워크 차단 상태)
set -euo pipefail
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
docker run --rm --platform linux/arm64 --network none -v "$KIT:/kit:ro" \
  --entrypoint bash linuxserver/openssh-server /kit/lab/arm64/bridge-ssh-inside.sh
