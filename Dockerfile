# syntax=docker/dockerfile:1.7
#
# Multi-stage build for a self-hosted ZeroTier planet + network controller.
#
# Licensing: ZeroTier One 1.16.x moved its controller to nonfree/ under the
# ZeroTier SOURCE-AVAILABLE LICENSE (non-commercial use only). This image is
# therefore built with ZT_NONFREE=1 and must not be used commercially.
# See NOTICE and /usr/share/licenses/zerotier inside the image.
#
# GPLv3 - see LICENSE.

# Pinned multi-arch base images (2026-11-05). Bump deliberately after testing.
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:01d566e8d94d8c619591d78652babfccd3c6992a3dffa9ed5ab39e11cf6c70e9

# ---------------------------------------------------------------------------
# ZeroTier One + mkworld
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS zt-builder

ARG ZT_VERSION=1.16.2
ARG ZT_COMMIT=fc5c3ec22090b5b2a0f274e863651fe9ca489bf4
ARG GH_MIRROR=https://github.com

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${ZT_VERSION}" \
      "${GH_MIRROR}/zerotier/ZeroTierOne.git" zerotier \
 && test "$(git -C zerotier rev-parse HEAD)" = "${ZT_COMMIT}"

COPY patch/mkworld_custom.cpp /src/mkworld_custom.cpp

RUN cd zerotier \
 && make -j"$(nproc)" ZT_NONFREE=1 ZT_SSO_SUPPORTED=0 \
 && mkdir -p /out/usr/sbin /out/licenses \
 && cp zerotier-one /out/usr/sbin/ \
 && strip --strip-unneeded /out/usr/sbin/zerotier-one \
 && ln -sf zerotier-one /out/usr/sbin/zerotier-cli \
 && ln -sf zerotier-one /out/usr/sbin/zerotier-idtool \
 && g++ -std=c++17 -O2 -I. -Iext -o /out/mkworld /src/mkworld_custom.cpp \
      node/ECC.cpp node/Identity.cpp node/InetAddress.cpp node/SHA512.cpp \
      node/Salsa20.cpp node/Utils.cpp osdep/OSUtils.cpp \
      -pthread -ldl -lrt -lm \
 && strip --strip-unneeded /out/mkworld \
 && cp LICENSE.txt LICENSE-MPL.txt nonfree/LICENSE.md /out/licenses/

# ---------------------------------------------------------------------------
# ztncui (pinned commit, hardened overlay, WASM Argon2)
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS ui-builder

ARG ZTNCUI_COMMIT=1b2284864de48d2dcae22582fff122fe24909c3d
ARG GH_MIRROR=https://github.com

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init ztncui \
 && cd ztncui \
 && git remote add origin "${GH_MIRROR}/key-networks/ztncui.git" \
 && git fetch --depth 1 origin "${ZTNCUI_COMMIT}" \
 && git checkout --detach FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "${ZTNCUI_COMMIT}"

WORKDIR /src/ztncui/src

# Install from the committed lockfile before copying the overlay so that the
# dependency layer is cached and the install is reproducible.
COPY patch/ztncui/package.json patch/ztncui/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts --no-audit --no-fund

COPY patch/ztncui/ /tmp/ztncui-patch/
RUN cd /src/ztncui \
 && cp /tmp/ztncui-patch/app.js ./src/app.js \
 && cp /tmp/ztncui-patch/bin-www ./src/bin/www \
 && cp /tmp/ztncui-patch/auth.js ./src/controllers/auth.js \
 && cp /tmp/ztncui-patch/usersController.js ./src/controllers/usersController.js \
 && cp /tmp/ztncui-patch/networkController.js ./src/controllers/networkController.js \
 && cp /tmp/ztncui-patch/argon2-wasm.js ./src/argon2-wasm.js \
 && cp /tmp/ztncui-patch/ip.js ./src/ip.js \
 && cp /tmp/ztncui-patch/validate.js ./src/validate.js \
 && cp /tmp/ztncui-patch/zt.js ./src/controllers/zt.js \
 && cp /tmp/ztncui-patch/routes-index.js ./src/routes/index.js \
 && cp /tmp/ztncui-patch/routes-users.js ./src/routes/users.js \
 && rm -rf ./src/views ./src/public ./src/etc/storage \
 && cp -a /tmp/ztncui-patch/views ./src/views \
 && cp -a /tmp/ztncui-patch/public ./src/public \
 && mkdir -p ./src/tools \
 && cp /tmp/ztncui-patch/tools/init-admin.js ./src/tools/init-admin.js \
 && chmod 755 ./src/bin/www ./src/tools/init-admin.js ./src/ip.js ./src/validate.js ./src/controllers/zt.js \
 && rm -rf .git

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

LABEL org.opencontainers.image.title="docker-zerotier-planet" \
      org.opencontainers.image.description="Self-hosted ZeroTier planet and controller with TLS and hardened defaults" \
      org.opencontainers.image.source="https://github.com/ban-sky/docker-zerotier-planet" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MPL-2.0 AND LicenseRef-ZeroTier-Source-Available"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates openssl tini tzdata util-linux \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=zt-builder /out/usr/sbin/ /usr/sbin/
COPY --from=zt-builder /out/mkworld /app/mkworld
COPY --from=zt-builder /out/licenses/ /usr/share/licenses/zerotier/
COPY --from=ui-builder /src/ztncui /app/ztncui
COPY patch/entrypoint.sh /app/entrypoint.sh
COPY patch/http_server.js /app/http_server.js
COPY patch/configure-moon.js /app/configure-moon.js
COPY LICENSE /usr/share/licenses/docker-zerotier-planet/LICENSE
COPY NOTICE /usr/share/licenses/docker-zerotier-planet/NOTICE

# The CLI lives in /usr/sbin; these links match what `make install` creates and
# let users run `docker exec ... zerotier-cli` (#196).
RUN ln -sf ../../../usr/sbin/zerotier-one /var/lib/zerotier-one/zerotier-one \
 && ln -sf ../../../usr/sbin/zerotier-one /var/lib/zerotier-one/zerotier-cli \
 && ln -sf ../../../usr/sbin/zerotier-one /var/lib/zerotier-one/zerotier-idtool \
 && chmod 755 /app/entrypoint.sh /app/http_server.js /app/configure-moon.js /app/mkworld \
 && mkdir -p /app/config /app/dist /var/lib/zerotier-one/moons.d \
 && chown -R node:node /app/config /app/dist /var/lib/zerotier-one

EXPOSE 9994/udp 3443/tcp 3000/tcp
VOLUME ["/app/config", "/app/dist", "/var/lib/zerotier-one"]

# The entrypoint starts as root only to fix volume ownership, then drops to
# uid/gid 1000 for zerotier-one, ztncui and the file server.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/sbin/zerotier-cli", "info"]
