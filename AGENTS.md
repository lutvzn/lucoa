## Project overview

**lucoa** is an always-on container for using coding agents from a browser through **Ovis** (https://ovis.sh). It bundles:

- Ovis
- herdr-core
- Claude Code
- pi agent

The image must use a digest-pinned **`fedora:45`** (Fedora 45, glibc) base, switched from `node:26-trixie-slim` at the user's request on 2026-11-13 (previously `node:26-alpine` on 2026-11-04). Its default workload is the Ovis server with **`OVIS_RUNTIME=herdr-core`**, running continuously as a non-root user. An interactive shell is an optional command override, not the default workload.

## Container requirements

- Keep the image minimal and compatible with Fedora and glibc. Install OS packages with `dnf -y install --setopt=install_weak_deps=False` and clean the dnf caches in the same layer. Node 26 comes from the checksum-pinned official tarball (Fedora does not ship it).
- Include Ovis and all three agent/runtime tools. Make agent/runtime executables available on `PATH` to both Ovis and interactive shells.
- Run Ovis in the foreground under a signal-safe launch strategy; leave container restart policy to the container engine.
- Persist Ovis state, agent configuration/authentication, herdr-core state, and workspaces in appropriate user-writable mounts. Persistent files do not preserve live processes across container restarts.
- Require authentication for network-accessible browser control. Never expose an ungated terminal service; document HTTPS and safe host port binding.
- Use the existing external **Traefik** HTTPS reverse proxy for primary browser access. The deployment host's LAN IP is **`10.0.0.50`**. Per the user's updated preference, new deployment examples default to **`0.0.0.0:7317:7317`** and **`0.0.0.0:2222:2222`**; users choose narrower bindings in run commands, Compose, or Quadlet and enforce source restrictions with host/network ingress rules. Do not configure firewall rules inside the container. Port 2222 runs Dropbear as the non-root `lutvzn` user (UID/GID 5997) with public-key-only authentication; users must provision `~/.ssh/authorized_keys`. Password/root login and forwarding are disabled. SSH host keys persist under `/home/lutvzn/.ssh`. This default change does not authorize changing the live deployment's loopback binding or private `.env`.
- Keep Ovis authentication enabled on the direct LAN path, not just at the proxy. Document that plain HTTP testing does not encrypt tokens or terminal traffic.
- **Prefer rootless solutions** (relaxed from a strict no-root rule at the user's request on 2026-11-06). The default workload still runs as the dedicated unprivileged `node` user, and the final image keeps an explicit non-root `USER`. Choose tools, packages, and designs that work unprivileged whenever a rootless option exists.
- Root inside the container is no longer forbidden outright. Use it only when a task has no reasonable rootless alternative, keep it opt-in rather than the default workload, and document why. Never require privileged container mode, root-owned services, or added capabilities for normal operation.
- Install agent packages and their writable state in locations accessible to the non-root user. Do not rely on root's home directory or root-only package locations.
- Avoid privilege-escalation utilities (`sudo`, `doas`, setuid helpers) by default. Adding one needs a documented reason and the user's agreement.
- Prefer limiting root during image construction to build-time setup.
- Container builds from inside lucoa use the bundled **podman-remote** client against an operator-mounted host Podman API socket (prefer a rootless host service). That socket grants full control of the host account's Podman, so it is opt-in, documented, and never mounted into the live deployment without approval.
- Ensure the runtime user's home, workspace, caches, and configuration directories are writable by that user.
- Never bake credentials, API keys, tokens, or private configuration into image layers. Supply secrets at runtime.

## Naming

The project is **lucoa**. Source, images, the Compose service, paths, and test settings
use `lucoa` / `LUCOA`. Do not rotate credentials or change a live port binding without approval.

## Current state (2026-11-13)

- Base: digest-pinned `fedora:45`, glibc, amd64 builds only.
- Runtime user: `lutvzn` (UID/GID 5997), home `/home/lutvzn`. No other account.
- Node 26.13.0 is managed by fnm (`FNM_DIR=/opt/lucoa/fnm`). fnm 1.39.0 is pinned by checksum.
- Default workload: Ovis with `OVIS_RUNTIME=herdr-core`, supervised with Dropbear SSH by `scripts/services.sh`.
- Shell and Python tooling only in the image: `scripts/`, `tests/*.sh`, `tests/python.py`. Node is still present for Claude Code and pi.
- Host-side admin (builder account, Quadlet CLI) is in the sibling repository `../lucoa-host`.
- Docs: `README.md` (setup), `docs/` (SSH, agents, podman-remote, operations, build/CI, testing).
- Live deployments: nothing in this repository changed the running `lucoa` Quadlet service.
  Do not redeploy it, re-own its volumes, rotate its token or change its loopback binding without approval.
- Not verified: arm64, hosted CI, graphical browser rendering, real provider logins, Quadlet boot,
  the dotfiles bootstrap, and long soak runs.
- Full dated handoff history: `docs/history/AGENTS-handoff-2026-11.md` and `docs/history/PLAN-2026-11.md`.

## Development guidelines

- Keep changes focused on building, configuring, and documenting this container image.
- Use installation methods supported by each tool; verify package names and sources rather than guessing them.
- Prefer pinned tool versions and reproducible installation steps.
- Avoid unnecessary dependencies, background services, and build artifacts in the final image.
- Document build and run commands, configuration, and required runtime environment variables as they are introduced.

## Validation

When changing the image or installation scripts:

1. Build the image using the digest-pinned `fedora:45` base.
2. Confirm the default runtime user is not root (`id -u` must not return `0`).
3. Confirm Ovis starts with `OVIS_RUNTIME=herdr-core` as the default user and that herdr-core, Claude Code, and pi agent are available to it.
4. Validate HTTP readiness, browser/WebSocket terminal access, and rejection of unauthorized terminal/API access without exposing credentials.
5. Confirm configuration, cache, and workspace writes work without root privileges.
6. Confirm normal operation does not require privilege escalation or privileged container mode.
7. Verify shutdown, restart, state persistence, and continued operation after a browser disconnect.

Report any checks that could not be run rather than claiming they passed.
