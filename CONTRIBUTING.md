# Contributing

Thanks for helping improve this project.

## Reporting bugs

Open a regular issue for functional bugs. For security problems, follow
[SECURITY.md](SECURITY.md) and use GitHub's private vulnerability reporting
instead of a public issue.

Please include the image tag or commit, the host platform, the relevant
container logs (redact tokens and `identity.secret`), and the steps to
reproduce.

## Pull requests

- Keep changes focused; describe the problem and the approach.
- Do not commit generated data (`data/`, `*.moon`, `*.pem`, `*.key`),
  `node_modules/`, or container images.
- Run the checks locally:

  ```sh
  cd patch/ztncui && npm ci --omit=dev --ignore-scripts
  find patch -name '*.js' -not -path '*/node_modules/*' -print0 \
    | xargs -0 -n1 node --check
  node --check patch/ztncui/bin-www
  bash -n patch/entrypoint.sh deploy.sh build.sh
  ./tests/http-server.test.sh
  ```

- If you change the ztncui overlay, update `patch/ztncui/package-lock.json`
  with `npm install --package-lock-only` and verify `npm ci` succeeds.
- If you change the pinned ZeroTier or ztncui version, update the pins in
  `Dockerfile`, `NOTICE`, and the README compatibility notes.

## Licensing

By contributing you agree that your changes are licensed under GPL-3.0-only,
and that they can be combined with the upstream ZeroTier and ztncui licenses
described in [NOTICE](NOTICE). The non-free ZeroTier controller may only be
used for non-commercial purposes.
