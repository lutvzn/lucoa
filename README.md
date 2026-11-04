# lucoa

An always-on, **non-root** container for using **Claude Code** and **pi** from a browser through [Ovis](https://ovis.sh), with **`OVIS_RUNTIME=herdr-core`**.

```text
Browser -> existing Traefik HTTPS proxy -> Ovis -> herdr-core -> agents
                     LAN test path: http://10.0.0.50:7317
```

## Rename and existing deployments

This project is now **lucoa** (formerly LBoA). New builds use `lucoa:local`,
service/container name `lucoa`, and installation paths under `/opt/lucoa`.
Use `LUCOA_BIND_IP` and `LUCOA_SOAK_SECONDS` for new configuration. Compose
still accepts the legacy `LBOA_BIND_IP` when `LUCOA_BIND_IP` is unset, so an
existing loopback-only `.env` does not silently switch to LAN publishing.
Do not regenerate an existing `.env` or rotate its token for this rename.

The existing Podman deployment has **not** been renamed or redeployed: it still
uses container `lboa`, image `localhost/lboa:python-uv`, and volumes
`lboa-home` / `lboa-workspace`. Its installed paths remain `/opt/lboa`.
The stopped rollback container remains `lboa-before-python-uv`. Use those legacy
names when operating that instance. The examples below describe new deployments;
do not start a second instance on the same port or assume new volume names contain
your existing data. Migrating the live deployment requires a separate, approved
stop/recreation with its existing volumes and token preserved.

## Included versions

| Component | Pin |
| --- | --- |
| Base | `node:26-alpine`, digest pinned in `Dockerfile` |
| Node / Alpine at the pinned digest | 26.13.0 / 3.24.3 |
| Ovis | 0.4.22, revision `a4ff0c942716602c43362f05c8511984e2bcae44` |
| herdr-core (`hc`) | 0.1.17, protocol generation 1 |
| Bun (musl) | 1.4.2 |
| Claude Code (musl) | 2.1.317 |
| pi | `@earendil-works/pi-coding-agent` 1.5.0 |
| Python 3 | Alpine `python3` package (version follows the Alpine repository) |
| uv / uvx (musl) | 0.13.7 |

Upstream archives are SHA-256 checked against checked-in values in `build/versions.env`. Agent dependencies use `build/agents/package-lock.json`; Ovis uses its upstream Bun lockfile and patches. Alpine package repositories are not snapshotted, so this is not a bit-for-bit reproducible OS build.

Initial validation targets **Linux amd64**. The download script also selects arm64 artifacts, but arm64 is not a tested/supported release target yet.

## Build

Docker with Compose v2:

```sh
docker build -t lucoa:local .
```

Or rootless Podman:

```sh
podman build --format docker -t localhost/lucoa:local .
```

Use Podman's `--format docker` to retain the Dockerfile health check (its default OCI format drops it).

The build needs internet access to the container registry, Alpine repositories, npm, GitHub, and `releases.herdr.dev`. It never needs provider credentials. Bun builds the web client during image construction; startup runs the production server directly, not Vite or a frontend build.

## Publish to GitHub Container Registry

In GitHub, open **Actions → Publish container to GHCR → Run workflow** and
select the branch to build. Check **Also tag as latest** if this build should
replace the current `latest` image (unchecked by default). The workflow builds a **Linux amd64** image, runs
the credential-free smoke suite, and publishes only if the tests pass.

Images are published as:

- `ghcr.io/lutvzn/lucoa:sha-<full-commit-sha>` for every successful run.
- `ghcr.io/lutvzn/lucoa:latest` only when **Also tag as latest** is checked.
  This can publish from any selected branch, so choose the branch carefully.

The workflow uses the automatic `GITHUB_TOKEN` with `packages: write`; no
personal access token or registry secret needs to be configured. Repository or
organization policy must allow package publishing. A newly published GHCR
package may be private; manage its visibility and Actions access in the package
settings. Pulling a private package requires registry authentication.

```sh
docker pull ghcr.io/lutvzn/lucoa:latest
```

Publishing does not deploy or restart any running container. The Compose setup
continues to build locally; using a published image is a separate deployment
choice. The manual workflow must exist on the default branch before GitHub
shows its **Run workflow** button.

## Python development with uv

Python 3, `uv`, and `uvx` are on PATH for Ovis agents and interactive shells.
Pip is not installed; use uv to manage project dependencies as the non-root user:

```sh
cd /workspace/my-project
uv venv --python /usr/bin/python3
uv pip install requests
.venv/bin/python -c 'import requests; print(requests.__version__)'
# For projects with pyproject.toml / uv.lock:
uv sync --locked
uv run python main.py
# Run isolated Python CLI tools:
uvx ruff --version
```

Virtual environments under `/workspace` persist with the workspace volume. uv's
cache and user tool installations live under the persisted home; its default tool
bin directory (`~/.local/bin`) is already on PATH. Package/tool downloads need
network access. Prefer the included system Python; requesting other Python
versions depends on uv's platform-specific download availability.

Alpine uses musl: native extensions need compatible wheels or additional build
dependencies. Compilers, Python development headers, and pip are not bundled.
Recreate virtual environments if a later image changes the system Python version;
do not reuse host-created environments across incompatible platforms.

## Configure authentication

Ovis refuses default service startup without a nonblank token. Generate a private `.env` file without printing the secret:

```sh
(umask 077; printf 'LUCOA_BIND_IP=10.0.0.50\nOVIS_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env)
```

Requires host `openssl`. Do not overwrite an existing `.env` if you want to preserve its token. `.env.example` documents the settings. `.env` is ignored by Git and excluded from the image build context.

The token is the browser sign-in credential: enter it into Ovis's login form when opening the service. Keep it in a password manager. Do not send it in URLs, paste it into logs, or share generated `docker compose config`/container-inspect output containing secrets. Runtime environment variables are visible to users who control the container engine.

For a direct `docker run`/`podman run` deployment, the entrypoint also accepts **`OVIS_TOKEN_FILE`** pointing to a readable mounted secret file. Set either `OVIS_TOKEN` or `OVIS_TOKEN_FILE`, not both. The file must be readable by UID 1000 (or its rootless host mapping); no root startup script fixes secret-file permissions. The supplied Compose example uses the environment-variable method.

## Before publishing the LAN port

The Compose mapping is **`10.0.0.50:7317:7317`**, configurable through `LUCOA_BIND_IP`. It binds a specific host address, **not** a source-address allowlist.

Before starting on the deployment host:

1. Configure host/network ingress rules allowing TCP 7317 from **`10.0.0.0/24`**, plus Traefik's source if needed.
2. Ensure those rules cover the container engine's published-port forwarding path. Do not assume a generic host input-chain rule or UFW rule filters Docker-forwarded traffic.
3. Verify the port is not reachable from disallowed networks and is not unintentionally published on IPv6 or other interfaces.
4. Do not add WAN forwarding for this testing port.

Firewall rules are deliberately **not** installed by this project: they are host-specific and must not run inside the agent container. Until filtering is configured, use `LUCOA_BIND_IP=127.0.0.1` for local-only testing.

Direct LAN HTTP is a **testing-only** path. Tokens, terminal output, and keystrokes are not encrypted. Use your existing Traefik HTTPS endpoint for normal access. Authentication is still required on the direct LAN path; proxy authentication alone is not sufficient.

## Start the always-on service

After configuring the token and host ingress rules:

```sh
docker compose up -d --build
docker compose ps
docker compose logs --tail=100 lucoa
```

For rootless Podman without a Compose provider, after the same token/firewall setup:

```sh
podman run -d --name lucoa --init --restart=unless-stopped \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --env-file .env -p 10.0.0.50:7317:7317 \
  -v lucoa-home:/home/node -v lucoa-workspace:/workspace \
  localhost/lucoa:local
```

This direct command uses the literal host binding shown; change it to `127.0.0.1:7317:7317` for local-only testing. Rootless host-reboot startup also needs host-side user-service/boot integration (for example a user Quadlet with appropriate lingering); a process restart policy alone is not a guarantee of reboot startup. That host configuration is not installed here.

For LAN testing, open **http://10.0.0.50:7317**. With Compose, you can temporarily bind to localhost without editing the file:

```sh
LUCOA_BIND_IP=127.0.0.1 docker compose up -d
```

Compose enables `init`, drops all Linux capabilities, sets `no-new-privileges`, and uses `restart: unless-stopped`. There is no privileged mode, Docker socket, root service, or privilege-escalation package installation. The image uses the base image's **`node` account, UID/GID `1000:1000`**. Its entrypoint also rejects root execution.

A maintenance command overrides the server and does not need a token at the image-entrypoint level:

```sh
docker run --rm -it lucoa:local /bin/bash
# Compose still requires .env interpolation even for a command override:
docker compose run --rm lucoa hc --version
docker compose exec lucoa /bin/bash
```

## Agent authentication and working files

Open a shell/workspace in Ovis and start Claude Code or pi from the agent picker or terminal. Authenticate through each agent's supported login flow. Agent credentials and sessions persist in the home volume. You can also start a CLI through `docker compose exec -it lucoa claude` or `docker compose exec -it lucoa pi`.

For API keys, add a private Compose override with the required provider environment variables or an `env_file`; the base Compose service does **not** automatically forward arbitrary host API keys. Never add keys as Dockerfile build arguments. Real provider calls require your own account/credentials.

| Path | Purpose | Persistence |
| --- | --- | --- |
| `/home/node` | Home, credentials, agent sessions, caches, configuration | Compose `home` volume |
| `/home/node/.config/ovis` | Ovis devices, pairing, settings, keys | Within `home` |
| `/home/node/.config/herdr-core` | Core config/templates | Within `home` |
| `/home/node/.local/state/herdr-core` | Core records, logs, saved terminal state | Within `home` |
| `/workspace` | Projects and default working directory | Compose `workspace` volume |
| `/tmp/lucoa-runtime` | Private ephemeral hc runtime sockets | Container-local |
| `/opt/lucoa` | User-owned installed tools and Ovis build | Image, not a persistent volume |

Ovis also keeps its adapter socket inside its state directory; that socket is not portable persisted process state. Home/config/state/runtime directories are private (`0700`). Installations live outside the persisted home so image upgrades do not leave an old package installation hidden in a volume.

To use an existing project directory, replace the workspace named volume with a bind mount in a local Compose override. Ensure the runtime UID can write it. Rootful Docker generally needs ownership compatible with UID/GID 1000; rootless Podman uses user-namespace mappings, so arrange ownership through the host's mapping or an intentional `--userns` strategy. SELinux hosts may need a dedicated `:Z` mount label. Do not recursively change host ownership without reviewing what will be affected. The container never elevates privileges or repairs host ownership at startup.

## Traefik

Traefik is managed separately. Its hostname/router, TLS configuration, and network topology are deferred.

The planned upstream is **`http://10.0.0.50:7317`** if Traefik can reach that host address. A shared container network can instead route directly to service port `7317`. Preserve the public request host/scheme, support WebSocket upgrades and long-lived streams, and verify origin handling. Never trust client-supplied identity headers as authentication. Do not mount the engine socket into lucoa just to support discovery.

After testing, disable direct LAN publishing or restrict the upstream port to Traefik's source. Keep Ovis authentication enabled either way.

## Health, lifecycle, and updates

The image health check calls `/api/health` locally with a timeout, verifies the backend ping succeeded and the authentication gate is present, and never supplies/logs a token. Ovis intentionally serves the login UI, static assets, and limited health/discovery endpoints without authentication; terminal control and protected APIs must remain gated.

A health failure marks the container unhealthy; **Docker's restart policy does not restart a merely unhealthy container**. Process exits are restarted by the engine. Monitor health externally if you need automatic recovery from a hung process.

Closing the browser does not stop agents. Stopping/recreating the container stops live processes; persistent volumes retain files/settings, not a guarantee of resuming in-flight agent execution. `SIGTERM` is forwarded to the foreground server, and Compose's init reaps orphaned children.

Updates are image-driven:

```sh
docker compose build --pull
docker compose up -d
```

Change checked-in pins/lockfiles to update bundled tools. Ovis automatic updates and Claude background updates are disabled; the Ovis managed updater is bypassed by direct server startup. Manual tool installation/update commands may still modify user-owned files; this is not an immutable or multi-user security boundary. Recreate the image to return installed tools to their pinned versions.

Back up home and workspace volumes while the service is stopped. Treat backups as secrets: terminal histories and agent sessions can contain credentials and source code. `docker compose down` preserves named volumes; **`docker compose down -v` deletes them**.

## Validation

```sh
sh tests/smoke.sh lucoa:local
# Rootless Podman:
CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
# Optional bounded readiness soak, in seconds (up to 24 hours):
LUCOA_SOAK_SECONDS=60 CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
```

The script uses disposable volumes and an ephemeral token, publishes no ports, and does not modify Traefik or the host firewall. It checks non-root execution, installed tools, refusal to start without authentication, HTTP login/protected APIs, core-backed workspaces, WebSocket terminal input/output/reconnect, persistence after recreation, and graceful shutdown.

Graphical browser rendering, real provider authentication, deployment-host firewall reachability, Traefik HTTPS routing, long-duration soak, and arm64 require additional validation. See `PLAN.md` for current results and remaining work.

## Security boundary

Ovis/herdr-core control everything the runtime user can access. They are **not agent sandboxes**, and a non-root account does not protect files, credentials, or network services you explicitly grant to it. Mount only the projects and secrets needed, do not expose hc sockets to untrusted clients, and do not run untrusted agents alongside sensitive sessions under this shared account.
