#!/usr/bin/env bash
#
# Check or update the pinned upstream versions used by this fork.
#
#   ZeroTier One  -> latest stable GitHub release (tag + peeled commit)
#   ztncui        -> latest commit on key-networks/ztncui master
#
# The script only edits the ARG lines at the top of Dockerfile.  It does not
# merge xubiaolin/docker-zerotier-planet (this fork has intentionally diverged)
# and it does not commit or push anything.
#
# Default is a read-only check.  Use --apply to update Dockerfile and run the
# local regression tests; the file is restored if the tests fail.
#
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
ZT_REPO="https://github.com/zerotier/ZeroTierOne.git"
ZTNCUI_REPO="https://github.com/key-networks/ztncui.git"

APPLY=0
DO_ZT=1
DO_UI=1
RUN_TESTS=1
BUILD=0
GITHUB_TOKEN=${GITHUB_TOKEN:-}

usage() {
  cat <<'EOF'
Usage: scripts/upgrade-upstreams.sh [options]

Check the pinned upstream versions and report whether they are current.

Options:
  --apply             Update Dockerfile and run the local regression tests.
  --check             Only report (default).
  --zerotier-only     Check/update ZeroTier One only.
  --ztncui-only       Check/update ztncui only.
  --no-tests          Do not run tests after --apply.
  --build             Run `docker build` after a successful update.
  -h, --help          Show this help.

Environment:
  GITHUB_TOKEN        Optional token used for GitHub API calls (prevents
                      anonymous rate limiting).  It is never printed.

Examples:
  scripts/upgrade-upstreams.sh
  scripts/upgrade-upstreams.sh --apply
  GITHUB_TOKEN=... scripts/upgrade-upstreams.sh --apply --build
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --check) APPLY=0 ;;
    --zerotier-only) DO_ZT=1; DO_UI=0 ;;
    --ztncui-only) DO_ZT=0; DO_UI=1 ;;
    --no-tests) RUN_TESTS=0 ;;
    --build) BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
  shift
done

need curl
need git
need node
[ -f "$DOCKERFILE" ] || die "Dockerfile not found at $DOCKERFILE"

# Read a dotted field from JSON on stdin.  Exits non-zero when the field is
# missing so callers can fail closed instead of writing "null" into a pin.
json_get() {
  node -e '
    let body = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { body += chunk; });
    process.stdin.on("end", () => {
      const keys = process.argv[1].split(".");
      let value = JSON.parse(body);
      for (const key of keys) {
        if (value === null || typeof value !== "object" || !(key in value)) process.exit(2);
        value = value[key];
      }
      if (value === undefined || value === null) process.exit(2);
      process.stdout.write(String(value));
    });
  ' "$1"
}

api_get() {
  local url=$1
  if [ -n "$GITHUB_TOKEN" ]; then
    curl -fsSL --retry 3 --connect-timeout 10 \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      "$url"
  else
    curl -fsSL --retry 3 --connect-timeout 10 \
      -H "Accept: application/vnd.github+json" \
      "$url"
  fi
}

resolve_zt_commit() {
  local tag=$1 sha
  sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "$ZT_REPO" "refs/tags/${tag}^{}" 2>/dev/null \
    | awk 'NR == 1 { print $1 }')
  if [ -z "$sha" ]; then
    sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "$ZT_REPO" "refs/tags/${tag}" 2>/dev/null \
      | awk 'NR == 1 { print $1 }')
  fi
  [ -n "$sha" ] || die "could not resolve ZeroTier tag '$tag' to a commit"
  printf '%s' "$sha"
}

resolve_ui_commit() {
  local sha
  sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$ZTNCUI_REPO" refs/heads/master 2>/dev/null \
    | awk 'NR == 1 { print $1 }')
  if [ -z "$sha" ]; then
    sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$ZTNCUI_REPO" refs/heads/main 2>/dev/null \
      | awk 'NR == 1 { print $1 }')
  fi
  [ -n "$sha" ] || die "could not resolve ztncui master/main commit"
  printf '%s' "$sha"
}

read_arg() {
  local name=$1 value
  value=$(awk -v key="ARG ${name}=" 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$DOCKERFILE")
  [ -n "$value" ] || die "missing ARG ${name}= in Dockerfile"
  printf '%s' "$value"
}

update_arg() {
  local name=$1 value=$2 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/upgrade-upstreams.XXXXXX")
  if ! awk -v key="ARG ${name}=" -v line="ARG ${name}=${value}" '
    index($0, key) == 1 { if (done) { print "duplicate " key > "/dev/stderr"; exit 3 } print line; done = 1; next }
    { print }
    END { if (!done) exit 4 }
  ' "$DOCKERFILE" > "$tmp"; then
    rm -f "$tmp"
    die "failed to update ARG ${name} in Dockerfile"
  fi
  cat "$tmp" > "$DOCKERFILE"
  rm -f "$tmp"
}

short_sha() { printf '%.12s' "$1"; }

CURRENT_ZT_VERSION=$(read_arg ZT_VERSION)
CURRENT_ZT_COMMIT=$(read_arg ZT_COMMIT)
CURRENT_UI_COMMIT=$(read_arg ZTNCUI_COMMIT)

ZT_TAG=""
ZT_COMMIT=""
ZT_RELEASE_URL=""
UI_COMMIT=""
UI_COMMIT_URL=""

if [ "$DO_ZT" -eq 1 ]; then
  note "Querying latest ZeroTier One stable release..."
  release_json=$(api_get "https://api.github.com/repos/zerotier/ZeroTierOne/releases/latest") \
    || die "GitHub API request failed (network error or rate limit; set GITHUB_TOKEN)"
  ZT_TAG=$(printf '%s' "$release_json" | json_get tag_name) \
    || die "could not parse tag_name from GitHub release"
  ZT_RELEASE_URL=$(printf '%s' "$release_json" | json_get html_url 2>/dev/null || true)
  ZT_COMMIT=$(resolve_zt_commit "$ZT_TAG")
fi

if [ "$DO_UI" -eq 1 ]; then
  note "Querying latest ztncui commit..."
  UI_COMMIT=$(resolve_ui_commit)
  UI_COMMIT_URL="https://github.com/key-networks/ztncui/commit/${UI_COMMIT}"
fi

ZT_CHANGED=0
UI_CHANGED=0
[ "$DO_ZT" -eq 1 ] || { ZT_TAG=$CURRENT_ZT_VERSION; ZT_COMMIT=$CURRENT_ZT_COMMIT; }
[ "$DO_UI" -eq 1 ] || { UI_COMMIT=$CURRENT_UI_COMMIT; }

if [ "$DO_ZT" -eq 1 ] && { [ "$ZT_TAG" != "$CURRENT_ZT_VERSION" ] || [ "$ZT_COMMIT" != "$CURRENT_ZT_COMMIT" ]; }; then
  ZT_CHANGED=1
fi
if [ "$DO_UI" -eq 1 ] && [ "$UI_COMMIT" != "$CURRENT_UI_COMMIT" ]; then
  UI_CHANGED=1
fi

note ""
note "Repository: $ROOT_DIR"
if [ "$DO_ZT" -eq 1 ]; then
  note "ZeroTier One:"
  note "  pinned: $CURRENT_ZT_VERSION  $(short_sha "$CURRENT_ZT_COMMIT")"
  note "  latest: $ZT_TAG  $(short_sha "$ZT_COMMIT")"
  [ -n "$ZT_RELEASE_URL" ] && note "  release: $ZT_RELEASE_URL"
fi
if [ "$DO_UI" -eq 1 ]; then
  note "ztncui:"
  note "  pinned: $(short_sha "$CURRENT_UI_COMMIT")"
  note "  latest: $(short_sha "$UI_COMMIT")"
  [ -n "$UI_COMMIT_URL" ] && note "  commit: $UI_COMMIT_URL"
fi
note ""

if [ "$ZT_CHANGED" -eq 0 ] && [ "$UI_CHANGED" -eq 0 ]; then
  note "All pins are current."
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  note "Updates are available. Re-run with --apply to update Dockerfile."
  [ "$ZT_CHANGED" -eq 1 ] && note "  - ZeroTier One: $CURRENT_ZT_VERSION -> $ZT_TAG"
  [ "$UI_CHANGED" -eq 1 ] && note "  - ztncui: $(short_sha "$CURRENT_UI_COMMIT") -> $(short_sha "$UI_COMMIT")"
  exit 0
fi

# Keep a rollback copy until the updated tree has passed the local tests.
BACKUP=$(mktemp "${TMPDIR:-/tmp}/Dockerfile.upgrade.XXXXXX")
cp "$DOCKERFILE" "$BACKUP"
restore() { cp "$BACKUP" "$DOCKERFILE"; rm -f "$BACKUP"; }

if [ "$ZT_CHANGED" -eq 1 ]; then
  update_arg ZT_VERSION "$ZT_TAG"
  update_arg ZT_COMMIT "$ZT_COMMIT"
fi
if [ "$UI_CHANGED" -eq 1 ]; then
  update_arg ZTNCUI_COMMIT "$UI_COMMIT"
fi

note "Dockerfile updated:"
[ "$ZT_CHANGED" -eq 1 ] && note "  ZT_VERSION=$ZT_TAG"
[ "$ZT_CHANGED" -eq 1 ] && note "  ZT_COMMIT=$ZT_COMMIT"
[ "$UI_CHANGED" -eq 1 ] && note "  ZTNCUI_COMMIT=$UI_COMMIT"

if [ "$RUN_TESTS" -eq 1 ]; then
  note ""
  note "Running local checks..."
  if [ -f "$ROOT_DIR/tests/http-server.test.sh" ]; then
    if ! (cd "$ROOT_DIR" && bash tests/http-server.test.sh); then
      restore
      die "http-server tests failed; Dockerfile restored"
    fi
  fi
  if [ -f "$ROOT_DIR/tests/ztncui-views.test.js" ]; then
    if [ -d "$ROOT_DIR/patch/ztncui/node_modules/pug" ]; then
      if ! (cd "$ROOT_DIR" && node tests/ztncui-views.test.js); then
        restore
        die "Pug view tests failed; Dockerfile restored"
      fi
    else
      note "  skip Pug tests: patch/ztncui/node_modules is missing"
    fi
  fi
  for script in patch/entrypoint.sh deploy.sh build.sh tests/http-server.test.sh; do
    if [ -f "$ROOT_DIR/$script" ] && ! (cd "$ROOT_DIR" && bash -n "$script"); then
      restore
      die "shell syntax check failed for $script; Dockerfile restored"
    fi
  done
else
  note "Tests skipped (--no-tests)."
fi

if [ "$BUILD" -eq 1 ]; then
  need docker
  note ""
  note "Building image docker-zerotier-planet:upgrade-test ..."
  if ! (cd "$ROOT_DIR" && docker build -t docker-zerotier-planet:upgrade-test .); then
    restore
    die "docker build failed; Dockerfile restored"
  fi
fi

rm -f "$BACKUP"

note ""
note "Done. Review the Dockerfile diff, update version references in README/SECURITY,"
note "then commit the change.  No commit or push was performed by this script."
if [ "$ZT_CHANGED" -eq 1 ]; then
  note "Review ZeroTier release notes for API/behaviour changes before deploying."
fi
if [ "$UI_CHANGED" -eq 1 ]; then
  note "Re-check patch/ztncui overlay compatibility (controllers/views) after a ztncui bump."
fi
