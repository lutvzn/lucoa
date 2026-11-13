# syntax=docker/dockerfile:1
# Digest-pinned fedora:45 (Fedora 45, glibc), reviewed 2026-11-13.
FROM docker.io/library/fedora:45@sha256:a7d72ba2745b100a3351087472e5ee7b2450af7cf331e7673007e3817612839c AS runtime-base

# Optional extra Fedora packages (space-separated), e.g. "gcc make".
# They must work unprivileged; setuid bits are stripped below regardless.
ARG EXTRA_DNF_PACKAGES=""

# Root is used only for image construction. No privilege-escalation packages.
# Fedora's dropbear package provides the server and dropbearkey without an
# enabled service. Its SFTP subsystem runs /usr/libexec/openssh/sftp-server,
# which comes from openssh-server. The sshd daemon and its units are removed
# below, so no OpenSSH daemon is present in the image.
# podman-remote is only a client: it builds/runs images through a host Podman
# API socket that the operator chooses to mount (see README); no daemon here.
# Remove su and strip every setuid/setgid bit from the base image.
# hadolint ignore=SC2086
RUN case "$EXTRA_DNF_PACKAGES" in *[!a-z0-9.+_:\ -]*) echo 'invalid EXTRA_DNF_PACKAGES' >&2; exit 1 ;; esac \
    && dnf -y install --setopt=install_weak_deps=False \
        bash ca-certificates curl git ripgrep python3 dropbear unzip \
        openssh-clients openssh-server xz libatomic jq less procps-ng podman-remote \
        $EXTRA_DNF_PACKAGES \
    && rm -f /usr/sbin/sshd /usr/lib/systemd/system/sshd*.service /usr/lib/systemd/system/sshd*.socket \
        /etc/systemd/system/multi-user.target.wants/sshd.service \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/libdnf5 \
    && rpm -e --nodeps sudo \
    && rm -f /bin/su /usr/bin/su \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} + \
    && groupadd --gid 5997 lutvzn \
    && useradd --uid 5997 --gid 5997 --create-home --home-dir /home/lutvzn --shell /bin/bash lutvzn \
    && mkdir -p /opt/lucoa/bin /opt/lucoa/agents /opt/lucoa/ovis /workspace \
    && chown -R lutvzn:lutvzn /opt/lucoa /workspace /home/lutvzn

# fnm manages Node: fnm binary and Node 26 under FNM_DIR, both checksum-pinned.
COPY build/versions.env build/install-fnm.sh /tmp/lucoa-build/
RUN sh /tmp/lucoa-build/install-fnm.sh && rm -rf /tmp/lucoa-build \
    && chown -R lutvzn:lutvzn /opt/lucoa/fnm

ENV HOME=/home/lutvzn \
    FNM_DIR=/opt/lucoa/fnm \
    PATH=/opt/lucoa/bin:/opt/lucoa/fnm/aliases/default/bin:/home/lutvzn/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    npm_config_prefix=/opt/lucoa \
    npm_config_update_notifier=false

FROM runtime-base AS build
USER root
RUN dnf -y install --setopt=install_weak_deps=False unzip \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/libdnf5
COPY --chown=lutvzn:lutvzn build/versions.env build/install-upstream.sh /tmp/lucoa-build/
USER lutvzn
RUN sh /tmp/lucoa-build/install-upstream.sh

WORKDIR /opt/lucoa/agents
COPY --chown=lutvzn:lutvzn build/agents/package.json build/agents/package-lock.json ./
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
COPY --from=build --chown=lutvzn:lutvzn /opt/lucoa /opt/lucoa
COPY --chown=lutvzn:lutvzn build/versions.env /opt/lucoa/versions.env
COPY scripts/entrypoint.sh scripts/healthcheck.sh scripts/services.sh scripts/ssh-shell.sh /usr/local/lib/lucoa/
RUN chmod 755 /usr/local/lib/lucoa/entrypoint.sh /usr/local/lib/lucoa/ssh-shell.sh \
    /usr/local/lib/lucoa/healthcheck.sh /usr/local/lib/lucoa/services.sh \
    && ln -s /usr/bin/podman-remote /opt/lucoa/bin/podman \
    && sed -i 's|^lutvzn:\(.*\):[^:]*$|lutvzn:\1:/usr/local/lib/lucoa/ssh-shell.sh|' /etc/passwd \
    && printf '%s\n' /usr/local/lib/lucoa/ssh-shell.sh >> /etc/shells

ENV LUCOA_SSH_ENABLED=1 \
    CONTAINER_HOST=unix:///run/podman/podman.sock \
    OVIS_RUNTIME=herdr-core \
    OVIS_HC_BIN=/opt/lucoa/bin/herdr-core \
    OVIS_STATE_DIR=/home/lutvzn/.config/ovis \
    OVIS_AUTO_UPDATE=0 \
    OVIS_TELEMETRY=0 \
    HOST=0.0.0.0 \
    PORT=7317 \
    XDG_CONFIG_HOME=/home/lutvzn/.config \
    XDG_STATE_HOME=/home/lutvzn/.local/state \
    XDG_CACHE_HOME=/home/lutvzn/.cache \
    XDG_RUNTIME_DIR=/tmp/lucoa-runtime \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    USE_BUILTIN_RIPGREP=0 \
    DISABLE_AUTOUPDATER=1 \
    PI_SKIP_VERSION_CHECK=1

WORKDIR /workspace
USER lutvzn
EXPOSE 7317 2222
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD ["/usr/local/lib/lucoa/healthcheck.sh"]
ENTRYPOINT ["/usr/local/lib/lucoa/entrypoint.sh"]
# Direct upstream server entry: prebuilt UI, no development server or runtime build.
# The container engine owns restarts; this bypasses Ovis's managed updater.
CMD ["bun", "/opt/lucoa/ovis/server/index.ts"]
