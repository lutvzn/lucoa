# AGENTS.md

## Project overview

**lucoa** is an always-on container for using coding agents from a browser through **Ovis** (https://ovis.sh). It bundles:

- Ovis
- herdr-core
- Claude Code
- pi agent

The image must use **`node:26-alpine`** as its base. Its default workload is the Ovis server with **`OVIS_RUNTIME=herdr-core`**, running continuously as a non-root user. An interactive shell is an optional command override, not the default workload.

## Container requirements

- Keep the image minimal and compatible with Alpine Linux and musl libc.
- Include Ovis and all three agent/runtime tools. Make agent/runtime executables available on `PATH` to both Ovis and interactive shells.
- Run Ovis in the foreground under a signal-safe launch strategy; leave container restart policy to the container engine.
- Persist Ovis state, agent configuration/authentication, herdr-core state, and workspaces in appropriate user-writable mounts. Persistent files do not preserve live processes across container restarts.
- Require authentication for network-accessible browser control. Never expose an ungated terminal service; document HTTPS and safe host port binding.
- Use the existing external **Traefik** HTTPS reverse proxy for primary browser access. The deployment host's LAN IP is **`10.0.0.50`**; publish testing access as `10.0.0.50:7317:7317`, restricted by host/network ingress rules to `10.0.0.0/24` and Traefik as needed. Do not publish on all host interfaces by default or configure firewall rules inside the container.
- Keep Ovis authentication enabled on the direct LAN path, not just at the proxy. Document that plain HTTP testing does not encrypt tokens or terminal traffic.
- Use a dedicated, unprivileged user to run the container and its agents. Set an explicit non-root `USER` in the final image.
- **Do not include rootful packages:** bundled tools and runtime dependencies must not require root privileges, privilege escalation, or root-owned services to operate.
- Install agent packages and their writable state in locations accessible to the non-root user. Do not rely on root's home directory or root-only package locations.
- Do not include `sudo`, `doas`, or other privilege-escalation utilities, and do not require privileged container mode.
- Any root access needed during image construction must be limited to build-time setup; it must not be required at runtime.
- Ensure the runtime user's home, workspace, caches, and configuration directories are writable by that user.
- Never bake credentials, API keys, tokens, or private configuration into image layers. Supply secrets at runtime.

## Naming transition

The project is now **lucoa** (formerly LBoA). Source, new images, Compose service,
installation paths, and test settings use `lucoa` / `LUCOA`. See README.md for
new deployment commands. Compose retains `LBOA_BIND_IP` as a fallback for existing
private `.env` files; `LUCOA_BIND_IP` takes precedence. Do not rotate credentials
or change the live port binding for this rename.

The deployment identifiers and paths in the handoff below are intentionally
historical/current-live names, not names for new builds. The existing `lboa`
container, images, volumes, and stopped rollback container have not been migrated.
Do not rename/redeploy them or create replacement volumes without approval.

## Current implementation and handoff

### Built and running

- Local image: **`localhost/lboa:local`**, built with **rootless Podman** on **linux/amd64**. Use `podman build --format docker` to preserve the image health check; Podman's default OCI format drops it.
- Pins: Ovis **0.4.22**, herdr-core **0.1.17**, Bun musl **1.4.2**, Claude Code **2.1.317**, and pi **1.5.0**. The digest-pinned base was verified as Node **26.13.0** / Alpine **3.24.3**. See `build/versions.env` and `build/agents/package-lock.json` for exact pins/checksums.
- Container **`lboa`** was last verified **running and healthy**, with `restart=unless-stopped`, engine-provided init, all capabilities dropped, and `no-new-privileges`.
- Runtime account: **`node`**, UID/GID **1000:1000**. User-owned installations live in **`/opt/lboa`**, outside persistent mounts. Default command runs the prebuilt Ovis server directly, without its managed updater.
- Persistent named volumes: **`lboa-home` -> `/home/node`** and **`lboa-workspace` -> `/workspace`**. Do not delete these volumes or replace the running instance casually; they may contain user credentials and work.
- Authentication uses a generated token in the ignored **`.env`** file, verified mode **`0600`**. Do not overwrite/rotate it without approval, copy it into documentation, or print it in agent tool output. Startup also supports `OVIS_TOKEN_FILE`.

### Python / uv image update (2026-11-04)

- Added Alpine Python **3.14.10** and checksum-pinned musl **uv / uvx 0.13.7**, without pip. Base image and non-root contract are unchanged.
- Built **`localhost/lboa:python-uv`** (image ID starts `022b609f8506`) and passed the full disposable-container smoke suite, including offline non-root venv creation, local wheel installation/import, and `uv run`. ShellCheck, shell syntax, and Python AST checks passed.
- **Deployed with user approval:** live `lboa` now runs `localhost/lboa:python-uv`, verified healthy with Python/uv available as UID 1000. Existing token, volumes, loopback binding, init, restart policy, dropped capabilities, and no-new-privileges were preserved. Host-port UI/backend, anonymous API/WebSocket-route rejection, cookie login, and Claude/pi detection passed.
- `localhost/lboa:local` still points to the previous image. The old container is retained **stopped** as `lboa-before-python-uv` for rollback; do not start it alongside `lboa` (same volumes/port).
- Usage and caveats are in README.md; detailed results are in PLAN.md. Python package-registry downloads, native compilation, and arm64 execution remain untested.
- User reports the existing setup is working; this is not an independent graphical-browser/provider-authentication test by the agent.

### Current access and network boundary

- The live instance publishes **only `127.0.0.1:7317:7317`**. Open **http://127.0.0.1:7317** locally.
- From another device, use `ssh -N -L 7317:127.0.0.1:7317 lutvzn@10.0.0.50`, then open the same localhost URL.
- **LAN publishing is not enabled.** The host has address `10.0.0.50`, but full firewall inspection required authorization. Do not assume the required source restriction is enforced or switch to LAN/all-interface publishing without verifying it.
- `.env` currently sets `LBOA_BIND_IP=127.0.0.1`; the Compose fallback remains `10.0.0.50`. The running service was started directly with Podman, not Compose. Do not launch a second Compose instance over the same port or assume its default volume names refer to the live Podman volumes.
- No host firewall or Traefik changes were made. **Traefik hostname/topology/routing is explicitly deferred at the user's request**; do not keep asking about it or treat it as a blocker for local work.
- Rootless host-reboot startup needs separate host-side user-service/boot integration. The restart policy alone is not proof that this service will start after reboot.

### Verified and still pending

- Passed the credential-free smoke suite: non-root CLI execution, root/missing-token rejection, hardened runtime, backend health, built UI assets, token/cookie login, anonymous API/WebSocket rejection, spoofed identity-header rejection, and actual Claude/pi installation detection.
- Tested core-backed workspace creation, live terminal I/O, task continuation across client disconnect/reconnect, persistent home/workspace files after recreation, file-based token startup, and graceful shutdown with exit code 0. Disposable smoke containers/volumes were removed.
- A **60-second readiness soak** passed **30 checks**, with server RSS **77,704 -> 76,944 KiB**. This does not establish overnight/24-hour stability or absence of leaks.
- The live instance separately passed checks through its host-published port: UI, backend health, anonymous API rejection, cookie login, and Claude/pi detection. Its explicit engine health check also passed.
- ShellCheck, shell/JavaScript syntax checks, and Compose/CI YAML parsing passed. Docker/Compose execution and hosted GitHub CI have not been tested here; only rootless Podman execution was verified.
- Pending: graphical-browser rendering and agent-launch UX, real provider authentication, pairing/credential restoration, Traefik HTTPS, deployment LAN filtering, bind-mount permissions, longer active-workload soak/recovery tests, arm64 validation, hosted CI, and image publication.

### Resuming safely

- Read **`README.md`** for operations and **`PLAN.md`** for detailed results and remaining tasks. Implementation includes `Dockerfile`, `compose.yaml`, `scripts/`, `build/`, `tests/`, and `.github/workflows/container.yml`.
- Read-only status checks: `podman ps --filter name='^lboa$'`, `podman healthcheck run lboa`, and `podman port lboa`. Avoid dumping container environment/inspect output containing the token.
- Run smoke tests against disposable containers built from the current source, not the live instance: `CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local`. Optionally set `LUCOA_SOAK_SECONDS=60` (up to 86400) for a bounded readiness soak.
- Leave the live test service running unless the user requests a stop/redeployment or a change requires an explicitly explained interruption. No unattended overnight monitoring has been configured; do not claim ongoing observation or promise automatic recovery beyond the configured engine behavior.

## Development guidelines

- Keep changes focused on building, configuring, and documenting this container image.
- Use installation methods supported by each tool; verify package names and sources rather than guessing them.
- Prefer pinned tool versions and reproducible installation steps.
- Avoid unnecessary dependencies, background services, and build artifacts in the final image.
- Document build and run commands, configuration, and required runtime environment variables as they are introduced.

## Validation

When changing the image or installation scripts:

1. Build the image using `node:26-alpine` as the base.
2. Confirm the default runtime user is not root (`id -u` must not return `0`).
3. Confirm Ovis starts with `OVIS_RUNTIME=herdr-core` as the default user and that herdr-core, Claude Code, and pi agent are available to it.
4. Validate HTTP readiness, browser/WebSocket terminal access, and rejection of unauthorized terminal/API access without exposing credentials.
5. Confirm configuration, cache, and workspace writes work without root privileges.
6. Confirm normal operation does not require privilege escalation or privileged container mode.
7. Verify shutdown, restart, state persistence, and continued operation after a browser disconnect.

Report any checks that could not be run rather than claiming they passed.
