#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME=${GREENMAIL_CONTAINER_NAME:-swiftimap-greenmail}
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
