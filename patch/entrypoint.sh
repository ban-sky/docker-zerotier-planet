#!/bin/bash
#
# Container entrypoint: initialises the planet/moon, starts the controller,
# the ztncui web UI and the planet download server, then supervises them.
#
# Security notes:
#  - no `set -x`: secrets must never end up in the container log
#  - the admin password is random and written to a 0600 file (not logged)
#  - TLS is on by default; a self-signed certificate is generated if needed
#  - ZeroTier One runs as root (the daemon refuses non-root); ztncui and the
#    file server run as the unprivileged "node" user (uid/gid 1000)
#
# GPLv3 - see LICENSE.
set -Eeuo pipefail
umask 077

ZT_HOME="${ZT_HOME:-/var/lib/zerotier-one}"
CONFIG_DIR="${CONFIG_DIR:-/app/config}"
DIST_DIR="${DIST_DIR:-/app/dist}"
ZTNCUI_DIR="/app/ztncui/src"
ZT_PORT="${ZT_PORT:-9994}"
API_PORT="${API_PORT:-3443}"
FILE_SERVER_PORT="${FILE_SERVER_PORT:-3000}"
TLS_ENABLED="${TLS_ENABLED:-1}"
TLS_CERT="${TLS_CERT:-$CONFIG_DIR/tls/fullchain.pem}"
TLS_KEY="${TLS_KEY:-$CONFIG_DIR/tls/privkey.pem}"
ALLOW_QUERY_KEY="${ALLOW_QUERY_KEY:-0}"
REGENERATE_PLANET="${REGENERATE_PLANET:-1}"
IP_ADDR4="${IP_ADDR4:-}"
IP_ADDR6="${IP_ADDR6:-}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

for pair in "ZT_PORT:$ZT_PORT" "API_PORT:$API_PORT" "FILE_SERVER_PORT:$FILE_SERVER_PORT"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  valid_port "$value" || die "$name must be a number between 1 and 65535"
done

if [ "$(id -u)" -eq 0 ]; then
  RUN_AS_ROOT=1
else
  RUN_AS_ROOT=0
fi

as_app() {
  if [ "$RUN_AS_ROOT" -eq 1 ]; then
    setpriv --reuid="$APP_UID" --regid="$APP_GID" --init-groups -- env HOME=/tmp "$@"
  else
    "$@"
  fi
}

mkdir -p "$CONFIG_DIR" "$DIST_DIR" "$ZT_HOME" "$ZT_HOME/moons.d" "$CONFIG_DIR/tls" "$CONFIG_DIR/ztncui-storage"
if [ "$RUN_AS_ROOT" -eq 1 ]; then
  chown -R "$APP_UID:$APP_GID" "$CONFIG_DIR" "$DIST_DIR" "$ZT_HOME"
fi
chmod 700 "$CONFIG_DIR" "$ZT_HOME"

# ---------------------------------------------------------------------------
# Public address detection (the address clients use to reach this host)
# ---------------------------------------------------------------------------
if [ -z "$IP_ADDR4" ] && [ -z "$IP_ADDR6" ]; then
  IP_ADDR4=$(as_app node -e '
    const os = require("os");
    for (const list of Object.values(os.networkInterfaces())) {
      for (const item of list || []) {
        if (item.family === "IPv4" && !item.internal) { console.log(item.address); process.exit(0); }
      }
    }
    process.exit(1);
  ') || die "no IPv4 address found; set IP_ADDR4 to the public address of this host"
  log "WARNING: IP_ADDR4 was not set; detected $IP_ADDR4 (set the public address for remote clients)"
fi

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
if [ "$TLS_ENABLED" = "1" ]; then
  if [ ! -s "$TLS_CERT" ] || [ ! -s "$TLS_KEY" ]; then
    log "generating a self-signed TLS certificate (set TLS_ENABLED=0 to disable TLS)"
    SAN="DNS:localhost,IP:127.0.0.1"
    if [ -n "$IP_ADDR4" ] && as_app node -e 'process.exit(require("net").isIP(process.argv[1]) === 4 ? 0 : 1)' "$IP_ADDR4"; then
      SAN="$SAN,IP:$IP_ADDR4"
    fi
    if [ -n "$IP_ADDR6" ] && as_app node -e 'process.exit(require("net").isIP(process.argv[1]) === 6 ? 0 : 1)' "$IP_ADDR6"; then
      SAN="$SAN,IP:$IP_ADDR6"
    fi
    as_app openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -sha256 -nodes -days 825 -subj "/CN=zerotier-planet" \
      -addext "subjectAltName=$SAN" \
      -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1 \
      || die "failed to generate a self-signed certificate"
    chmod 600 "$TLS_KEY"
    chmod 644 "$TLS_CERT"
  fi
  log "TLS enabled: $TLS_CERT"
else
  log "WARNING: TLS is disabled; credentials and the download key will be sent in clear text"
  TLS_CERT=""
  TLS_KEY=""
fi

# ---------------------------------------------------------------------------
# ZeroTier identity, moon and planet
# ---------------------------------------------------------------------------
IDTOOL=/usr/sbin/zerotier-idtool
[ -x "$IDTOOL" ] || die "$IDTOOL is missing"

if [ ! -s "$ZT_HOME/identity.secret" ]; then
  log "generating a new ZeroTier identity"
  as_app bash -c "cd '$ZT_HOME' && '$IDTOOL' generate identity.secret identity.public >/dev/null"
fi
chmod 600 "$ZT_HOME/identity.secret"
chmod 644 "$ZT_HOME/identity.public"

if [ ! -s "$ZT_HOME/moon.json" ]; then
  log "creating the moon definition"
  as_app bash -c "cd '$ZT_HOME' && '$IDTOOL' initmoon identity.public > moon.json"
fi
chmod 600 "$ZT_HOME/moon.json"

MOON_ARGS=(--moon "$ZT_HOME/moon.json" --port "$ZT_PORT")
[ -n "$IP_ADDR4" ] && MOON_ARGS+=(--ipv4 "$IP_ADDR4")
[ -n "$IP_ADDR6" ] && MOON_ARGS+=(--ipv6 "$IP_ADDR6")
as_app node /app/configure-moon.js "${MOON_ARGS[@]}"

log "generating the moon file"
# genmoon writes <world-id>.moon into the current directory, not moons.d.
as_app bash -c "cd '$ZT_HOME' && '$IDTOOL' genmoon moon.json >/dev/null"
MOON_FILE=$(ls -t "$ZT_HOME"/*.moon 2>/dev/null | head -n 1 || true)
[ -n "$MOON_FILE" ] || die "genmoon did not produce a .moon file"
as_app cp -f "$MOON_FILE" "$ZT_HOME/moons.d/"
chmod 644 "$ZT_HOME/moons.d/$(basename "$MOON_FILE")"

if [ "$REGENERATE_PLANET" = "1" ] || [ ! -s "$DIST_DIR/planet" ]; then
  log "building planet from identity + moon"
  as_app /app/mkworld -i "$ZT_HOME/identity.secret" -m "$ZT_HOME/moon.json" -o "$DIST_DIR/planet"
fi
as_app cp "$MOON_FILE" "$DIST_DIR/"
chmod 644 "$DIST_DIR/planet" "$DIST_DIR"/*.moon 2>/dev/null || true

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
SESSION_SECRET_FILE="$CONFIG_DIR/session.secret"
if [ ! -s "$SESSION_SECRET_FILE" ]; then
  as_app bash -c "openssl rand -hex 32 > '$SESSION_SECRET_FILE'"
  chmod 600 "$SESSION_SECRET_FILE"
fi
SESSION_SECRET=$(cat "$SESSION_SECRET_FILE")
[ "${#SESSION_SECRET}" -ge 32 ] || die "invalid session secret"

FILE_KEY_FILE="$CONFIG_DIR/file_server.key"
if [ -n "${FILE_KEY:-}" ] && [ "${#FILE_KEY}" -lt 32 ]; then
  die "FILE_KEY must be at least 32 characters"
fi
if [ -n "${FILE_KEY:-}" ]; then
  printf '%s\n' "$FILE_KEY" > "$FILE_KEY_FILE"
  chmod 600 "$FILE_KEY_FILE"
  if [ "$RUN_AS_ROOT" -eq 1 ]; then chown "$APP_UID:$APP_GID" "$FILE_KEY_FILE"; fi
fi

# ---------------------------------------------------------------------------
# Start ZeroTier and wait for its API token
# ---------------------------------------------------------------------------
log "starting zerotier-one on UDP port $ZT_PORT"
# ZeroTier refuses to start unless uid 0 ("must be run as root"). Run only this
# process as root; ztncui and the file server still drop to APP_UID.
/usr/sbin/zerotier-one -p"$ZT_PORT" &
ZT_PID=$!

TOKEN=""
for _ in $(seq 1 120); do
  if [ -s "$ZT_HOME/authtoken.secret" ]; then
    TOKEN=$(cat "$ZT_HOME/authtoken.secret")
    break
  fi
  kill -0 "$ZT_PID" 2>/dev/null || die "zerotier-one exited during startup"
  sleep 0.5
done
[ -n "$TOKEN" ] || die "timed out waiting for authtoken.secret"
chmod 600 "$ZT_HOME/authtoken.secret"
log "zerotier-one is up"

# ---------------------------------------------------------------------------
# Admin account (random one-time password, forced change on first login)
# ---------------------------------------------------------------------------
as_app env \
  ZTNCUI_PASSWD="$CONFIG_DIR/ztncui-passwd" \
  ZTNCUI_ADMIN_PASSWORD_FILE="$CONFIG_DIR/admin-password" \
  node "$ZTNCUI_DIR/tools/init-admin.js"

# ---------------------------------------------------------------------------
# Start ztncui and the planet file server
# ---------------------------------------------------------------------------
log "starting ztncui on port $API_PORT"
if [ "$TLS_ENABLED" = "1" ]; then
  UI_HTTP_PORT=0
  UI_HTTPS_PORT="$API_PORT"
  UI_HTTP_HOST="127.0.0.1"
else
  UI_HTTP_PORT="$API_PORT"
  UI_HTTPS_PORT=0
  UI_HTTP_HOST="0.0.0.0"
fi
as_app env \
  NODE_ENV=production \
  ZT_ADDR="127.0.0.1:$ZT_PORT" \
  ZT_TOKEN="$TOKEN" \
  HTTP_PORT="$UI_HTTP_PORT" \
  HTTPS_PORT="$UI_HTTPS_PORT" \
  HTTP_HOST="$UI_HTTP_HOST" \
  TLS_ENABLED="$TLS_ENABLED" \
  TLS_CERT="$TLS_CERT" \
  TLS_KEY="$TLS_KEY" \
  SESSION_SECRET="$SESSION_SECRET" \
  ZTNCUI_PASSWD="$CONFIG_DIR/ztncui-passwd" \
  ZTNCUI_STORAGE="$CONFIG_DIR/ztncui-storage" \
  ZTNCUI_ADMIN_PASSWORD_FILE="$CONFIG_DIR/admin-password" \
  node "$ZTNCUI_DIR/bin/www" &
UI_PID=$!

log "starting planet file server on port $FILE_SERVER_PORT"
as_app env \
  DIST_DIR="$DIST_DIR" \
  FILE_SERVER_PORT="$FILE_SERVER_PORT" \
  TLS_ENABLED="$TLS_ENABLED" \
  TLS_CERT="$TLS_CERT" \
  TLS_KEY="$TLS_KEY" \
  FILE_KEY_FILE="$FILE_KEY_FILE" \
  ALLOW_QUERY_KEY="$ALLOW_QUERY_KEY" \
  node /app/http_server.js &
FS_PID=$!

cat <<EOF

================================================================
 ZeroTier planet is ready.

 Controller UI : https://<server-ip>:$API_PORT
 Planet file  : https://<server-ip>:$FILE_SERVER_PORT/planet
 Moon file    : https://<server-ip>:$FILE_SERVER_PORT/<id>.moon

 Download (header auth, no key in URL):
   curl -fsS -H "Authorization: Bearer \$(cat $FILE_KEY_FILE)" \\
     https://<server-ip>:$FILE_SERVER_PORT/planet -o planet

 Initial admin password is in $CONFIG_DIR/admin-password
 (mode 0600, deleted after the first password change).

 Open UDP $ZT_PORT/udp on the firewall for ZeroTier clients.
================================================================
EOF

shutdown() {
  log "shutting down"
  kill "$ZT_PID" "$UI_PID" "$FS_PID" 2>/dev/null || true
  wait "$ZT_PID" "$UI_PID" "$FS_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# Exit (and let the container restart) if any supervised process dies.
set +e
wait -n "$ZT_PID" "$UI_PID" "$FS_PID"
STATUS=$?
set -e
log "a child process exited with status $STATUS; stopping the container"
kill "$ZT_PID" "$UI_PID" "$FS_PID" 2>/dev/null || true
wait "$ZT_PID" "$UI_PID" "$FS_PID" 2>/dev/null || true
exit "$STATUS"
