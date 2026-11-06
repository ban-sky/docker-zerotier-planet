# docker-zerotier-planet (hardened)

Run your own **ZeroTier planet** and **network controller (ztncui)** in Docker.
This is a maintained fork of
[xubiaolin/docker-zerotier-planet](https://github.com/xubiaolin/docker-zerotier-planet),
upgraded to **ZeroTier One 1.16.2** (verified 2026-11-06: this is still the latest
upstream stable release) with fixes for the security issues reported against the
upstream project.

> **License warning (important)**
> Since ZeroTier 1.16 the controller lives in `nonfree/` and is covered by the
> *ZeroTier SOURCE-AVAILABLE LICENSE*: **personal, non-commercial use only**
> (plus student education/academia and a 30-day evaluation). This image is
> therefore built with `ZT_NONFREE=1`. Companies, government/military,
> non-profits/charities and paid services **must not** use the bundled
> controller. See [NOTICE](NOTICE) and `/usr/share/licenses/zerotier/`.

## Changes from upstream

### Security (the five findings in issue #215)

| Finding | Fix |
| --- | --- |
| Hard-coded `admin/password` | A random 24-character password is generated on first boot into `config/admin-password` (0600). The UI forces a password change on first login and deletes the file afterwards |
| Path traversal in the file server | Only `planet` and `*.moon` are served; the resolved `realpath` must stay inside `dist/`; symlink escapes, `..` and encoded traversal are rejected |
| Download key in the URL query | `Authorization: Bearer` / `X-Api-Key` only by default; a 32-byte key persisted as 0600; the legacy `?key=` mode requires `ALLOW_QUERY_KEY=1` |
| Unpinned dependencies | ZeroTier pinned to `1.16.2` with commit verification; ztncui pinned to a commit; npm uses the committed lockfile and `npm ci --omit=dev --ignore-scripts` |
| Plaintext HTTP for UI and downloads | TLS by default (self-signed ECDSA P-256 with the server IP in the SAN), TLS 1.2+, HSTS; custom certificates can be mounted |

### Other upstream issues

- **#213**: `attic/world` was removed in 1.16 and the old `mkworld` no longer builds. The tool was rewritten against `node/World.hpp` + `ECC` and verifies the signature it produces.
- **#200**: port prompts in `deploy.sh` are no longer swallowed by command substitution, and ports are validated as `1-65535`.
- **#180**: data directories are created before `docker run`, so podman works too.
- **#196**: `/usr/sbin/zerotier-cli` and `zerotier-idtool` are available inside the image; the old `/bak` templates are gone.
- **#208**: `activeBridge`/`auth` are parsed as strict booleans; the string `"false"` is no longer truthy.
- **#185**: the default MemoryStore warning is replaced by a TTL-bounded store.
- **#163**: the entrypoint waits for ZeroTier's own authtoken instead of generating one, avoiding controller API 401s.
- **#216**: multi-arch build script and local Dockerfile; no dependency on the upstream Docker Hub image. Images can be pushed to GHCR by the operator.
- **#157**: set `HTTPS_HOST=::` to listen on IPv6 as well (default `0.0.0.0`).
- **#205**: only `linux/amd64` and `linux/arm64` are built; armv7 is not supported.

### Additional hardening

- Services run as uid/gid 1000; the entrypoint only uses root briefly to fix volume ownership.
- No `set -x`: authtoken, controller token and download keys never appear in logs.
- ztncui: CSP, HSTS, SameSite/HttpOnly/Secure cookies, same-origin Origin/Referer checks, login throttling, open-redirect fix, prototype-chain username DoS fix, session fixation fix, and error pages without stack traces.
- Native `argon2` replaced by pure-WASM `hash-wasm` (no node-gyp) with Argon2id (64 MiB).
- ztncui frontend and dependency stack rewritten (0.9.0): Bootstrap 3, jQuery, got,
  ip-address and express-validator are gone. IP/CIDR checks use `node:net`,
  controller calls use Node 24's native `fetch`, and network creation uses the
  1.16 `POST /controller/network` API. `npm audit --omit=dev` reported zero
  advisories on 2026-11-06.
- The UI is a responsive card/table layout; on phones (≤720px) tables collapse into labelled cards, navigation collapses, toolbars scroll horizontally and touch targets are at least 42px. No inline scripts or styles
  (CSP allows `'self'` only). Member authorization/bridging uses explicit
  selects and keeps the strict boolean semantics from the #208 fix.
- Atomic 0600 password writes; existing passwords can only be changed by their owner; an admin can initialize a newly created user; the last admin cannot be deleted.
- Compose defaults to `read_only`, `no-new-privileges` and a `tmpfs` `/tmp`.
- `SECURITY.md`, a disclosure process, dependency lockfiles and regression tests.

## Quick start

### Requirements

- Docker 24+ / Docker Compose v2; `amd64` or `arm64`
- A Linux host with a public IPv4 address (port forwarding if behind NAT)
- Allow **UDP 9994**, **TCP 3443** (UI) and **TCP 3000** (planet download)
- ~512 MiB RAM and 1 GiB disk

### Option 1: script

```bash
git clone https://github.com/ban-sky/docker-zerotier-planet.git
cd docker-zerotier-planet
./deploy.sh
```

The script asks for the public address and ports, creates `data/`, builds the
image if it is missing, starts the container and waits for its health check. It
asks before replacing an existing container and never deletes the data
directory.

### Option 2: Compose

```bash
git clone https://github.com/ban-sky/docker-zerotier-planet.git
cd docker-zerotier-planet
cat > .env <<'EOF'
IP_ADDR4=203.0.113.10
# IP_ADDR6=2001:db8::10
EOF
# build locally on first use
docker compose up -d --build
```

### First login

```bash
sudo cat data/config/admin-password
```

Open `https://<public-ip>:3443`, accept the self-signed certificate, and log in
as `admin` with that password. The UI immediately forces a password change; the
`admin-password` file is deleted once the new password is set.

### Distribute the planet file

The safest approach is to copy it from the host (no download key needed):

```bash
cp data/dist/planet ./planet
```

Or download it from the file server (key in `data/config/file_server.key`):

```bash
curl -fsS \
  -H "Authorization: Bearer $(sudo cat data/config/file_server.key)" \
  https://<public-ip>:3000/planet -o planet
```

Place `planet` in the client's data directory and restart ZeroTier:

| OS | Path |
| --- | --- |
| Linux | `/var/lib/zerotier-one/planet` |
| Windows | `C:\ProgramData\ZeroTier\One\planet` |
| macOS | `/Library/Application Support/ZeroTier/One/planet` |
| Android/iOS | import it with a client that supports custom planets |

After the restart, `zerotier-cli listpeers` should show your planet instead of
the official one.

### Optional moon

`data/dist/` also contains `<moon-id>.moon`. Copy it into the client's
`moons.d/`, then:

```bash
zerotier-cli orbit <moon-id> <moon-id>
```

### Create and join a network

1. In ztncui open **Networks → Add network** and note the 16-digit network ID.
2. On the client run `zerotier-cli join <network-id>`.
3. Authorize the member in ztncui, then assign IPs/routes/rules as needed.
4. `zerotier-cli listnetworks` should report `OK PRIVATE`.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `IP_ADDR4` | auto-detected private IPv4 | **Set this to the public IPv4/hostname clients can reach**; written into moon/planet |
| `IP_ADDR6` | empty | Optional public IPv6 |
| `ZT_PORT` | `9994` | ZeroTier UDP port (fixed to 9994 inside the container) |
| `API_PORT` | `3443` | ztncui HTTPS port (fixed to 3443 inside) |
| `FILE_SERVER_PORT` | `3000` | planet download port (fixed to 3000 inside) |
| `TLS_ENABLED` | `1` | `0` disables TLS (**not recommended**; credentials travel in clear text) |
| `TLS_CERT` / `TLS_KEY` | self-signed | In-container paths to custom certificate/key |
| `FILE_KEY` | generated | At least 32 characters; overrides the stored download key |
| `ALLOW_QUERY_KEY` | `0` | Re-enable the legacy `?key=` download mode |
| `REGENERATE_PLANET` | `1` | Rebuild the planet on every start (identity unchanged) |
| `APP_UID` / `APP_GID` | `1000` | uid/gid used by the services |
| `HTTPS_HOST` | `0.0.0.0` | Set to `::` to listen on IPv6 as well |
| `TRUST_PROXY` | empty | Number of trusted proxies, e.g. `1`; enables `X-Forwarded-For` for throttling |

Publish ports with `docker run -p` or Compose; the in-container ports are fixed
so documentation, health checks and the UI stay consistent.

### Custom certificates

```bash
mkdir -p data/config/tls
cp fullchain.pem data/config/tls/fullchain.pem
cp privkey.pem   data/config/tls/privkey.pem
docker compose restart
```

The certificate must include `IP:<public-ip>` or the hostname clients use in its
SAN. Behind Nginx/Caddy, expose only the proxy and set `TRUST_PROXY=1`; you can
then bind `API_PORT`/`FILE_SERVER_PORT` to `127.0.0.1`.

### Data and backups

| Path | Contents |
| --- | --- |
| `data/one/` | ZeroTier identity, controller database, authtoken, moon |
| `data/config/` | ztncui password database, session secret, TLS keys, download key, bootstrap password |
| `data/dist/` | Publicly distributable `planet` and `.moon` files |

**`data/one/identity.secret` is the root identity of the planet.** If it is
lost, every client must switch to a new planet. Back up `data/one/` and
`data/config/` offline and encrypted. Image upgrades never modify these volumes.

## Migrating from upstream

1. Stop the old container and back up its data directory.
2. The new container needs three volumes: `config`, `dist` and `one` (the old
   `zerotier-one` directory maps to the new `one`).
3. **Do not** mount `/app/ztncui` any more; the application directory is now
   immutable, and mounting over it would prevent security updates.
4. The old ztncui password database lives in `ztncui/src/etc/passwd`; the new
   image reads `config/ztncui-passwd`. Copy the old file there and set
   `ZTNCUI_PASSWD`, or delete both `config/ztncui-passwd` and
   `config/admin-password` to let the container recreate the admin.
5. With an existing `one/`, the entrypoint reuses `identity.secret` and
   regenerates the planet; the planet ID stays the same.

## Local build and tests

Builds use digest-pinned Debian bookworm-slim and Node.js 24 LTS slim base images.
When bumping a base image, update the ARGs at the top of `Dockerfile` and re-run
the tests.

```bash
# local single-architecture build
./build.sh

# multi-arch build and push (log in to the registry first)
PUSH=1 IMAGE=ghcr.io/<you>/docker-zerotier-planet:latest ./build.sh

# tests
cd patch/ztncui && npm ci --omit=dev --ignore-scripts
cd ../..
./tests/http-server.test.sh
node tests/ztncui-views.test.js
```

`tests/http-server.test.sh` contains file-server security regression tests, and
`tests/ztncui-views.test.js` compiles every Pug view. Add a CI
workflow yourself if desired: pushing workflow files with a GitHub OAuth App requires the
additional `workflow` scope.

### Upgrading upstream versions

`scripts/upgrade-upstreams.sh` checks and updates the two upstream pins. It only
edits `ZT_VERSION`, `ZT_COMMIT` and `ZTNCUI_COMMIT` in `Dockerfile`; it does not
merge xubiaolin/docker-zerotier-planet (this fork has diverged) and does not commit:

```bash
# read-only check (default)
./scripts/upgrade-upstreams.sh

# update Dockerfile and run the local regression tests
./scripts/upgrade-upstreams.sh --apply

# only one upstream
./scripts/upgrade-upstreams.sh --apply --zerotier-only
./scripts/upgrade-upstreams.sh --apply --ztncui-only

# build after a successful update (requires docker)
./scripts/upgrade-upstreams.sh --apply --build
```

The script needs `curl`, `git` and `node` (`--build` additionally needs docker). Set `GITHUB_TOKEN` if the anonymous GitHub API rate limit is too low. After a
ZeroTier bump, read the release notes and re-check the controller API; after a
ztncui bump, review whether the `patch/ztncui` controller/view overlay still
applies. Version numbers and changelog text in README/SECURITY are updated
manually.

## Security model and limitations

- Single-node controller; there is no HA. The controller database is
  `data/one/controller.d`.
- Sessions live in memory; a container restart logs everyone out.
- A self-signed certificate provides encryption, not identity. Use a trusted
  certificate or a reverse proxy in production.
- Keep the UI on a trusted network; do not expose port 3443 to the whole
  internet without a strong password.
- Without `NET_ADMIN` the container cannot create a TUN device, but the
  controller/planet still work. Extra capabilities are only needed if the
  container itself must join a network as a leaf.
- The bundled controller is subject to ZeroTier's non-commercial license. Buy a
  license or use the official controller for commercial use.
- This project does not operate any relay or root servers; planet availability
  depends on your host and network.

## Troubleshooting

- **Clients still use the official planet**: verify the planet path and restart
  the service; `zerotier-cli listpeers` should show your public IP; check that
  UDP 9994 is not blocked by a firewall or NAT.
- **Cannot log in**: check that `data/config/admin-password` exists. Delete
  `data/config/ztncui-passwd` and `admin-password` and restart to reset (this
  removes all admin accounts).
- **Container restarts repeatedly**: `docker logs <container>`; common causes are
  a missing public IP, a port conflict, volumes not owned by uid 1000, or an
  unreadable certificate.
- **Certificate warning**: expected with the self-signed certificate; import it
  or switch to a trusted certificate.
- **Download returns 401**: use `Authorization: Bearer <key>` rather than
  `?key=`; or copy `data/dist/planet` directly.

## License

- Original code in this repository: GPL-3.0-only, see [LICENSE](LICENSE).
- ztncui: GPL-3.0, see its repository.
- ZeroTier One core: MPL-2.0; `nonfree/controller`: ZeroTier SOURCE-AVAILABLE
  LICENSE (non-commercial only), see [NOTICE](NOTICE).

Upstream: <https://github.com/xubiaolin/docker-zerotier-planet>
