# lucoa implementation plan

## Goal

Build **lucoa**: an always-on, browser-accessible agent server based on **`node:26-alpine`**. Run **Ovis** (https://ovis.sh) continuously with **`OVIS_RUNTIME=herdr-core`**, backed by bundled **herdr-core**, **Claude Code**, and **pi agent**, all under an unprivileged user.

The primary workflow is opening Ovis in a browser, starting agents, interacting through chat/live terminals, and reconnecting later without stopping the agents. An interactive container shell is a maintenance override, not the default workload.

This document tracks implementation plans and upstream findings. Source review is not proof of container compatibility; runtime checks remain pending unless explicitly marked complete. `AGENTS.md` defines the project requirements.

## Project rename

Renamed source, build/test identifiers, Compose service, and documentation to
**lucoa**. New image paths use `/opt/lucoa`; new configuration uses `LUCOA_*`.
Compose preserves `LBOA_BIND_IP` as a fallback to avoid changing existing private
loopback bindings. Historical results below retain the names actually tested.
The live `lboa` deployment, volumes, credentials, and rollback container were not
changed. Earlier smoke/build results do not validate the renamed image; rebuild
and rerun disposable smoke tests before deployment.

## Python / uv addition — 2026-11-04

- Added Alpine `python3` (resolved to **3.14.10**) without pip; retained the required digest-pinned Node 26 Alpine base and non-root runtime.
- Added **uv / uvx 0.13.7**, using upstream musl release archives with SHA-256 pins for amd64 and arm64. Only amd64 was executed.
- Built **`localhost/lboa:python-uv`**, image ID `022b609f8506629bc4043c43e3e82c8b930dd26d51e874fdc96811c8b0b3e1bc`.
- Full disposable-container smoke suite passed, including the new network-disabled Python test: UID 1000, no pip, uv virtual environment creation, local wheel installation/import, and `uv run`. Existing Ovis auth, terminal/reconnect, persistence, and shutdown tests passed again. ShellCheck (`-x`), shell syntax, and Python AST checks passed.
- **Deployed with user approval:** replaced live `lboa` with `localhost/lboa:python-uv`. Preserved the exact token, named volumes, `127.0.0.1:7317` binding, init, `unless-stopped`, dropped capabilities, and no-new-privileges. Verified healthy, UID 1000, Python/uv/uvx versions, writable home/workspace, host-port UI/backend, anonymous API/WebSocket-route rejection, cookie login, and Claude/pi detection.
- Old container retained **stopped** as `lboa-before-python-uv` for rollback; never start both against the same volumes/port. `localhost/lboa:local` still points to the previous image. No token rotation, firewall, or Traefik changes were made.
- User reports the existing browser setup is working; no additional graphical/provider-authenticated checks were performed by the agent for this change. Python registry downloads, native-extension builds, and arm64 execution were not tested.

## Implementation results — 2026-11-03

- Built **`localhost/lboa:local`** with rootless Podman on **linux/amd64**, using Docker image format to preserve HEALTHCHECK metadata. Final local image ID starts `105ecf28619e`; uncompressed image size is approximately **1.12 GB** (mostly upstream binaries/dependencies).
- Full smoke suite passed, including UID 1000 execution, CLI versions, root/no-token rejection, no sudo/doas/su on PATH, no setuid/setgid files under standard system binary paths, and capability-dropped/no-new-privileges operation.
- Ovis served its built UI, reported a usable herdr-core backend, rejected anonymous API and WebSocket access and spoofed identity headers, accepted browser-style cookie login, and detected Claude/pi as installed on PATH with successful version probes.
- Created/closed a workspace through the web API and tested live terminal input/output through authenticated WebSockets. A shell command continued while the client disconnected, and its output was visible after reconnect.
- Recreated the container with the same home/workspace volumes, confirmed saved files survived, and reran the authenticated HTTP/WebSocket workflow using file-based token startup. Graceful shutdown exited with code 0.
- A **60-second readiness soak** passed **30 checks**; observed server RSS was **77,704 -> 76,944 KiB**. This is a short observation, not evidence of 24-hour stability or absence of leaks.
- ShellCheck, POSIX-shell syntax checks, JavaScript syntax checks, and Compose/CI YAML parsing passed. No Docker daemon or Compose provider is installed here, so the Compose service itself was not launched; CI has been added but not run on GitHub.
- Smoke containers and disposable volumes were removed. Subsequently started the persistent test service **`lboa`** with rootless Podman, init, `restart=unless-stopped`, dropped capabilities, and no-new-privileges. It uses named volumes `lboa-home` / `lboa-workspace` and a generated token in the ignored mode-0600 `.env` file.
- The live test service is bound only to **`127.0.0.1:7317`**, not the LAN. Host firewall queries require authorization, so the required LAN source filtering could not be verified. No host firewall or Traefik changes were made. Use a local browser or SSH tunnel until LAN filtering is confirmed.
- Live host-port checks passed: UI response, usable core backend, anonymous API rejection, cookie-based token login, and installed Claude/pi detection. Explicit `podman healthcheck run lboa` succeeded; container reports running/healthy as UID 1000. Verified only the IPv4 loopback listener on port 7317.
- Still pending: real provider-authenticated workflows and agent launch UX, graphical-browser rendering, Traefik HTTPS routing, LAN source filtering, bind-mount deployment permissions, long-duration soak, arm64 validation, and image publication.

See README.md for build, authentication, rootless Podman/Compose startup, persistence, and security instructions.

## Verified upstream findings — herdr-core

Authoritative repository: **https://github.com/herdrdev/herdr-core**, supplied by the project owner. Source reviewed at commit `b63ecbd1e6b6a7d63fb7bcf40f268930417723ba`.

- **Purpose:** runs programs and coding agents in persistent terminals, supports attaching to them, and lets agents delegate work and communicate. It does not sandbox agents.
- **Executables:** the installer places `herdr-core` in `$HOME/.local/bin` and creates an `hc` alias beside it if no conflicting `hc` exists. Verify both commands in the image.
- **Installation:** upstream documents `https://releases.herdr.dev/core/install.sh`. The installer supports `HC_VERSION` for selecting a release and `HC_INSTALL_DIR` for the destination. It requires `curl`, `tar`, and checksum/shell utilities; it does not require root. Select and record an actual release before implementing the install.
- **Integrity:** the installer checks the archive's SHA-256 against its release manifest. The manifest is trusted through HTTPS, not an independent signing key. Pin the installer revision and release inputs/checksums rather than relying on an unversioned remote script during reproducible builds.
- **Linux builds:** upstream documents static binaries for x86_64 and aarch64. This makes prebuilt binaries the preferred candidate for Alpine, but actual execution on `node:26-alpine` still needs testing. herdr-core itself is not a Node.js package.
- **Runtime:** the CLI starts a background core when needed; holder processes own terminals. These run with the invoking user's access. Do not add a root daemon or assume a system service manager is required.
- **Configuration:** `$XDG_CONFIG_HOME/herdr-core/config.toml`, defaulting to `~/.config/herdr-core/config.toml`; templates live beside it.
- **State:** `$XDG_STATE_HOME/herdr-core/<session>/`, defaulting to `~/.local/state/herdr-core/<session>/`. `HC_SESSION` selects the session, with `default` as the default.
- **Sockets:** use `$XDG_RUNTIME_DIR/herdr-core/` when set, otherwise an available `/run/user/<uid>/herdr-core/`, then the session state directory. Choose a short, private, user-writable location; do not expose the socket publicly or mount it into untrusted containers.
- **Lifecycle:** persistent terminals can survive a client disconnect or core restart, not container removal. Persistent files alone do not preserve live processes. Test container stop behavior and orphan reaping with the background core and holders.
- **Privacy:** terminal history, screens, and logs can contain secrets. Treat state volumes as sensitive. Unix state/socket directories are created with mode `0700`, but existing directory permissions are not repaired automatically.

References: [README](https://github.com/herdrdev/herdr-core/blob/b63ecbd1e6b6a7d63fb7bcf40f268930417723ba/README.md), [installer](https://github.com/herdrdev/herdr-core/blob/b63ecbd1e6b6a7d63fb7bcf40f268930417723ba/distribution/install.sh), [security and state](https://github.com/herdrdev/herdr-core/blob/b63ecbd1e6b6a7d63fb7bcf40f268930417723ba/docs/security.md).

## Verified upstream findings — Ovis

Authoritative repository linked by https://ovis.sh: **https://github.com/devswha/ovis**. Source reviewed at commit `3e5190296aa220a986200f0a253763aa1e56218d`.

- **herdr-core mode exists:** `OVIS_RUNTIME=herdr-core` selects an adapter using one `hc connect` connection for core operations and live terminals. The ordinary `herdr` TUI runtime is not the intended backend for this image.
- **Core compatibility:** the guide requires herdr-core protocol generation 1 and mentions testing with 0.1.14 and 0.1.17. These are upstream test references, not our selected pins. Verify the chosen release pair together.
- **Core discovery:** `OVIS_HC_BIN` can specify the full executable path. Set it explicitly to avoid discovery ambiguity.
- **Ovis runtime:** upstream requires Bun 1.4+; the reviewed package declares `bun@1.4.2`. Node alone is not a substitute. A pinned musl-compatible Bun installation and build/runtime testing are required while retaining the mandated Node base.
- **Network:** upstream defaults to `HOST=127.0.0.1`, `PORT=7317`. A normal bridge-network deployment needs Ovis bound to the container interface, with authenticated access and carefully scoped host port publishing.
- **State:** `OVIS_STATE_DIR` defaults to `~/.config/ovis`; it includes pairing/device state, keys, and other settings. Mount it privately with service-user ownership. The core adapter enforces user ownership and mode `0700` on its Ovis state directory.
- **Authentication:** `OVIS_TOKEN` gates unpaired/non-trusted clients. Pairing and Tailscale identity also exist. For the first deployment, require a runtime-supplied token before accepting network-accessible service operation; verify browser login and all terminal HTTP/WebSocket paths.
- **Production launch:** `bun run start` builds the UI and then runs `server/managed.ts`. Build assets in the image and verify a foreground launch path that does not rebuild on every restart. The managed launcher participates in upstream's updater/supervisor lifecycle; choose deliberately rather than adding overlapping supervision.
- **Alpine caveat:** the install guide says its prebuilt Rust PTY host has no Alpine build. The guide also says herdr-core mode streams live terminals through `hc connect`. Test this mode on musl before deciding whether another PTY host or native dependency is necessary; do not assume ordinary-runtime PTY limitations apply identically.
- **Installation:** use a pinned source/release build, not the one-line desktop/plugin installer, which can install ordinary herdr and change Tailscale configuration.

References: [installation](https://github.com/devswha/ovis/blob/3e5190296aa220a986200f0a253763aa1e56218d/INSTALL.md), [herdr-core mode](https://github.com/devswha/ovis/blob/3e5190296aa220a986200f0a253763aa1e56218d/docs/guide.md#herdr-app-terminals), [runtime adapter](https://github.com/devswha/ovis/blob/3e5190296aa220a986200f0a253763aa1e56218d/server/herdr-core/runtime.ts), [package scripts](https://github.com/devswha/ovis/blob/3e5190296aa220a986200f0a253763aa1e56218d/package.json).

## Intended deployment

```text
Browser
  -> existing Traefik HTTPS reverse proxy (primary access)
     OR http://10.0.0.50:7317 (restricted LAN testing)
  -> authenticated Ovis HTTP/WebSocket server (:7317 inside container)
  -> herdr-core (hc connect, private local sockets)
  -> Claude Code / pi / workspace shells
```

- Default workload: Ovis server with `OVIS_RUNTIME=herdr-core`, not a shell.
- Ovis, hc, and agents share one non-root account; no root-owned daemon or systemd is needed.
- The container engine owns 24/7 restart behavior (`unless-stopped` in the planned Compose example).
- Primary browser access uses the user's existing **Traefik** HTTPS reverse proxy, outside this image, with WebSocket upgrade/streaming support.
- The confirmed container host LAN IP is **`10.0.0.50`**. Publish TCP `7317` on that address for testing within **`10.0.0.0/24`**.
- Planned Compose binding: `10.0.0.50:7317:7317`. If parameterized with `LUCOA_BIND_IP`, use `10.0.0.50` in the deployment example. Do not default to `0.0.0.0` or put a CIDR in the bind-address field. This is planned configuration, not a live port mapping.
- Traefik can use `http://10.0.0.50:7317` as its upstream if reachable from its deployment. If it shares a container network, direct service-name routing to port `7317` is an alternative. Confirm topology before choosing file-provider configuration versus Docker labels; never mount a Docker socket into lucoa.
- Restrict ingress to testing clients in `10.0.0.0/24` and the reverse proxy's explicit source address if it is outside that subnet. Binding an interface does not filter client source addresses: enforce this with container-engine-aware host/network firewall rules and test it. Account for published-port forwarding and IPv6 rather than assuming an ordinary host firewall automatically covers them.
- Keep `OVIS_TOKEN` required on both proxy and LAN access paths; LAN access must not bypass Ovis authentication or rely solely on authentication at the reverse proxy.
- Direct `http://10.0.0.50:7317` is a testing-only path on a trusted LAN: tokens and terminal traffic are not encrypted there. Prefer the existing HTTPS endpoint for real use, especially when handling credentials. No WAN port forwarding or direct public exposure is planned.
- Host firewall/proxy configuration remains outside the container. Do not add firewall tooling, network-administration capabilities, or root services to the image.
- Persist workspace files, Ovis state, herdr-core config/state, and agent settings/authentication. Keep ephemeral sockets in a private runtime directory.
- Browser disconnects must not stop agents. Container termination stops live processes; restart restores persisted files/settings, not guaranteed in-flight agent execution.
- Prefer image rebuild/redeployment for updates. Set `OVIS_AUTO_UPDATE=0`; verify manual in-app update behavior rather than claiming all update paths are disabled.

## Non-negotiable requirements

- Use `node:26-alpine` as the base image. If it is unavailable, report the blocker rather than silently choosing another base.
- Set an explicit non-root `USER` in the final image.
- Do not include rootful packages: no bundled tool may require root privileges, privilege escalation, or a root-owned service at runtime.
- Do not include `sudo`, `doas`, or require privileged container mode or a host container-engine socket.
- Limit root access to necessary image-build setup.
- Keep agent installations, configuration, caches, and working directories accessible to the runtime user.
- Supply credentials at runtime; never copy them into the build context or image layers.
- Keep the final image small and avoid unnecessary services and dependencies.
- Run Ovis as the default foreground workload with `OVIS_RUNTIME=herdr-core`.
- Never expose unauthenticated terminal control. Supply access tokens at runtime and keep them out of logs, health-check arguments, and image layers.

## Phase 1 — Verify upstream requirements

- [x] Confirm that `node:26-alpine` is available and identify its Alpine version and supported architectures. Verified Node 26.13.0 / Alpine 3.24.3; registry index lists amd64 and arm64, with local execution tested only on amd64.
- [x] Confirm Ovis's authoritative source and documented/source-level support for `OVIS_RUNTIME=herdr-core`.
- [x] Select an Ovis release containing herdr-core mode, a compatible herdr-core release, and a pinned musl-compatible Bun version: Ovis 0.4.22, hc 0.1.17, Bun 1.4.2.
- [x] Verify Ovis dependency installation, frontend build, server startup, and core-backed terminals on Alpine amd64. Tested live terminal I/O through hc without the ordinary-runtime PTY host.
- [x] Confirm herdr-core's authoritative repository, documented installation method, executable names, and purpose through source review.
- [x] Select herdr-core 0.1.17, verify its manifest, and pin artifact checksums. Download the checked archive directly instead of running an unversioned installer.
- [x] Verify the supported npm installations and executables: Claude Code 2.1.317 (`claude`, musl native optional dependency) and `@earendil-works/pi-coding-agent` 1.5.0 (`pi`).
- [x] Run all three agent/runtime executables on Node 26 / Alpine amd64, retaining required native assets. Real authenticated provider workflows remain pending.
- [x] Include Bash, Git, certificates, curl, ripgrep, libgcc, and libstdc++ as runtime utilities; no compiler or root service is needed for the tested path.
- [x] Document home/config/state/authentication paths in README.md; persist the full user home without overlaying installed tools.
- [x] Record pins and upstream artifact checksums in build/versions.env and agent dependencies in build/agents/package-lock.json.

**Exit condition:** a verified dependency/install matrix for Ovis, Bun, and all three agent/runtime tools. Any unsupported tool/base combination is an explicit blocker, not a reason to silently change the base or omit a tool.

## Phase 2 — Define the runtime contract

- [x] Use the base image's unprivileged `node` account, UID/GID 1000:1000.
- [x] Set a writable `/home/node` and `/workspace` owned by that user.
- [x] Use node-owned `/opt/lucoa` for installations and put `/opt/lucoa/bin` on PATH. This deliberately keeps installations outside the persistent home so image upgrades do not retain stale tools in a home volume.
- [x] Define writable XDG config/state/cache locations under the user's home.
- [x] Document UID/GID and bind-mount ownership without a privileged startup repair script.
- [x] Persist separate home and workspace volumes; the home contains credentials, configuration, and state.
- [x] Default to foreground Ovis with `OVIS_RUNTIME=herdr-core` and explicit `OVIS_HC_BIN`, preserving command overrides.
- [x] Set `HOST=0.0.0.0`, `PORT=7317` inside the container; require a nonblank runtime token without printing it. Accept either OVIS_TOKEN or a readable OVIS_TOKEN_FILE.
- [x] Record deployment decisions: host `10.0.0.50`, Traefik HTTPS reverse proxy, and LAN testing on TCP `7317` for `10.0.0.0/24`.
- [x] Define Compose publishing on `10.0.0.50:7317:7317` and document host-side subnet/proxy ingress filtering. No live port or firewall changes have been applied.
- [ ] Confirm Traefik's location/network, public hostname, TLS entrypoint/certificate configuration, upstream reachability, WebSocket behavior, and trusted-forwarded-header/origin handling. Do not trust identity headers supplied by direct LAN clients.
- [ ] Verify browser-based launch of Claude Code and pi, working directories, and any required integrations/templates. The core starts on demand; no root service is planned.
- [x] Define OVIS_STATE_DIR, disable automatic updates, and run `bun /opt/lucoa/ovis/server/index.ts` directly against prebuilt assets. The update API reports unmanaged mode; container-engine restart policy replaces upstream managed supervision.
- [x] Use private config/state directories and `/tmp/lucoa-runtime` for hc runtime sockets, with owned directories set to `0700`.
- [x] Use engine-provided init (`init: true` / `--init`) rather than bundling a supervisor. Verify SIGTERM shutdown in smoke tests.

**Exit condition:** documented user, paths, command behavior, and persistence model.

## Phase 3 — Implement the image

Implementation files:

| File | Purpose |
| --- | --- |
| `Dockerfile` | Base image, minimal dependencies, pinned tool installs, non-root runtime, and default command. |
| `.dockerignore` | Exclude repository metadata, local dependencies, credentials, environment files, and build output. |
| `README.md` | Build/run instructions, configuration, authentication, persistence, and security limitations. |
| `tests/smoke.sh` | Automated checks for the image's runtime contract. |
| `compose.yaml` | Always-on example with restart policy, init, explicit LAN-IP port publishing, persistent mounts, and runtime configuration. |
| `scripts/entrypoint.sh` | Non-root/token/path validation and exec of server or command override. |
| `scripts/healthcheck.mjs` | Bounded public health probe checking backend readiness and auth gating. |
| `tests/http.mjs` | Credential-free authenticated API/WebSocket terminal tests. |
| `tests/soak.mjs` | Optional bounded readiness soak with server RSS observations. |
| `build/versions.env` | Archive version/revision/checksum pins. |
| `build/agents/package{,-lock}.json` | Agent package and transitive dependency pins. |
| `.github/workflows/container.yml` | amd64 build and credential-free smoke CI; not yet run on GitHub. |

Tasks:

- [x] Create the Dockerfile with a verified `node:26-alpine` index digest.
- [x] Install verified runtime OS dependencies with root only during image setup; remove the base image's su launcher.
- [x] Install pinned agents as node into user-owned `/opt/lucoa/agents`, with their commands exposed on PATH.
- [x] Retain required native/optional assets. Skip arbitrary npm lifecycle scripts and invoke only Claude's reviewed binary-linking postinstall.
- [x] Use a build stage for downloads/frontend compilation; do not include unzip or build caches in the final stage.
- [x] Install pinned musl Bun, build Ovis with its frozen lockfile/patches, then install production-only Ovis dependencies.
- [x] Avoid build-time agent login and provider credentials.
- [x] Set HOME, PATH, WORKDIR, and explicit non-root USER.
- [x] Use an exec-form command and unprivileged entrypoint with exec forwarding.
- [x] Use an allowlisted .dockerignore to exclude secrets and unrelated host files.
- [x] Document/expose internal port 7317, keeping hc sockets private.
- [x] Add a bounded health probe that checks backend ping and authentication gating without a token.
- [x] Add Compose restart/init settings and secret/state mount instructions; document unhealthy-status limitations.

**Exit condition:** the image builds, starts authenticated Ovis by default in herdr-core mode, and exposes all three agent/runtime executables to the non-root service user.

## Phase 4 — Validate behavior and security

Automated smoke tests should:

- [x] Inspect the image user and confirm UID 1000 at runtime.
- [x] Confirm Node 26 and the Alpine base.
- [x] Run every bundled CLI's version command without provider credentials.
- [x] Confirm writable home, workspace, configuration, cache, and installation prefix.
- [x] Confirm sudo/doas/su are not on PATH and installs do not depend on root's home.
- [x] Run with all capabilities dropped and no-new-privileges, without privileged mode or an engine socket.
- [ ] Confirm bind-mounted workspace access and persistence using compatible ownership.
- [x] Verify maintenance command overrides, graceful shutdown, and exit code 0.
- [x] Exercise a credential-free core-backed shell lifecycle through Ovis, checking private state/runtime directory permissions. Standalone hc CLI workflows beyond version checks can be expanded later.
- [x] Verify built browser assets and successful backend health, without Vite at runtime.
- [x] Verify missing-token startup refusal and unauthorized API/WebSocket rejection, using unlogged ephemeral test tokens.
- [x] Test browser-protocol cookie login, shell launch, live WebSocket I/O, disconnect, and reconnect while a command continues. Graphical rendering is a separate pending check.
- [ ] Verify the existing HTTPS proxy serves the UI and live terminals, including authentication, streaming, and reconnects.
- [ ] Verify authenticated testing from an allowed `10.0.0.0/24` client to the host's LAN port. Verify disallowed source networks cannot reach it and no unintended IPv6/all-interface publishing bypasses the restriction. Mark these checks pending if the deployment network is unavailable.
- [x] Reject spoofed forwarding/Tailscale/Portal identity headers in container-local API tests; repeat over the real LAN/proxy ingress during deployment validation.
- [x] Confirm Ovis detects Claude Code and pi as installed/on PATH with successful version reads.
- [ ] Test actual browser agent-launch UX and authenticated chat/terminal workflows when credentials are available.
- [x] Recreate the container and verify home/workspace marker files survive; rerun the full web workflow with file-based token startup.
- [ ] Verify real Ovis pairing/device enrollment and agent credential/session restoration after recreation.
- [x] Perform a bounded 60-second readiness soak and record RSS/check counts above. Live client reconnect was tested in the HTTP/WebSocket suite.
- [ ] Run a longer soak under active agent workloads.
- [x] Verify clean shutdown with the core/holders active and engine init enabled; the container stops with exit code 0. No live-process survival across container restart is promised.
- [ ] Check for accidentally copied credentials and leftover build-only dependencies.

Additional validation:

- [ ] Test authenticated agent workflows separately using runtime-injected credentials, never embedded test secrets.
- [ ] Establish which architectures can be supported by testing them; do not publish untested architecture claims.
- [x] Record initial image size and review dependencies; production-only Ovis packages are included, without build caches/compiler tooling.
- [x] Document remaining tooling, credential, platform, and deployment validation gaps.

**Exit condition:** automated checks pass, and any untested authenticated behavior or other limitations are explicitly documented.

## Phase 5 — Documentation and automation

- [x] Document Docker/Podman builds, startup, restart policy, browser authentication, and maintenance commands.
- [x] Document the deferred Traefik upstream, WebSocket needs, explicit LAN binding, and host-side source filtering.
- [x] Explain cleartext testing, disabling/restricting LAN access afterward, and the distinction between interface binding and a source allowlist.
- [x] Document backups/redeployment and the effect of restarts on live agents.
- [x] Document environment variables and persistent paths.
- [x] Explain bind-mount ownership, persistent state, and runtime credentials.
- [x] Explain the shared-account security boundary and recommend minimal mounts.
- [x] Add amd64 build/smoke CI without provider credentials; GitHub execution remains pending.
- [ ] Choose a registry, image name, release tags, and supported architectures before adding publication automation.
- [ ] Keep publishing gated on successful builds and tests, and publish only tested platforms.

## Open questions

1. Deferred at the user's request: Traefik hostname and deployment topology. Host IP (`10.0.0.50`), proxy choice (Traefik), and LAN subnet/port (`10.0.0.0/24`, TCP `7317`) are confirmed; these proxy details do not block local image development.
2. Initial pins are selected and tested on amd64; decide the desired cadence for future dependency updates.
3. Initial validation is `linux/amd64` only. Are additional architectures required before release?
4. Which registry and image name should be used for publication?

## Remaining implementation order

1. Configure a private runtime token and deployment-host ingress rules before publishing the LAN port; validate actual LAN reachability/filtering and bind-mount permissions if used.
2. Configure and test Traefik HTTPS routing when the user is ready; keep this deferred for now.
3. Test graphical-browser agent launch, real provider authentication, pairing, and session/settings restoration.
4. Run longer active-workload soak/recovery tests and execute CI on the hosted runner.
5. Validate any additional architectures before declaring support.
6. Choose registry/release details and add gated image publication.
