# syntax=docker/dockerfile:1
# Multi-architecture node:26-trixie-slim (Debian 13) index, reviewed 2026-11-04.
FROM node:26-trixie-slim@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS runtime-base

# Optional extra Debian packages (space-separated), e.g. "build-essential".
# They must work unprivileged; setuid bits are stripped below regardless.
ARG EXTRA_APT_PACKAGES=""

# Root is used only for image construction. No privilege-escalation packages.
# dropbear-bin ships the server binaries without the root-run init service.
# Debian's Dropbear runs /usr/lib/sftp-server from openssh-sftp-server for
# SFTP (and modern scp); no OpenSSH server or daemon is installed.
# Remove su and strip every setuid/setgid bit from the base image.
# hadolint ignore=SC2086
RUN case "$EXTRA_APT_PACKAGES" in *[!a-z0-9.+:\ -]*) echo 'invalid EXTRA_APT_PACKAGES' >&2; exit 1 ;; esac \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl git ripgrep python3 dropbear-bin \
        openssh-client openssh-sftp-server jq less procps \
        $EXTRA_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
    && rm -f /bin/su /usr/bin/su \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} + \
    && mkdir -p /opt/lucoa/bin /opt/lucoa/agents /opt/lucoa/ovis /workspace \
    && chown -R node:node /opt/lucoa /workspace /home/node

ENV HOME=/home/node \
    PATH=/opt/lucoa/bin:/home/node/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    npm_config_prefix=/opt/lucoa \
    npm_config_update_notifier=false

FROM runtime-base AS build
USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*
COPY --chown=node:node build/versions.env build/install-upstream.sh /tmp/lucoa-build/
USER node
RUN sh /tmp/lucoa-build/install-upstream.sh

WORKDIR /opt/lucoa/agents
COPY --chown=node:node build/agents/package.json build/agents/package-lock.json ./
# Skip arbitrary dependency lifecycle scripts, then run only Claude's reviewed
# binary-linking postinstall. Keep optional dependencies enabled so npm selects
# the glibc native package for this platform.
RUN npm ci --ignore-scripts --no-audit --no-fund \
    && node node_modules/@anthropic-ai/claude-code/install.cjs \
    && ln -s ../agents/node_modules/.bin/claude /opt/lucoa/bin/claude \
    && ln -s ../agents/node_modules/.bin/pi /opt/lucoa/bin/pi \
    && claude --version && pi --version

WORKDIR /opt/lucoa/ovis
RUN bun install --frozen-lockfile --ignore-scripts \
    && bun run build \
    && rm -rf node_modules \
    && bun install --production --frozen-lockfile --ignore-scripts

FROM runtime-base AS final
COPY --from=build --chown=node:node /opt/lucoa /opt/lucoa
COPY --chown=node:node build/versions.env /opt/lucoa/versions.env
COPY scripts/entrypoint.sh scripts/healthcheck.mjs scripts/services.mjs scripts/ssh-shell.sh /usr/local/lib/lucoa/
RUN chmod 755 /usr/local/lib/lucoa/entrypoint.sh /usr/local/lib/lucoa/ssh-shell.sh \
    && sed -i 's|^node:\(.*\):[^:]*$|node:\1:/usr/local/lib/lucoa/ssh-shell.sh|' /etc/passwd \
    && printf '%s\n' /usr/local/lib/lucoa/ssh-shell.sh >> /etc/shells

ENV LUCOA_SSH_ENABLED=1 \
    OVIS_RUNTIME=herdr-core \
    OVIS_HC_BIN=/opt/lucoa/bin/herdr-core \
    OVIS_STATE_DIR=/home/node/.config/ovis \
    OVIS_AUTO_UPDATE=0 \
    OVIS_TELEMETRY=0 \
    HOST=0.0.0.0 \
    PORT=7317 \
    XDG_CONFIG_HOME=/home/node/.config \
    XDG_STATE_HOME=/home/node/.local/state \
    XDG_CACHE_HOME=/home/node/.cache \
    XDG_RUNTIME_DIR=/tmp/lucoa-runtime \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    USE_BUILTIN_RIPGREP=0 \
    DISABLE_AUTOUPDATER=1 \
    PI_SKIP_VERSION_CHECK=1

WORKDIR /workspace
USER node
EXPOSE 7317 2222
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD ["node", "/usr/local/lib/lucoa/healthcheck.mjs"]
ENTRYPOINT ["/usr/local/lib/lucoa/entrypoint.sh"]
# Direct upstream server entry: prebuilt UI, no development server or runtime build.
# The container engine owns restarts; this bypasses Ovis's managed updater.
CMD ["bun", "/opt/lucoa/ovis/server/index.ts"]
