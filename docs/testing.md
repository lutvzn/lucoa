# Testing

Run smoke tests against a **disposable deployment**, never the live instance:

```sh
sh tests/smoke.sh lucoa:local

# Rootless Podman:
CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local

# SSH/SFTP integration (requires host ssh, ssh-keygen, and sftp):
CONTAINER_ENGINE=podman sh tests/ssh.sh localhost/lucoa:local
# Docker: sh tests/ssh.sh lucoa:local

# podman-remote via a temporary host API service (rootless Podman host only):
sh tests/podman-remote.sh localhost/lucoa:local

# Optional bounded readiness soak (seconds, maximum 86400):
LUCOA_SOAK_SECONDS=60 CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
```

The main smoke suite creates disposable volumes and an ephemeral token, publishes
no ports, and checks non-root tools, authentication, core-backed workspaces,
WebSocket I/O/reconnect, file persistence, and shutdown. The SSH suite additionally
publishes an ephemeral **loopback-only test port**, generates disposable keys,
and checks key login, denied authentication, PTY access, SFTP transfer, `hc connect` RPC,
disconnect continuity, host-key persistence, and service failure propagation.
Neither suite modifies Traefik or the firewall.

The CI scripts wrap the same checks: `sh ci/install-tools.sh && sh ci/lint.sh &&
sh ci/build.sh lucoa:local && sh ci/test.sh lucoa:local && sh ci/scan.sh lucoa:local`.

Rootless Podman execution has been verified. Docker/Compose execution, hosted CI,
Quadlet runtime/boot startup, graphical-browser rendering, real provider login,
LAN filtering, Traefik HTTPS, long-duration soak, and arm64 need further
validation. See [`PLAN.md`](PLAN.md) for results and remaining work.
