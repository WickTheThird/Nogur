#!/bin/sh
set -eu

: "${TURN_HOST:?Set TURN_HOST, for example turn.bumbuindustries.com}"
: "${TURN_SHARED_SECRET:?Set TURN_SHARED_SECRET to the coturn shared secret}"

TURN_PORT="${TURN_PORT:-5349}"
TURN_USER_ID="${TURN_USER_ID:-nogur-smoke-test}"
TURN_EXPIRES="$(( $(date +%s) + 600 ))"
TURN_USERNAME="${TURN_EXPIRES}:${TURN_USER_ID}"
TURN_PASSWORD="$(printf '%s' "${TURN_USERNAME}" | openssl dgst -binary -sha1 -hmac "${TURN_SHARED_SECRET}" | openssl base64 -A)"

printf 'Testing TLS relay allocation through %s:%s\n' "${TURN_HOST}" "${TURN_PORT}"
turnutils_uclient \
  -S \
  -v \
  -u "${TURN_USERNAME}" \
  -w "${TURN_PASSWORD}" \
  -p "${TURN_PORT}" \
  "${TURN_HOST}"
