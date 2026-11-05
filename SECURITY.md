# Security policy

## Supported versions

Security fixes are applied to the `main` branch and to the latest release tag.
Older tags are not maintained.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's private vulnerability reporting:
<https://github.com/ban-sky/docker-zerotier-planet/security/advisories/new>

Include, if possible:

- affected version / image digest,
- a description of the issue and its impact,
- reproduction steps or a proof of concept,
- any suggested mitigation.

You can expect an acknowledgement within 7 days. Please allow time for a fix and
a coordinated disclosure before publishing details.

## Security model

This project runs a **single-node** ZeroTier planet and controller. The
controller is the trusted authority for the networks it manages; anyone who can
log in to ztncui can administer those networks. The planet identity
(`data/one/identity.secret`) is the most sensitive asset: with it an attacker can
sign planet updates for your clients.

The container is not a sandbox against a compromised controller. It is hardened
to reduce the impact of network-facing bugs and to avoid well-known insecure
defaults.

### Implemented controls

- **No default credentials.** A random 24-character admin password is generated
  on first boot, stored in a 0600 file, and must be changed at first login.
  The file is deleted after the change.
- **TLS by default.** The entrypoint generates a self-signed ECDSA P-256
  certificate (SAN includes the configured public address). TLS 1.2+ is
  enforced and HSTS is sent when TLS is enabled. Custom certificates are
  supported.
- **Authenticated downloads.** The file server serves only `planet` and
  `*.moon`, verifies the resolved path with `realpath`, compares the key in
  constant time, and accepts the key via header by default. The legacy query
  parameter is opt-in (`ALLOW_QUERY_KEY=1`).
- **Least privilege.** Services run as uid/gid 1000. The entrypoint starts as
  root only to fix volume ownership and then uses `setpriv`. Compose enables
  `read_only`, `no-new-privileges` and a `tmpfs` `/tmp`.
- **No secret logging.** `set -x` is not used; the authtoken, controller token,
  session secret and download key are not printed. The initial admin password is
  written to a file instead of the log.
- **Password storage.** Argon2id (64 MiB, t=3, p=1) via `hash-wasm`, with a
  per-password random salt. The password database is written atomically with
  mode 0600.
- **Session handling.** A 32-byte server-side session secret is generated on
  first boot; cookies are `HttpOnly`, `SameSite=Lax` and `Secure` under TLS.
  Sessions are regenerated at login and bounded in memory.
- **Request hardening.** Same-origin Origin/Referer checks for state-changing
  requests, login throttling (10 failures / 15 min / IP), a 256 KiB body limit,
  CSP, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, and
  error pages that do not expose stack traces.
- **Input handling.** Usernames are restricted to a safe character set and
  reserved prototype names are rejected. Member flags are parsed as strict
  booleans. Shell scripts validate ports/addresses and quote variables.
- **Supply chain.** ZeroTier is pinned to `1.16.2` and verified against its
  commit; ztncui is pinned to a commit; npm installs from a committed lockfile
  with lifecycle scripts disabled; the Dockerfile verifies the pinned commits and
  `build.sh` builds multi-arch images locally with buildx.

### Deployment checklist

1. Set `IP_ADDR4` to the address clients actually reach; do not rely on the
   auto-detected private address.
2. Restrict TCP 3443 (and 3000, if used) to trusted source addresses.
3. Allow UDP 9994 from clients; do not expose the controller API port directly.
4. Replace the self-signed certificate or terminate TLS at a trusted proxy.
5. Back up `data/one/` and `data/config/` encrypted and offline.
6. Keep the image updated; watch the repository's security advisories.
7. Do not reuse the planet identity for multiple deployments.

## Known limitations

- The controller uses ZeroTier's non-free, source-available implementation and
  is licensed for non-commercial use only.
- There is no HA, clustering, or external session store. A restart invalidates
  sessions.
- The login throttle is in-memory and per process; it is not a distributed
  rate limiter.
- The file server and UI share the host's network namespace in the default
  Compose setup. Use a reverse proxy if you need finer network separation.
- The bundled ztncui application is a maintained fork of the last upstream
  release (0.9.0). Bootstrap 3, jQuery, got 7, ip-address 5, express-validator
  9 and serve-favicon have been removed and replaced with small local helpers:
  a `node:net` IP/CIDR module, a validator shim, native `fetch`, and a
  dependency-free responsive UI. The production dependency tree was audited
  against the npm advisory database on 2026-11-06 and reported no known
  vulnerabilities; re-run `npm audit --omit=dev` on every rebuild, because new
  advisories can appear at any time.
- Container images are built for `linux/amd64` and `linux/arm64` only.
- Real TUN/planet connectivity cannot be validated in this build environment;
  validate your deployment with `zerotier-cli listpeers` and a test client.
