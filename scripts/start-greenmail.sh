#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "$*" >&2
}

CONTAINER_NAME=${GREENMAIL_CONTAINER_NAME:-swiftimap-greenmail}
IMAGE=${GREENMAIL_DOCKER_IMAGE:-greenmail/standalone:2.0.0}
HOST=${GREENMAIL_HOST:-127.0.0.1}
IMAP_PORT=${GREENMAIL_IMAP_PORT:-3143}
IMAPS_PORT=${GREENMAIL_IMAPS_PORT:-3993}
SMTP_PORT=${GREENMAIL_SMTP_PORT:-3025}
USER=${GREENMAIL_USER:-test}
DOMAIN=${GREENMAIL_DOMAIN:-example.com}
PASSWORD=${GREENMAIL_PASSWORD:-test}
GREENMAIL_OPTS=${GREENMAIL_OPTS:-"-Dgreenmail.imap.hostname=0.0.0.0 -Dgreenmail.imap.port=3143 -Dgreenmail.imaps.hostname=0.0.0.0 -Dgreenmail.imaps.port=3993 -Dgreenmail.smtp.hostname=0.0.0.0 -Dgreenmail.smtp.port=3025 -Dgreenmail.users.login=email -Dgreenmail.users=${USER}:${PASSWORD}@${DOMAIN}"}

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

log "Starting GreenMail container: $CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "$IMAP_PORT":3143 \
  -p "$IMAPS_PORT":3993 \
  -p "$SMTP_PORT":3025 \
  -e "GREENMAIL_OPTS=${GREENMAIL_OPTS}" \
  "$IMAGE" >/dev/null

log "GreenMail running at ${HOST}:${IMAP_PORT} (IMAP) / ${HOST}:${IMAPS_PORT} (IMAPS)"
log "User: ${USER}@${DOMAIN}"

cat <<EOF
export GREENMAIL_HOST=${HOST}
export GREENMAIL_IMAP_PORT=${IMAP_PORT}
export GREENMAIL_USER=${USER}
export GREENMAIL_DOMAIN=${DOMAIN}
export GREENMAIL_PASSWORD=${PASSWORD}
EOF
