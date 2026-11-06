#!/usr/bin/env bash
#
# Migrate an existing xubiaolin/docker-zerotier-planet deployment to this fork.
#
# What is preserved:
#   - /var/lib/zerotier-one: identity, controller.d, moons.d, networks.d,
#     authtoken.secret and the rest of the ZeroTier state
#   - /app/dist: planet and moon files (rebuilt by the new entrypoint)
#   - /app/config: file-server key, custom certificates and other config
#   - the ztncui user database (ztncui/src/etc/passwd -> config/ztncui-passwd)
#
# The old container is stopped only after a full data backup has been written.
# The new container is started under a temporary name and renamed into place
# only after it reports healthy; on failure the backup is restored and the old
# container is started again.
#
# Requirements: bash, docker, tar, gzip, coreutils. Node is optional and only used
# to validate the legacy ztncui password database before copying it.
# Run it from the repository checkout of the branch you want to deploy, usually:
#   sudo ./scripts/migrate-from-upstream.sh
#
# GPLv3 - see LICENSE.

set -Eeuo pipefail
umask 077

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER="${DOCKER:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-myztplanet}"
IMAGE="${IMAGE:-docker-zerotier-planet:latest}"
APT_MIRROR="${APT_MIRROR:-http://mirrors.ustc.edu.cn}"
SOURCE_DATA="${SOURCE_DATA:-}"
TARGET_DATA="${TARGET_DATA:-}"
BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
IP_ADDR4="${IP_ADDR4:-}"
IP_ADDR6="${IP_ADDR6:-}"
ZT_PORT="${ZT_PORT:-}"
API_PORT="${API_PORT:-}"
FILE_PORT="${FILE_PORT:-}"
ASSUME_YES=0
DRY_RUN=0
BUILD_IMAGE=1

TMP_NAME=""
BACKUP_FILE=""
BACKUP_READY=0
TARGET_READY=0
STOPPED=0
OLD_REMOVED=0
SUCCESS=0
OLD_WAS_RUNNING=0
MIGRATE_PASSWD=0
OLD_PASSWD=""
NEW_PASSWD=""
OLD_STORAGE=""
NEW_STORAGE=""
MIGRATE_STORAGE=0

log() { printf '[migrate] %s\n' "$*"; }
warn() { printf '[migrate] WARNING: %s\n' "$*" >&2; }
die() { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-from-upstream.sh [options]

Options:
  --name NAME        existing container name (default: myztplanet)
  --data DIR         existing data root (default: derived from the container)
  --target-data DIR  new data root (default: reuse --data in place); copied
                     from the old root and left there for rollback
  --image IMAGE      image to build/use (default: docker-zerotier-planet:latest)
  --backup DIR       backup directory (default: ./backups)
  --ipv4 ADDR        public IPv4 address or hostname (default: old container env)
  --ipv6 ADDR        optional public IPv6 address
  --zt-port PORT     host UDP port (default: old container mapping or 9994)
  --api-port PORT    host HTTPS port (default: old container mapping or 3443)
  --file-port PORT   host planet-download port (default: old mapping or 3000)
  --no-build         do not build the image; require it to exist
  --dry-run          inspect and print the plan without changing anything
  -y, --yes          do not ask for confirmation
  -h, --help         show this help

The script must be able to read the old data directory. If it is owned by root,
run the script with sudo. Use --dry-run first.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) CONTAINER_NAME="${2:?}"; shift 2 ;;
    --data) SOURCE_DATA="${2:?}"; shift 2 ;;
    --target-data) TARGET_DATA="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --backup) BACKUP_DIR="${2:?}"; shift 2 ;;
    --ipv4) IP_ADDR4="${2:?}"; shift 2 ;;
    --ipv6) IP_ADDR6="${2:?}"; shift 2 ;;
    --zt-port) ZT_PORT="${2:?}"; shift 2 ;;
    --api-port) API_PORT="${2:?}"; shift 2 ;;
    --file-port) FILE_PORT="${2:?}"; shift 2 ;;
    --no-build) BUILD_IMAGE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_cmd "$DOCKER"
need_cmd tar
need_cmd gzip
need_cmd sha256sum
need_cmd realpath
[ -x "$REPO_ROOT/deploy.sh" ] || die "deploy.sh not found under $REPO_ROOT"
[ -f "$REPO_ROOT/Dockerfile" ] || die "Dockerfile not found under $REPO_ROOT"

# ---------------------------------------------------------------------------
# Find the old container and its data directory
# ---------------------------------------------------------------------------
if ! "$DOCKER" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  die "container '$CONTAINER_NAME' not found; this script only migrates an existing xubiaolin/docker-zerotier-planet deployment (use ./deploy.sh for a fresh install)"
fi

OLD_STATE=$("$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
OLD_IMAGE=$("$DOCKER" inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")
[ "$OLD_STATE" = "running" ] && OLD_WAS_RUNNING=1

OLD_ENV=$("$DOCKER" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME")
get_env() {
  printf '%s\n' "$OLD_ENV" | sed -n "s/^$1=//p" | head -n 1
}

if [ -z "$SOURCE_DATA" ]; then
  CONFIG_SRC=$("$DOCKER" inspect -f '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")
  [ -n "$CONFIG_SRC" ] || die "cannot detect /app/config mount; pass --data DIR"
  SOURCE_DATA=$(dirname "$CONFIG_SRC")
fi

[ -d "$SOURCE_DATA" ] || die "data directory not found: $SOURCE_DATA"
SOURCE_DATA=$(cd "$SOURCE_DATA" && pwd)
[ "$SOURCE_DATA" != "/" ] || die "refusing to use / as the data directory"
[ "$SOURCE_DATA" != "$REPO_ROOT" ] || die "data directory must not be the repository root"
[ -d "$SOURCE_DATA/one" ] || die "missing $SOURCE_DATA/one (is this really the old deployment?)"
[ -s "$SOURCE_DATA/one/identity.secret" ] || die "missing $SOURCE_DATA/one/identity.secret; back up and check the old deployment first"
[ -r "$SOURCE_DATA/one" ] || die "cannot read $SOURCE_DATA/one; run with sudo or fix permissions"
[ -d "$SOURCE_DATA/config" ] || die "missing $SOURCE_DATA/config"
[ -d "$SOURCE_DATA/dist" ] || die "missing $SOURCE_DATA/dist"

if [ ! -d "$SOURCE_DATA/one/controller.d" ]; then
  warn "$SOURCE_DATA/one/controller.d not found; the controller database may be empty"
fi

# The new deployment can keep using the old data root, or copy it to a new one
# (for example /root/... -> /opt/...). The source is never modified in the copy
# case, so it remains available if the new container has to be rolled back.
if [ -z "$TARGET_DATA" ]; then
  TARGET_DATA="$SOURCE_DATA"
else
  TARGET_DATA=$(realpath -m "$TARGET_DATA")
fi
if [ "$TARGET_DATA" != "$SOURCE_DATA" ]; then
  [ "$TARGET_DATA" != "/" ] || die "refusing to use / as the target data directory"
  [ "$TARGET_DATA" != "$REPO_ROOT" ] || die "target data directory must not be the repository root"
  [ -L "$TARGET_DATA" ] && die "target data directory must not be a symlink: $TARGET_DATA"
  if [ -e "$TARGET_DATA" ]; then
    [ -d "$TARGET_DATA" ] || die "target data path is not a directory: $TARGET_DATA"
    [ -z "$(ls -A "$TARGET_DATA" 2>/dev/null || true)" ] \
      || die "target data directory must be empty: $TARGET_DATA"
  fi
  case "$TARGET_DATA/" in
    "$SOURCE_DATA"/*) die "target data directory must not be inside the old data directory" ;;
  esac
  case "$SOURCE_DATA/" in
    "$TARGET_DATA"/*) die "old data directory must not be inside the target data directory" ;;
  esac
fi

# Detect a legacy ztncui password database that should become config/ztncui-passwd.
NEW_PASSWD="$TARGET_DATA/config/ztncui-passwd"
if [ "$TARGET_DATA" != "$SOURCE_DATA" ] && [ -s "$SOURCE_DATA/config/ztncui-passwd" ]; then
  log "found existing $SOURCE_DATA/config/ztncui-passwd; it will be copied with the old config"
elif [ -s "$NEW_PASSWD" ]; then
  log "found existing $NEW_PASSWD; existing ztncui users will be kept"
else
  for candidate in \
    "$SOURCE_DATA/ztncui/src/etc/passwd" \
    "$SOURCE_DATA/ztncui/etc/passwd"
  do
    [ -s "$candidate" ] || continue
    if command -v node >/dev/null 2>&1; then
      if ! node -e '
        const fs = require("fs");
        const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (!data || typeof data !== "object" || Array.isArray(data)) process.exit(1);
        if (!data.admin || typeof data.admin !== "object" || typeof data.admin.hash !== "string") process.exit(1);
      ' "$candidate" 2>/dev/null; then
        die "found $candidate but it is not a valid ztncui password database; back it up and fix it before migrating"
      fi
    else
      warn "node not found; copying $candidate without JSON validation"
    fi
    OLD_PASSWD="$candidate"
    MIGRATE_PASSWD=1
    break
  done
fi

# ztncui keeps member display names in node-persist; migrate that too.
NEW_STORAGE="$TARGET_DATA/config/ztncui-storage"
if [ "$TARGET_DATA" != "$SOURCE_DATA" ] \
  && [ -n "$(ls -A "$SOURCE_DATA/config/ztncui-storage" 2>/dev/null || true)" ]; then
  log "found existing $SOURCE_DATA/config/ztncui-storage; it will be copied with the old config"
elif [ -z "$(ls -A "$NEW_STORAGE" 2>/dev/null || true)" ]; then
  for candidate in \
    "$SOURCE_DATA/ztncui/src/etc/storage" \
    "$SOURCE_DATA/ztncui/etc/storage"
  do
    if [ -d "$candidate" ] && [ -n "$(ls -A "$candidate" 2>/dev/null || true)" ]; then
      OLD_STORAGE="$candidate"
      MIGRATE_STORAGE=1
      break
    fi
  done
fi

# ---------------------------------------------------------------------------
# Ports and public addresses
# ---------------------------------------------------------------------------
resolve_port() {
  local spec="$1" envkey="$2" fallback="$3" mapped value
  mapped=$("$DOCKER" port "$CONTAINER_NAME" "$spec" 2>/dev/null | head -n 1 | sed 's/.*://' || true)
  if [ -n "$mapped" ]; then printf '%s' "$mapped"; return; fi
  value=$(get_env "$envkey" || true)
  if [ -n "$value" ]; then printf '%s' "$value"; return; fi
  printf '%s' "$fallback"
}

[ -n "$ZT_PORT" ] || ZT_PORT=$(resolve_port "9994/udp" "ZT_PORT" "9994")
[ -n "$API_PORT" ] || API_PORT=$(resolve_port "3443/tcp" "API_PORT" "3443")
[ -n "$FILE_PORT" ] || FILE_PORT=$(resolve_port "3000/tcp" "FILE_SERVER_PORT" "3000")

for spec in "ZT_PORT:$ZT_PORT" "API_PORT:$API_PORT" "FILE_PORT:$FILE_PORT"; do
  name="${spec%%:*}"
  value="${spec#*:}"
  valid_port "$value" || die "$name must be between 1 and 65535 (got '$value')"
done

[ -n "$IP_ADDR4" ] || IP_ADDR4=$(get_env IP_ADDR4 || true)
[ -n "$IP_ADDR6" ] || IP_ADDR6=$(get_env IP_ADDR6 || true)

if [ -z "$IP_ADDR4" ] && [ -t 0 ]; then
  printf 'Public IPv4 address or hostname: ' >&2
  IFS= read -r IP_ADDR4 || true
fi
[ -n "$IP_ADDR4" ] || die "public IPv4 address is required; pass --ipv4 ADDR"
printf '%s' "$IP_ADDR4" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$' \
  || die "IP_ADDR4 contains unexpected characters"

if [ -n "$IP_ADDR6" ]; then
  printf '%s' "$IP_ADDR6" | grep -Eq '^[0-9A-Fa-f:]+$' || die "IP_ADDR6 is not a valid IPv6 address"
fi

TMP_NAME="${CONTAINER_NAME}-upgraded"
if "$DOCKER" container inspect "$TMP_NAME" >/dev/null 2>&1; then
  die "temporary container '$TMP_NAME' already exists; remove it or choose another --name"
fi

cat <<EOF

Migration plan
--------------
  old container : $CONTAINER_NAME ($OLD_IMAGE, $OLD_STATE)
  old data      : $SOURCE_DATA
  new data      : $TARGET_DATA ($([ "$TARGET_DATA" = "$SOURCE_DATA" ] && printf 'reused in place' || printf 'copy of old data; old root retained'))
  new image     : $IMAGE
  temporary name: $TMP_NAME
  backup        : $BACKUP_DIR/upstream-migration-<timestamp>.tar.gz
  ZeroTier      : UDP $ZT_PORT -> 9994
  UI            : HTTPS $API_PORT -> 3443
  planet server : HTTPS $FILE_PORT -> 3000
  public IPv4   : $IP_ADDR4
  public IPv6   : ${IP_ADDR6:-(none)}
  ztncui users  : $([ "$MIGRATE_PASSWD" -eq 1 ] && printf 'preserve existing database (%s)' "$OLD_PASSWD" || printf 'keep existing config/ztncui-passwd or create a new random admin')
  member names  : $([ "$MIGRATE_STORAGE" -eq 1 ] && printf 'migrate %s' "$OLD_STORAGE" || printf 'none found / already present')
  planet        : rebuilt by the new entrypoint (same identity)

The old container is removed only after the new one is healthy. The new UI
uses HTTPS with a self-signed certificate by default.
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run complete; nothing was changed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the new image before stopping anything
# ---------------------------------------------------------------------------
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
log "repository: $REPO_ROOT (branch: $BRANCH)"
if [ "$BRANCH" != "feature/ztncui-modern-ui" ] && [ "$BRANCH" != "main" ]; then
  warn "current branch is '$BRANCH'; make sure this is the version you want to deploy"
fi

if [ "$BUILD_IMAGE" -eq 1 ]; then
  log "building $IMAGE from $REPO_ROOT"
  "$DOCKER" build --build-arg "APT_MIRROR=$APT_MIRROR" -t "$IMAGE" "$REPO_ROOT" || die "docker build failed; the old container was not touched"
fi
"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE not found; build it or drop --no-build"

# ---------------------------------------------------------------------------
# Plan / confirmation
# ---------------------------------------------------------------------------

if [ "$ASSUME_YES" -eq 0 ]; then
  [ -t 0 ] || die "confirmation required; rerun with --yes for non-interactive use"
  printf 'Proceed with migration? [y/N] ' >&2
  IFS= read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) log "aborted; nothing was changed"; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Backup and rollback
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)
[ -w "$BACKUP_DIR" ] || die "backup directory is not writable: $BACKUP_DIR"
case "$BACKUP_DIR/" in
  "$SOURCE_DATA"/*|"$TARGET_DATA"/*) die "backup directory must not be inside a data directory" ;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_FILE="$BACKUP_DIR/upstream-migration-$STAMP.tar.gz"
CONTAINER_JSON="$BACKUP_DIR/upstream-migration-$STAMP-container.json"

restore_backup() {
  [ -f "$BACKUP_FILE" ] || { warn "backup file is missing; cannot restore automatically"; return 1; }
  [ -f "$BACKUP_FILE.sha256" ] || { warn "backup checksum is missing; cannot restore automatically"; return 1; }
  sha256sum -c "$BACKUP_FILE.sha256" >/dev/null 2>&1 \
    || { warn "backup checksum verification failed; cannot restore automatically"; return 1; }
  rm -rf "$SOURCE_DATA" || { warn "failed to clear $SOURCE_DATA"; return 1; }
  tar -C "$(dirname "$SOURCE_DATA")" -xzf "$BACKUP_FILE" || { warn "failed to extract $BACKUP_FILE"; return 1; }
  return 0
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$STOPPED" -eq 1 ] && [ "$SUCCESS" -eq 0 ] && [ "$OLD_REMOVED" -eq 0 ]; then
    set +e
    warn "migration failed; attempting rollback"
    "$DOCKER" rm -f "$TMP_NAME" >/dev/null 2>&1
    if [ "$TARGET_DATA" != "$SOURCE_DATA" ] && [ "$TARGET_READY" -eq 1 ]; then
      rm -rf "$TARGET_DATA" \
        && log "removed incomplete target data $TARGET_DATA; old data was untouched" \
        || warn "could not remove incomplete target data $TARGET_DATA"
    fi
    if [ "$TARGET_DATA" = "$SOURCE_DATA" ] && [ "$BACKUP_READY" -eq 1 ]; then
      if restore_backup; then
        log "data restored from $BACKUP_FILE"
      else
        warn "automatic restore failed; backup is at $BACKUP_FILE"
      fi
    fi
    if [ "$OLD_WAS_RUNNING" -eq 1 ]; then
      "$DOCKER" start "$CONTAINER_NAME" >/dev/null 2>&1 \
        && log "old container $CONTAINER_NAME restarted" \
        || warn "could not restart $CONTAINER_NAME"
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT

log "stopping $CONTAINER_NAME"
"$DOCKER" stop "$CONTAINER_NAME" >/dev/null || die "failed to stop the old container"
STOPPED=1

log "backing up $SOURCE_DATA"
tar --numeric-owner -C "$(dirname "$SOURCE_DATA")" -czf "$BACKUP_FILE" "$(basename "$SOURCE_DATA")" \
  || die "backup failed; starting the old container again"
chmod 600 "$BACKUP_FILE"
sha256sum "$BACKUP_FILE" > "$BACKUP_FILE.sha256"
"$DOCKER" inspect "$CONTAINER_NAME" > "$CONTAINER_JSON" 2>/dev/null || true
[ -f "$CONTAINER_JSON" ] && chmod 600 "$CONTAINER_JSON"
BACKUP_READY=1
log "backup written: $BACKUP_FILE"

if [ "$TARGET_DATA" != "$SOURCE_DATA" ]; then
  log "copying old data to $TARGET_DATA"
  TARGET_READY=1
  mkdir -p "$TARGET_DATA/config" "$TARGET_DATA/dist" "$TARGET_DATA/one" \
    || die "failed to create target data directories"
  cp -a "$SOURCE_DATA/config/." "$TARGET_DATA/config/" \
    || die "failed to copy config data to the target root"
  cp -a "$SOURCE_DATA/dist/." "$TARGET_DATA/dist/" \
    || die "failed to copy dist data to the target root"
  cp -a "$SOURCE_DATA/one/." "$TARGET_DATA/one/" \
    || die "failed to copy ZeroTier data to the target root"
fi

if [ "$MIGRATE_PASSWD" -eq 1 ]; then
  log "preserving ztncui users: $OLD_PASSWD -> $NEW_PASSWD"
  mkdir -p "$(dirname "$NEW_PASSWD")"
  cp "$OLD_PASSWD" "$NEW_PASSWD" || die "failed to copy the ztncui password database"
  chmod 600 "$NEW_PASSWD" || die "failed to set permissions on the ztncui password database"
fi

if [ "$MIGRATE_STORAGE" -eq 1 ]; then
  log "preserving ztncui member names: $OLD_STORAGE -> $NEW_STORAGE"
  mkdir -p "$NEW_STORAGE"
  cp -a "$OLD_STORAGE/." "$NEW_STORAGE/" || die "failed to copy the ztncui storage directory"
fi

# ---------------------------------------------------------------------------
# Start the new container under a temporary name
# ---------------------------------------------------------------------------
DEPLOY_ARGS=(
  --name "$TMP_NAME"
  --image "$IMAGE"
  --data "$TARGET_DATA"
  --zt-port "$ZT_PORT"
  --api-port "$API_PORT"
  --file-port "$FILE_PORT"
  --ipv4 "$IP_ADDR4"
  --recreate
  -y
)
[ -n "$IP_ADDR6" ] && DEPLOY_ARGS+=(--ipv6 "$IP_ADDR6")

log "starting the new container as $TMP_NAME"
if ! "$REPO_ROOT/deploy.sh" "${DEPLOY_ARGS[@]}"; then
  die "new container failed to become healthy; rolling back"
fi

# The new container is healthy. Swap it into place.
log "removing the old container"
"$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null || die "could not remove the old container"
OLD_REMOVED=1
if ! "$DOCKER" rename "$TMP_NAME" "$CONTAINER_NAME"; then
  die "new container is running as $TMP_NAME but could not be renamed; old container was already removed"
fi
SUCCESS=1

if [ "$TARGET_DATA" = "$SOURCE_DATA" ]; then
  ROLLBACK_HINT="restore the backup over ${SOURCE_DATA}, then start the old container."
else
  ROLLBACK_HINT="the old data at ${SOURCE_DATA} was never modified. Stop and remove the new container, delete ${TARGET_DATA}, then start the old container."
fi

cat <<EOF

Migration complete.

  UI            : https://${IP_ADDR4}:${API_PORT}
  Planet file   : https://${IP_ADDR4}:${FILE_PORT}/planet
  Moon file     : https://${IP_ADDR4}:${FILE_PORT}/<moon-id>.moon
  New data      : $TARGET_DATA
  Backup        : $BACKUP_FILE

The new UI uses a self-signed HTTPS certificate, so old http:// links no longer
work. Download the planet with the header-based key (the old key was preserved):

  curl -fsS -H "Authorization: Bearer \$(sudo cat ${TARGET_DATA}/config/file_server.key)" \\
    https://${IP_ADDR4}:${FILE_PORT}/planet -o planet

EOF

if [ "$TARGET_DATA" != "$SOURCE_DATA" ]; then
  cat <<EOF
The old data root is still intact at ${SOURCE_DATA}. After you have verified the
new deployment, archive or remove it to avoid keeping a second copy of the
controller identity and keys.

EOF
fi

if [ "$MIGRATE_PASSWD" -eq 1 ] || [ -s "$NEW_PASSWD" ]; then
  cat <<EOF
Your previous ztncui login database was preserved; use your existing admin
password. No new admin-password file is created in that case.
EOF
else
  cat <<EOF
A new random admin password was generated:

  sudo cat ${TARGET_DATA}/config/admin-password

Change it on first login. Legacy clients downloading with ?key=... must switch
to the Authorization header; query-string keys are disabled by default.
EOF
fi

cat <<EOF

To roll back manually: ${ROLLBACK_HINT} The old container definition was saved in:
  $CONTAINER_JSON
EOF