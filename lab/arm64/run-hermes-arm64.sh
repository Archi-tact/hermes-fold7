#!/usr/bin/env bash
# lab/arm64/run-hermes-arm64.sh — x86 서버에서 ARM64(qemu) 컨테이너로 Hermes 소스 설치 + 하드닝 설정 검증
#   요구: docker, (x86이면) binfmt arm64 등록:  docker run --privileged --rm tonistiigi/binfmt --install arm64
#   사용: HERMES_SRC=/path/to/hermes-agent bash lab/arm64/run-hermes-arm64.sh
set -euo pipefail
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${HERMES_SRC:?HERMES_SRC=hermes-agent 소스 경로}"
PROXY_ARGS=()
if [ -n "${HTTPS_PROXY:-}" ]; then   # 프록시 환경(클라우드 세션 등)
  PROXY_ARGS=(--network host -e HTTPS_PROXY -e NO_PROXY="${NO_PROXY:-}")
  [ -f /root/.ccr/ca-bundle.crt ] && PROXY_ARGS+=(-v /root/.ccr/ca-bundle.crt:/ca.crt:ro
     -e SSL_CERT_FILE=/ca.crt -e PIP_CERT=/ca.crt -e REQUESTS_CA_BUNDLE=/ca.crt -e NODE_EXTRA_CA_CERTS=/ca.crt)
fi
docker run --rm --platform linux/arm64 "${PROXY_ARGS[@]}" \
  -v "$SRC:/src:ro" -v "$KIT:/kit:ro" -v hermes-arm64-opt:/opt \
  python:3.14-bookworm bash /kit/lab/arm64/inside.sh
