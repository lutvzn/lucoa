# lucoa

Run **Claude Code** and **pi** in your browser with [Ovis](https://ovis.sh)
and **herdr-core**. lucoa packages them in an always-on, non-root container,
with persistent storage for your projects, settings, and agent credentials.

```text
Browser → Ovis → herdr-core → Claude Code / pi
```

- **Base:** Node 26 on Alpine Linux (musl).
- **Runtime user:** `node`, UID/GID `1000:1000`; no sudo or privileged mode.
- **Default workload:** Ovis in the foreground with `OVIS_RUNTIME=herdr-core`.
- **Also included:** Python 3, uv, and uvx.
- **Access:** authenticated browser UI; use the existing Traefik proxy for HTTPS.

> **Existing deployment:** this project was formerly LBoA. The live `lboa`
> container has not been migrated. Do not start these examples on its occupied
> port or reuse its volumes in a second running container. See
> [Existing LBoA deployment](#existing-lboa-deployment) before operating it.

## Contents

- [Setup](#setup)
- [Choose a deployment method](#choose-a-deployment-method)
  - [Docker run](#docker-run)
  - [Docker Compose](#docker-compose)
  - [Podman run](#podman-run)
  - [Podman Quadlet](#podman-quadlet)
- [Open the browser UI](#open-the-browser-ui)
- [Use agents and Python](#use-agents-and-python)
- [Persistent storage](#persistent-storage)
- [Networking and HTTPS](#networking-and-https)
- [Maintenance](#maintenance)
- [Versions and builds](#versions-and-builds)
- [Publish to GHCR](#publish-to-ghcr)
- [Validation](#validation)
- [Existing LBoA deployment](#existing-lboa-deployment)

## Setup

### 1. Check requirements

Use Docker with Compose v2, or rootless Podman. Quadlet additionally requires
Linux, a user systemd manager, cgroup v2, and a compatible Podman version.

Run the commands below from this repository. Builds require internet access to
the container registry, Alpine repositories, npm, GitHub, and
`releases.herdr.dev`—but no provider credentials.

**Linux amd64 is the validated target.** The build script supports selecting
arm64 artifacts, but arm64 execution has not been validated.

### 2. Create a private environment file

Ovis requires a nonblank token at startup. It is also your browser sign-in
credential.

For a **new installation only**, generate `.env` without printing the token
(requires host `openssl`):

```sh
# Refuse to overwrite an existing .env.
(umask 077; set -C; printf 'LUCOA_BIND_IP=127.0.0.1\nOVIS_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env)
```

If `.env` already exists, keep it and its token. For local-only Compose access,
set `LUCOA_BIND_IP=127.0.0.1` in that file. See [`.env.example`](.env.example)
for available settings.

Keep `.env` private (mode `0600`); it is ignored by Git and excluded from the
image build context. Store the token in a password manager. Never put it in a
URL or share environment dumps, `docker compose config`, or container-inspect
output containing secrets. Anyone controlling the container engine can read
runtime environment variables.

**Alternative: a mounted token file.** Direct Docker/Podman deployments also
accept `OVIS_TOKEN_FILE`. Set either `OVIS_TOKEN` or `OVIS_TOKEN_FILE`, not both.
The mounted file must be readable by UID 1000 or its rootless host mapping;
startup does not repair permissions. The Compose example uses `OVIS_TOKEN`.

## Choose a deployment method

Choose **one** method. Every example below binds to **`127.0.0.1:7317`** and
uses init, dropped capabilities, and `no-new-privileges`.

| Method | Best for | Restart management |
| --- | --- | --- |
| Docker run | A standalone Docker container | Docker restart policy |
| Docker Compose | Repeatable configuration in one file | Docker restart policy |
| Podman run | A standalone rootless container | Podman restart policy |
| Podman Quadlet | A rootless systemd-managed service | User systemd service |

Do not run two deployments against the same home/workspace volumes.
Docker and Podman use separate image and volume stores; matching names do not
share data between engines.

### Docker run

**Build and start:**

```sh
docker build -t lucoa:local .
docker run -d --name lucoa --init --restart=unless-stopped \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --stop-timeout=20 \
  --env-file .env -p 127.0.0.1:7317:7317 \
  -v lucoa-home:/home/node -v lucoa-workspace:/workspace \
  lucoa:local
```

**Manage:**

```sh
docker ps --filter name='^lucoa$'
docker logs --tail=100 lucoa
docker exec -it lucoa /bin/bash
```

Use `docker stop lucoa` and `docker start lucoa` to stop/start without removing
data. For host-reboot recovery, the Docker daemon must also start at boot.

### Docker Compose

The checked-in [`compose.yaml`](compose.yaml) builds the image locally.

**Build and start:**

```sh
LUCOA_BIND_IP=127.0.0.1 docker compose up -d --build
```

**Manage:**

```sh
docker compose ps
docker compose logs --tail=100 lucoa
docker compose exec lucoa /bin/bash
```

Use `docker compose stop` / `docker compose start` for existing containers.
`docker compose down` removes containers and the network but keeps named volumes.
**`docker compose down -v` deletes persistent data.**

Important differences from the direct-run examples:

- Keep `LUCOA_BIND_IP=127.0.0.1` in `.env`, or prefix every `up` command as above.
  Without an override or legacy setting, Compose defaults to `10.0.0.50`.
- Compose normally creates project-prefixed volumes such as `lucoa_home` and
  `lucoa_workspace`, not `lucoa-home` and `lucoa-workspace`. Switching methods
  does not migrate your data.
- `LBOA_BIND_IP` remains a fallback when `LUCOA_BIND_IP` is unset.

### Podman run

Run as your normal host user, not root.

**Build and start:**

```sh
podman build --format docker -t localhost/lucoa:local .
podman run -d --name lucoa --init --restart=unless-stopped \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --stop-timeout=20 \
  --env-file .env -p 127.0.0.1:7317:7317 \
  -v lucoa-home:/home/node -v lucoa-workspace:/workspace \
  localhost/lucoa:local
```

**Manage:**

```sh
podman ps --filter name='^lucoa$'
podman logs --tail=100 lucoa
podman healthcheck run lucoa
podman exec -it lucoa /bin/bash
```

Use `podman stop lucoa` / `podman start lucoa` to stop/start. The restart policy
alone does not establish rootless boot startup; use Quadlet for that integration.

> Keep `--format docker` when building with Podman. Its default OCI format drops
> the image health check.

### Podman Quadlet

The ready-to-copy [`examples/quadlet/lucoa.container`](examples/quadlet/lucoa.container)
runs the locally built image as a rootless user service. It publishes localhost
only and uses the `lucoa-home` / `lucoa-workspace` named volumes.

**Build and install as the host user who will run the service:**

```sh
podman build --format docker -t localhost/lucoa:local .
mkdir -p "$HOME/.config/containers/systemd" "$HOME/.config/lucoa"
chmod 700 "$HOME/.config/lucoa"
# Preserve an existing destination file and its token.
(umask 077; cp -n .env "$HOME/.config/lucoa/lucoa.env")
chmod 600 "$HOME/.config/lucoa/lucoa.env"
cp examples/quadlet/lucoa.container "$HOME/.config/containers/systemd/"

systemctl --user daemon-reload
systemctl --user start lucoa.service
```

**Manage through systemd, not `podman stop/start`:**

```sh
systemctl --user status lucoa.service
journalctl --user -u lucoa.service -n 100 --no-pager
systemctl --user stop lucoa.service
systemctl --user start lucoa.service
```

**Configuration notes:**

- The unit reads `%h/.config/lucoa/lucoa.env`, where `%h` is the host user's home.
- Edit `PublishPort=` in the unit to change the binding. `LUCOA_BIND_IP` and
  `LBOA_BIND_IP` in its environment file do not control publishing.
- `Pull=never` requires the image to exist in that user's Podman store.
- Named volumes are created if absent. They are not the live `lboa-*` volumes.
- Systemd owns restarts (`Restart=always`); there is no Podman restart policy.
  A manual systemd stop stays stopped until another start or boot/login activation.

**Boot startup:** do not run `systemctl --user enable lucoa.service`. Quadlet
uses `[Install] WantedBy=default.target` to generate startup integration.
Running without a login and surviving logout also requires user lingering:

```sh
loginctl show-user "$USER" -p Linger
```

If disabled, ask the host administrator to authorize/configure
`loginctl enable-linger <host-user>`. This is a host-only operation, not a
container privilege requirement. Boot startup has not been verified here.

After editing the Quadlet, run `systemctl --user daemon-reload` and
`systemctl --user restart lucoa.service`. To remove startup integration, stop
the service, remove its `.container` file, and reload the user manager. Volumes
and the private environment file remain.

See the [upstream Quadlet documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
for host requirements and troubleshooting.

## Open the browser UI

Open **http://127.0.0.1:7317** and sign in with your Ovis token.

From another device, use the host's SSH server to tunnel the browser port:

```sh
ssh -N -L 7317:127.0.0.1:7317 lutvzn@10.0.0.50
```

Then open the same localhost URL on that device. Adjust the host user/address
if deploying elsewhere.

**This is a tunnel to Ovis, not SSH into the container.** An SSH endpoint for
Herdr Desktop is not implemented yet.

## Use agents and Python

### Claude Code and pi

Create a workspace in Ovis and launch an agent from the picker or terminal.
Authenticate using that agent's supported login flow. Credentials and sessions
persist in the home volume.

You can also launch them from a running container:

```sh
docker compose exec lucoa claude
docker compose exec lucoa pi
```

For API keys, use a private Compose override with the required environment
variables or an `env_file`. The base Compose service does **not** forward
arbitrary host API keys. Never pass credentials as image build arguments.
Real provider calls require your own account and credentials.

### Python with uv

Python 3, `uv`, and `uvx` are on PATH for agents and shells. Pip is not installed.

```sh
cd /workspace/my-project
uv venv --python /usr/bin/python3
uv pip install requests
.venv/bin/python -c 'import requests; print(requests.__version__)'

# A project with pyproject.toml and uv.lock:
uv sync --locked
uv run python main.py

# An isolated Python CLI tool:
uvx ruff --version
```

Virtual environments under `/workspace` persist. uv's cache and user tools live
in the persisted home; `~/.local/bin` is already on PATH. Downloads need network
access. Prefer the included system Python; other versions depend on uv's
platform-specific download availability.

Alpine uses musl. Native extensions need compatible wheels or extra build
dependencies; compilers, Python development headers, and pip are not bundled.
Recreate virtual environments after an incompatible system Python update, and
do not reuse environments created on incompatible hosts.

## Persistent storage

| Container path | Contents | Storage |
| --- | --- | --- |
| `/home/node` | Credentials, sessions, configuration, caches | Home volume |
| `/home/node/.config/ovis` | Ovis devices, pairing, settings, keys | Home volume |
| `/home/node/.config/herdr-core` | Core configuration and templates | Home volume |
| `/home/node/.local/state/herdr-core` | Core records, logs, saved terminal state | Home volume |
| `/workspace` | Projects and working files | Workspace volume |
| `/tmp/lucoa-runtime` | Private hc runtime sockets | Ephemeral |
| `/opt/lucoa` | Installed tools and Ovis build | Image |

Home/config/state/runtime directories are private (`0700`). Installed tools stay
outside persistent mounts so an old home volume does not hide image upgrades.
Ovis's adapter socket lives in its state directory, but sockets are not portable
persisted process state.

**Persistence saves files, not live processes.** Closing the browser leaves
agents running. Stopping or recreating the container ends its live processes;
volumes do not guarantee resuming in-flight work.

### Use a host project directory

Replace the workspace volume with a bind mount in a local Compose override.
The runtime user must be able to write it:

- Rootful Docker usually needs ownership compatible with UID/GID 1000.
- Rootless Podman uses user-namespace mappings; arrange permissions through the
  host mapping or a deliberate `--userns` strategy.
- SELinux hosts may need a dedicated `:Z` mount label.

Do not recursively change host ownership without reviewing the affected files.
The container never elevates privileges or fixes ownership at startup.

## Networking and HTTPS

### Local access

Use `127.0.0.1:7317:7317` until host ingress filtering is verified. Do not publish
on all interfaces. Ovis authentication remains required, even behind a proxy.

### Direct LAN testing

The deployment host's LAN address is `10.0.0.50`. To test directly on the LAN,
change the host binding to **`10.0.0.50:7317:7317`**, but first:

1. Allow TCP 7317 only from **`10.0.0.0/24`** and Traefik's source as needed.
2. Verify the rules cover the engine's published-port forwarding path. Generic
   input-chain or UFW rules may not filter Docker-forwarded traffic.
3. Test rejection from disallowed networks and check for unintended IPv6 or
   other-interface exposure.
4. Do not add WAN forwarding for this test port.

Binding an IP is **not** a source allowlist. This project does not install host
firewall rules or configure them inside the container.

**Plain HTTP does not encrypt tokens, terminal output, or keystrokes.** Keep
Ovis authentication enabled on the direct path, and use HTTPS for normal network
access.

### Traefik HTTPS

Use the existing external Traefik proxy. Its hostname, routing, TLS configuration,
and network topology are managed separately and remain deferred.

The planned upstream is `http://10.0.0.50:7317` if reachable from Traefik. A shared
container network can instead route directly to port `7317`.

Preserve the public host/scheme, support WebSocket upgrades and long-lived
streams, and verify origin handling. Never trust client-supplied identity headers
as authentication or mount the engine socket just for proxy discovery.
After testing, disable direct LAN access or restrict it to Traefik's source.

## Maintenance

### Health and restarts

The image health check calls `/api/health` locally, checks the backend ping and
authentication gate, and never supplies or logs a token. The login UI, static
assets, and limited health/discovery endpoints are intentionally public;
terminal control and protected APIs require authentication.

**Unhealthy does not mean restarted.** Docker's restart policy handles process
exits, not a merely unhealthy container. The supplied Quadlet also restarts on
process exit, not health failure. Recovery from a hung process needs separate
external monitoring.

The server runs in the foreground, receives `SIGTERM`, and uses engine-provided
init to reap orphaned children. No unattended monitoring is configured by this
repository.

### Update the image

Updates are image-driven. Keep the same environment file and volumes.

| Deployment | Update procedure |
| --- | --- |
| Docker run | Rebuild; `docker stop lucoa && docker rm lucoa`; repeat the original run command |
| Docker Compose | `docker compose build --pull`, then `LUCOA_BIND_IP=127.0.0.1 docker compose up -d` |
| Podman run | Rebuild; `podman stop lucoa && podman rm lucoa`; repeat the original run command |
| Quadlet | Rebuild as the service's host user; `systemctl --user restart lucoa.service` |

Removing a container is not permission to delete its volumes. Back up home and
workspace volumes **while stopped**. Treat backups as secrets: they may include
credentials, terminal histories, and source code.

Update checked-in pins/lockfiles to change bundled tool versions. Ovis automatic
updates and Claude background updates are disabled; startup bypasses Ovis's
managed updater. Manual installation can still modify user-owned tools.
Recreating the container restores image-provided tools outside persistent mounts.

### Disposable maintenance shells

A command override runs instead of Ovis and does not require a token at the image
entrypoint level:

```sh
docker run --rm -it lucoa:local /bin/bash
podman run --rm -it localhost/lucoa:local /bin/bash
# Compose still requires its .env interpolation:
docker compose run --rm lucoa hc --version
```

Direct disposable shells above do not mount persistent data. Use `exec` on the
running service when you need its existing workspace and credentials.

### Security boundary

Ovis and herdr-core can control everything accessible to the runtime user.
**They are not agent sandboxes.** Non-root execution does not protect files,
credentials, or network services you explicitly make accessible. Mount only what
is needed, do not expose hc sockets to untrusted clients, and do not run untrusted
agents alongside sensitive sessions under this shared account.

## Versions and builds

| Component | Pin |
| --- | --- |
| Base | `node:26-alpine`, digest pinned in `Dockerfile` |
| Node / Alpine at that digest | 26.13.0 / 3.24.3 |
| Ovis | 0.4.22, revision `a4ff0c942716602c43362f05c8511984e2bcae44` |
| herdr-core (`hc`) | 0.1.17, protocol generation 1 |
| Bun (musl) | 1.4.2 |
| Claude Code (musl) | 2.1.317 |
| pi | `@earendil-works/pi-coding-agent` 1.5.0 |
| Python 3 | Alpine package; version follows its repository |
| uv / uvx (musl) | 0.13.7 |

Upstream archives are SHA-256 checked against [`build/versions.env`](build/versions.env).
Agent dependencies use [`build/agents/package-lock.json`](build/agents/package-lock.json);
Ovis uses its upstream Bun lockfile and patches. Alpine repositories are not
snapshotted, so OS builds are not bit-for-bit reproducible.

Bun builds the UI during image construction. Startup runs the production server,
not Vite or a runtime frontend build.

## Publish to GHCR

In GitHub, open **Actions → Publish container to GHCR → Run workflow** and select
the branch. Check **Also tag as latest** only when you want to replace `latest`.

The workflow builds Linux amd64, runs the credential-free smoke suite, and
publishes only after tests pass:

| Tag | When published |
| --- | --- |
| `ghcr.io/lutvzn/lucoa:sha-<full-commit-sha>` | Every successful workflow run |
| `ghcr.io/lutvzn/lucoa:latest` | Only when **Also tag as latest** is checked |

The workflow uses the automatic `GITHUB_TOKEN` with `packages: write`; no personal
access token is needed for publication. Repository/organization policy must
allow it. Packages may initially be private, and private pulls require registry
authentication.

```sh
docker pull ghcr.io/lutvzn/lucoa:latest
```

Publishing does **not** deploy or restart containers. The examples above build
locally; using a registry image is a separate choice. The manual workflow must
exist on the default branch to show **Run workflow**. Since `latest` can be
published from any selected branch, choose carefully.

## Validation

Run smoke tests against a **disposable deployment**, never the live instance:

```sh
sh tests/smoke.sh lucoa:local

# Rootless Podman:
CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local

# Optional bounded readiness soak (seconds, maximum 86400):
LUCOA_SOAK_SECONDS=60 CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
```

The suite creates disposable volumes and an ephemeral token, publishes no ports,
and does not modify Traefik or the firewall. It checks non-root execution, tool
availability, authentication, core-backed workspaces, WebSocket terminal I/O and
reconnect, file persistence, and graceful shutdown.

Rootless Podman execution has been verified. Docker/Compose execution, hosted CI,
Quadlet runtime/boot startup, graphical-browser rendering, real provider login,
LAN filtering, Traefik HTTPS, long-duration soak, and arm64 need further
validation. See [`PLAN.md`](PLAN.md) for results and remaining work.

## Existing LBoA deployment

New builds use **lucoa**, `/opt/lucoa`, `LUCOA_BIND_IP`, and `LUCOA_SOAK_SECONDS`.
The current live deployment deliberately retains its old names:

| Resource | Existing value |
| --- | --- |
| Container | `lboa` |
| Image | `localhost/lboa:python-uv` |
| Installed tools | `/opt/lboa` |
| Persistent volumes | `lboa-home`, `lboa-workspace` |
| Stopped rollback container | `lboa-before-python-uv` |
| Published address | `127.0.0.1:7317:7317` |

It was started directly with Podman, not Compose. The private `.env` currently
uses `LBOA_BIND_IP=127.0.0.1`; Compose retains this fallback, with
`LUCOA_BIND_IP` taking precedence.

Do not rename/redeploy the live instance, replace its volumes, rotate its token,
or start the rollback container alongside it without approval. A migration
requires an approved interruption with the existing token and volumes preserved.
Use the legacy names for live operations; new example volumes do not contain
its data. See [`AGENTS.md`](AGENTS.md) and [`PLAN.md`](PLAN.md) for the handoff.
