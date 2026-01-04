#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

eval "$("${SCRIPT_DIR}/start-greenmail.sh")"
trap "${SCRIPT_DIR}/stop-greenmail.sh" EXIT

GREENMAIL_REQUIRED=1 swift test --filter GreenMailIntegrationTests
