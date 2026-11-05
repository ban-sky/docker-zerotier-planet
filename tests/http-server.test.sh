#!/usr/bin/env bash
#
# Regression tests for the planet file server security properties.
# Requires node and curl; runs entirely in a temporary directory.
#
# GPLv3 - see LICENSE.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/dist"
printf 'planet-bytes\n' > "$TMP/dist/planet"
printf 'moon-bytes\n' > "$TMP/dist/0123456789abcdef.moon"
printf 'top-secret\n' > "$TMP/secret"
ln -s "$TMP/secret" "$TMP/dist/evil.moon"

DIST_DIR="$TMP/dist" \
FILE_SERVER_PORT="$PORT" \
FILE_SERVER_BIND=127.0.0.1 \
TLS_ENABLED=0 \
FILE_KEY_FILE="$TMP/file_server.key" \
node "$ROOT/patch/http_server.js" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }
  sleep 0.1
done

KEY="$(cat "$TMP/file_server.key")"
BASE="http://127.0.0.1:$PORT"
fail=0

check() {
  local want="$1" label="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   %-42s %s\n' "$label" "$got"
  else
    printf 'FAIL %-42s want %s got %s\n' "$label" "$want" "$got" >&2
    fail=1
  fi
}

status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

check 200 "healthz" "$(status "$BASE/healthz")"
check 401 "planet without key" "$(status "$BASE/planet")"
check 401 "planet with wrong key" "$(status -H 'Authorization: Bearer wrong' "$BASE/planet")"
check 200 "planet with bearer key" "$(status -H "Authorization: Bearer $KEY" "$BASE/planet")"
check 200 "planet with X-Api-Key" "$(status -H "X-Api-Key: $KEY" "$BASE/planet")"
check 200 "moon with bearer key" "$(status -H "Authorization: Bearer $KEY" "$BASE/0123456789abcdef.moon")"
check 401 "legacy query key disabled" "$(status "$BASE/planet?key=$KEY")"
check 404 "path traversal" "$(status --path-as-is -H "Authorization: Bearer $KEY" "$BASE/../secret")"
check 404 "encoded traversal" "$(status --path-as-is -H "Authorization: Bearer $KEY" "$BASE/%2e%2e/secret")"
check 404 "symlink escape" "$(status -H "Authorization: Bearer $KEY" "$BASE/evil.moon")"
check 404 "unknown file" "$(status -H "Authorization: Bearer $KEY" "$BASE/nope")"
check 405 "POST rejected" "$(status -X POST -H "Authorization: Bearer $KEY" "$BASE/planet")"

BODY="$(curl -fsS -H "Authorization: Bearer $KEY" "$BASE/planet")"
if [ "$BODY" = "planet-bytes" ]; then
  echo "ok   planet body"
else
  echo "FAIL planet body" >&2
  fail=1
fi

exit "$fail"
