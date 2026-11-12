# AGENTS.md

## Project overview

**lucoa** is an always-on container for using coding agents from a browser through **Ovis** (https://ovis.sh). It bundles:

- Ovis
- herdr-core
- Claude Code
- pi agent

The image must use **`node:26-trixie-slim`** (Debian 13, glibc) as its base, switched from `node:26-alpine` at the user's request on 2026-11-04. Its default workload is the Ovis server with **`OVIS_RUNTIME=herdr-core`**, running continuously as a non-root user. An interactive shell is an optional command override, not the default workload.

## Container requirements

- Keep the image minimal and compatible with Debian (trixie) and glibc. Install OS packages with `apt-get install --no-install-recommends` and clear apt lists in the same layer.
- Include Ovis and all three agent/runtime tools. Make agent/runtime executables available on `PATH` to both Ovis and interactive shells.
- Run Ovis in the foreground under a signal-safe launch strategy; leave container restart policy to the container engine.
- Persist Ovis state, agent configuration/authentication, herdr-core state, and workspaces in appropriate user-writable mounts. Persistent files do not preserve live processes across container restarts.
- Require authentication for network-accessible browser control. Never expose an ungated terminal service; document HTTPS and safe host port binding.
- Use the existing external **Traefik** HTTPS reverse proxy for primary browser access. The deployment host's LAN IP is **`10.0.0.50`**. Per the user's updated preference, new deployment examples default to **`0.0.0.0:7317:7317`** and **`0.0.0.0:2222:2222`**; users choose narrower bindings in run commands, Compose, or Quadlet and enforce source restrictions with host/network ingress rules. Do not configure firewall rules inside the container. Port 2222 runs Dropbear as the non-root `node` user with public-key-only authentication; users must provision `~/.ssh/authorized_keys`. Password/root login and forwarding are disabled. SSH host keys persist under `/home/node/.ssh`. This default change does not authorize changing the live deployment's loopback binding or private `.env`.
- Keep Ovis authentication enabled on the direct LAN path, not just at the proxy. Document that plain HTTP testing does not encrypt tokens or terminal traffic.
- **Prefer rootless solutions** (relaxed from a strict no-root rule at the user's request on 2026-11-06). The default workload still runs as the dedicated unprivileged `node` user, and the final image keeps an explicit non-root `USER`. Choose tools, packages, and designs that work unprivileged whenever a rootless option exists.
- Root inside the container is no longer forbidden outright. Use it only when a task has no reasonable rootless alternative, keep it opt-in rather than the default workload, and document why. Never require privileged container mode, root-owned services, or added capabilities for normal operation.
- Install agent packages and their writable state in locations accessible to the non-root user. Do not rely on root's home directory or root-only package locations.
- Avoid privilege-escalation utilities (`sudo`, `doas`, setuid helpers) by default. Adding one needs a documented reason and the user's agreement.
- Prefer limiting root during image construction to build-time setup.
- Container builds from inside lucoa use the bundled **podman-remote** client against an operator-mounted host Podman API socket (prefer a rootless host service). That socket grants full control of the host account's Podman, so it is opt-in, documented, and never mounted into the live deployment without approval.
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

### SSH image addition (not deployed)

- Added non-root Dropbear on port 2222 alongside Ovis, supervised with signal forwarding and failure propagation. SSH is enabled by default (`LUCOA_SSH_ENABLED=0` disables it), accepts public keys only, and denies root/password authentication and port forwarding.
- Host keys and authorized keys persist in `/home/node/.ssh`; an empty key file permits no SSH logins. Optional `LUCOA_SSH_AUTHORIZED_KEYS` imports public-key text (including newline-separated keys), or `LUCOA_SSH_AUTHORIZED_KEYS_FILE` copies a readable runtime public-key file at startup. Both inputs replace `authorized_keys`; nonempty conflicting inputs are rejected. No credentials or host keys are baked into the image.
- SSH shell setup supplies `/opt/lucoa/bin` and default shared hc XDG paths without forwarding service environment secrets. No SCP/SFTP subsystem is bundled.
- Built `localhost/lucoa:ssh` with rootless Podman. The full existing smoke suite and disposable `tests/ssh.sh` suite passed: key-only UID 1000 login, PTY, tools on PATH, `hc connect` RPC, disconnect continuity, denied invalid/root/password-only authentication, host-key/data persistence, graceful shutdown, and propagation of SSH service failure.
- Deployment examples, Compose, and Quadlet now use `ghcr.io/lutvzn/lucoa:latest` by default; Compose accepts `LUCOA_IMAGE`, and local builds remain documented. Registry images must be published from this source before these new features are available there; no publication was performed for this change.
- Rebuilt `localhost/lucoa:ssh` and reran both smoke suites after adding raw environment key import: multiline key login, preservation without input, conflicting inputs, blank input, and private-key text rejection passed.
- This image has **not** replaced the live `lboa` service. Herdr Desktop graphical onboarding, Docker runtime, hosted CI, Quadlet boot, arm64, and network ingress filtering remain untested. See README.md for setup and PLAN.md for details.

### Debian base migration (not built)

- Switched the Dockerfile base from `node:26-alpine` to digest-pinned `node:26-trixie-slim` (Node **26.13.0**, Debian 13; index lists amd64/arm64). OS packages now come from apt; Dropbear uses `dropbear-bin` (no root-run init service). `su` is removed and all setuid/setgid bits are stripped at build time.
- Bun and uv now use glibc release archives (checksums verified against upstream SHA256 lists and by download). herdr-core archives are static and unchanged. Claude Code selects its glibc native optional dependency from the existing lockfile.
- Python is now the Debian `python3` package (3.13 series in trixie) instead of Alpine's 3.14. Existing virtual environments created on the Alpine image are not compatible.
- **Not built or tested:** no container engine was available in the authoring session. Build with `podman build --format docker` and run both smoke suites before publishing or deploying. The live `lboa` service still runs the Alpine-based `localhost/lboa:python-uv` image; Alpine-specific notes in the handoff above describe that image.

### CI, pins, and SFTP additions (not built)

- Shared CI scripts in `ci/` back both `.github/workflows` and `.forgejo/workflows` (Forgejo: `lucoa-host:host` x86_64 runner, no pull-request trigger, `REGISTRY_TOKEN` secret for pushes). Only linux/amd64 is built, at the user's request; do not add arm64 builds.
- `ci/bump-versions.mjs` checks/rewrites pins with checksums (14-day minimum age, no downgrades); the weekly freshness workflow only reports. Available bumps found on 2026-11-06 were **not applied**.
- The image adds `openssh-client`, `openssh-sftp-server` (SFTP/scp over the existing Dropbear port), `jq`, `less`, `procps`, and an `EXTRA_APT_PACKAGES` build argument. README documents backup/restore via `tar` streams.
- Lint, ShellCheck, hadolint, and YAML parsing passed locally. **No image build, smoke/SSH run, scan, or workflow execution has happened**; see PLAN.md.

### podman-remote and rootless-preference change (not built)

- Added Debian `podman-remote` (5.4.2 in trixie; client only, no daemon), with a `podman` symlink in `/opt/lucoa/bin` and `CONTAINER_HOST=unix:///run/podman/podman.sock` (also set for SSH shells). It works only when the operator mounts a host Podman socket. Rootless hosts need `--userns=keep-id:uid=1000,gid=1000`, and SELinux hosts need `label=disable`; see README.
- `tests/podman-remote.sh` starts a temporary host API service and checks build/run/remove through it as UID 1000. `ci/test.sh` runs it only on Podman runners.
- The requirements above now prefer rootless solutions rather than forbidding root. With user approval, the entrypoint now allows UID 0 for **command overrides** (with a stderr warning) but still refuses to start the Ovis server as root. The smoke suite asserts both. The default image still ships no sudo/doas/su or setuid files, and the smoke suite still checks that.
- Not built or run, and live `lboa` is unchanged. Client/server compatibility with the host's Podman version is unverified.

### Dedicated builder account (deployed 2026-11-12)

- `host/setup-builder.sh` (host-side, run as root; not in the image) creates a hardened `lucoa-builder` account (UID/GID 6000 by default: the smallest free from 6000 up; `--uid N` overrides): nologin, locked password, `0700` home, refuses privileged groups/sudo rules. It allocates subuid/subgid ranges and adds root-owned `user-<uid>.slice` limits (default `MemoryMax=50%`, no swap, `TasksMax=4096`, CPU/IO weight 50). It runs a socket-activated rootless Podman API at `/run/lucoa-builder/podman.sock` (dir root `0700`, socket `0600`, POSIX ACLs only for `--client` UIDs) with lingering. `--uninstall [--delete-user]` reverses it; `--dry-run` previews.
- lucoa mounts the **directory** (`-v /run/lucoa-builder:/run/podman`) with `label=disable`, plus `keep-id` or a `--client` set to the mapped subordinate UID.
- Verified here: ShellCheck, dry-run/argument validation, `tmpfiles.d` ACL syntax including numeric UIDs, `systemd-analyze verify` of the units, and the ACL design with real containers. The non-owner subordinate UID connected and got a rootless API. An unrelated UID got `EACCES`, and SELinux denied the connection without `label=disable`.
- **Deployed by the user on 2026-11-12** with `--client lutvzn`. `lucoa-builder` exists as UID/GID 6000 (subids 655360+65536), is lingering, has a nologin shell, and has active slice limits (`MemoryMax` resolved to 16620539904 bytes, no swap, `TasksMax=4096`, CPU/IO weight 50). The ACLs are `/run/lucoa-builder` u:6000 rwx / u:5997 x and the socket u:5997 rw, with nothing for others.
- The live Quadlet `~/.config/containers/systemd/lucoa/lucoa.container` (container `lucoa`) now mounts `Volume=/run/lucoa-builder:/run/podman` instead of `lutvzn`'s `%t/podman/podman.sock`. Verified inside it: UID 1000, `rootless=true`, graphroot `/home/lucoa-builder/...`, no `lutvzn` containers visible, `/run/user/5997` absent. A busybox build/run worked; its process ran in `user-6000.slice/user@6000.service/.../libpod-*.scope`, and nothing was added to `lutvzn`'s store. Test images were removed.
- **Keep `lutvzn`'s own `podman.socket` enabled:** `traefik` and `forgejo-runner` mount it and `Requires=podman.socket`. Never mount it into lucoa again.
- The old unrelated `builder` account (UID 6001) was deleted by the user, including its group and subids.
- **Survives a host reboot (user-run checks, 2026-11-12):** `/run/lucoa-builder` was recreated with its ACLs, `user@6000.service` was active without a login, Podman inside lucoa was rootless on `/home/lucoa-builder` storage with no `lutvzn` containers visible, and `lucoa`, `traefik` and `forgejo-runner` all came back up.

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

1. Build the image using `node:26-trixie-slim` as the base.
2. Confirm the default runtime user is not root (`id -u` must not return `0`).
3. Confirm Ovis starts with `OVIS_RUNTIME=herdr-core` as the default user and that herdr-core, Claude Code, and pi agent are available to it.
4. Validate HTTP readiness, browser/WebSocket terminal access, and rejection of unauthorized terminal/API access without exposing credentials.
5. Confirm configuration, cache, and workspace writes work without root privileges.
6. Confirm normal operation does not require privilege escalation or privileged container mode.
7. Verify shutdown, restart, state persistence, and continued operation after a browser disconnect.

Report any checks that could not be run rather than claiming they passed.
