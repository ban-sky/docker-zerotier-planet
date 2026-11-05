#!/usr/bin/env bash
#
# Interactive deployment helper for docker-zerotier-planet.
#
# Unlike the original script this version:
#  - keeps prompts on stderr so command substitution cannot swallow them
#  - validates ports and addresses before touching Docker
#  - creates the data directories before `docker run` (works with podman too)
#  - never prints a hard-coded admin password; the container generates one
#  - asks before replacing an existing container
#
# GPLv3 - see LICENSE.
set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-myztplanet}"
IMAGE="${IMAGE:-docker-zerotier-planet:latest}"
DATA_ROOT="${DATA_ROOT:-$(pwd)/data/zerotier}"
DOCKER="${DOCKER:-docker}"
ZT_PORT="${ZT_PORT:-9994}"
API_PORT="${API_PORT:-3443}"
FILE_PORT="${FILE_PORT:-3000}"
IP_ADDR4="${IP_ADDR4:-}"
IP_ADDR6="${IP_ADDR6:-}"
ASSUME_YES=0
RECREATE=0

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [options]

Options:
  --name NAME        container name (default: myztplanet)
  --image IMAGE      image reference (default: docker-zerotier-planet:latest; built if missing)
  --data DIR         data root (default: ./data/zerotier)
  --zt-port PORT     host UDP port for ZeroTier (default: 9994)
  --api-port PORT    host TCP port for ztncui (default: 3443)
  --file-port PORT   host TCP port for the planet file server (default: 3000)
  --ipv4 ADDR        public IPv4 address or hostname (prompted if unset)
  --ipv6 ADDR        optional public IPv6 address
  -y, --yes          do not ask for confirmation when replacing a container
  --recreate         replace an existing container without asking
  -h, --help         show this help

Environment variables with the same names are also accepted.
EOF
}

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) CONTAINER_NAME="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --data) DATA_ROOT="${2:?}"; shift 2 ;;
    --zt-port) ZT_PORT="${2:?}"; shift 2 ;;
    --api-port) API_PORT="${2:?}"; shift 2 ;;
    --file-port) FILE_PORT="${2:?}"; shift 2 ;;
    --ipv4) IP_ADDR4="${2:?}"; shift 2 ;;
    --ipv6) IP_ADDR6="${2:?}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --recreate) RECREATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

prompt() {
  local label="$1" value="$2" default="${3:-}"
  if [ -n "$value" ]; then printf '%s' "$value"; return; fi
  [ -t 0 ] || die "$label is required (pass it as an option or environment variable)"
  printf '%s%s: ' "$label" "${default:+ [$default]}" >&2
  IFS= read -r value || die "no input for $label"
  printf '%s' "${value:-$default}"
}

for spec in "ZT_PORT:$ZT_PORT" "API_PORT:$API_PORT" "FILE_PORT:$FILE_PORT"; do
  name="${spec%%:*}"
  value="${spec#*:}"
  valid_port "$value" || die "$name must be between 1 and 65535"
done

command -v "$DOCKER" >/dev/null 2>&1 || die "$DOCKER is not installed or not in PATH"

if ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
  [ -f Dockerfile ] || die "image $IMAGE not found; build it first or set IMAGE"
  log "image $IMAGE not found; building it from ./Dockerfile"
  "$DOCKER" build -t "$IMAGE" .
fi

IP_ADDR4=$(prompt "Public IPv4 address or hostname" "$IP_ADDR4")
[ -n "$IP_ADDR4" ] || die "a public IPv4 address (or resolvable hostname) is required"
printf '%s' "$IP_ADDR4" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$' \
  || die "IP_ADDR4 contains unexpected characters"

if [ -z "$IP_ADDR6" ] && [ -t 0 ]; then
  printf 'Public IPv6 address (optional, press Enter to skip): ' >&2
  IFS= read -r IP_ADDR6 || true
fi
if [ -n "$IP_ADDR6" ]; then
  printf '%s' "$IP_ADDR6" | grep -Eq '^[0-9A-Fa-f:]+$' || die "IP_ADDR6 is not a valid IPv6 address"
fi

if "$DOCKER" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  if [ "$RECREATE" -eq 0 ]; then
    if [ "$ASSUME_YES" -eq 1 ] || [ -t 0 ]; then
      if [ "$ASSUME_YES" -eq 0 ]; then
        printf 'Container %s already exists. Replace it? [y/N] ' "$CONTAINER_NAME" >&2
        IFS= read -r answer || answer=""
        case "$answer" in y|Y|yes|YES) ;; *) die "aborted; existing container left untouched" ;; esac
      fi
    else
      die "container $CONTAINER_NAME already exists; rerun with --recreate"
    fi
  fi
  log "removing existing container $CONTAINER_NAME"
  "$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null
fi

mkdir -p "$DATA_ROOT/config" "$DATA_ROOT/dist" "$DATA_ROOT/one"
if [ "$(id -u)" -eq 0 ]; then
  chown -R 1000:1000 "$DATA_ROOT"
else
  [ -w "$DATA_ROOT/config" ] || die "$DATA_ROOT is not writable; create it as uid 1000 or run with sudo"
fi

log "starting $CONTAINER_NAME from $IMAGE"
"$DOCKER" run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  -p "$ZT_PORT:9994/udp" \
  -p "$API_PORT:3443/tcp" \
  -p "$FILE_PORT:3000/tcp" \
  -e "IP_ADDR4=$IP_ADDR4" \
  -e "IP_ADDR6=$IP_ADDR6" \
  -e "ZT_PORT=9994" \
  -e "API_PORT=3443" \
  -e "FILE_SERVER_PORT=3000" \
  -e "TLS_ENABLED=1" \
  -v "$DATA_ROOT/config:/app/config" \
  -v "$DATA_ROOT/dist:/app/dist" \
  -v "$DATA_ROOT/one:/var/lib/zerotier-one" \
  "$IMAGE" >/dev/null

log "waiting for the container to become healthy"
STATUS="starting"
for _ in $(seq 1 60); do
  STATUS=$("$DOCKER" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)
  [ "$STATUS" = "healthy" ] && break
  [ "$STATUS" = "exited" ] && break
  sleep 1
done

if [ "$STATUS" != "healthy" ]; then
  printf '[deploy] container did not report healthy (status: %s)\n' "$STATUS" >&2
  "$DOCKER" logs --tail 50 "$CONTAINER_NAME" >&2 || true
  die "startup failed; inspect the logs with: $DOCKER logs $CONTAINER_NAME"
fi

cat <<EOF

ZeroTier planet is running.

  Controller UI : https://${IP_ADDR4}:${API_PORT}
  Planet file   : https://${IP_ADDR4}:${FILE_PORT}/planet
  Moon file     : https://${IP_ADDR4}:${FILE_PORT}/<moon-id>.moon

Initial admin password (read it as root, then change it on first login):

  sudo cat ${DATA_ROOT}/config/admin-password

Or copy the planet file directly from the host (no download key needed):

  cp ${DATA_ROOT}/dist/planet ./planet

If you prefer HTTP download, the key is in ${DATA_ROOT}/config/file_server.key:

  curl -fsS -H "Authorization: Bearer \$(sudo cat ${DATA_ROOT}/config/file_server.key)" \\
    https://${IP_ADDR4}:${FILE_PORT}/planet -o planet

Remember to allow UDP ${ZT_PORT} through the firewall and to point clients at
the downloaded planet file. The self-signed certificate is generated on first
start; replace ${DATA_ROOT}/config/tls/fullchain.pem and privkey.pem to use
your own certificate.
EOF
