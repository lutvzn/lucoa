# lucoa

Run **Claude Code** and **pi** in your browser with [Ovis](https://ovis.sh)
and **herdr-core**. lucoa packages them in an always-on, non-root container,
with persistent storage for your projects, settings, and agent credentials.

```text
Browser → Ovis → herdr-core → Claude Code / pi
```

- **Base:** Node 26 on Debian 13 "trixie" slim (glibc).
- **Runtime user:** `node`, UID/GID `1000:1000`; no sudo or privileged mode.
- **Default workload:** Ovis in the foreground with `OVIS_RUNTIME=herdr-core`.
- **Also included:** Python 3, uv, uvx, and key-only SSH via Dropbear.
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
- [SSH and Herdr Desktop](#ssh-and-herdr-desktop)
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

The deployment examples use **`ghcr.io/lutvzn/lucoa:latest`**. Pulls need access
to GHCR; private packages require `docker login ghcr.io` or `podman login ghcr.io`.
Use this repository for the supplied Compose/Quadlet files.

**Use an image published from this SSH-capable source.** Local code changes do
not publish a new GHCR image, and an older `latest` may lack these SSH options.
See [Publish to GHCR](#publish-to-ghcr). For reproducible deployments, replace
`latest` with a published `sha-<full-commit-sha>` tag or image digest.

**Linux amd64 is the validated target.** The build script supports selecting
arm64 artifacts, but arm64 execution has not been validated.

### 2. Create a private environment file

Ovis requires a nonblank token at startup. It is also your browser sign-in
credential.

For a **new installation only**, generate `.env` without printing the token
(requires host `openssl`):

```sh
# Refuse to overwrite an existing .env.
(umask 077; set -C; printf 'LUCOA_BIND_IP=0.0.0.0\nOVIS_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env)
```

If `.env` already exists, keep it and its token. New examples default to all
host IPv4 interfaces (`0.0.0.0`); an existing `.env` may override the Compose
browser binding. See [`.env.example`](.env.example) for available settings.

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

Choose **one** method. Every example below publishes on **all host IPv4
interfaces** and uses init, dropped capabilities, and `no-new-privileges`:

| Host binding | Container port | Purpose |
| --- | --- | --- |
| `0.0.0.0:7317` | `7317` | Ovis browser UI |
| `0.0.0.0:2222` | `2222` | Key-only SSH as `node` |

**You control reachability.** Restrict host/network ingress and, if desired,
change the published addresses before starting. `0.0.0.0` is a bind address,
not a browser destination or a source allowlist. Ovis still requires its token.

SSH starts alongside Ovis, but accepts no logins until you provision a public
key. Follow [SSH and Herdr Desktop](#ssh-and-herdr-desktop) after startup.

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

**Pull and start:**

```sh
docker pull ghcr.io/lutvzn/lucoa:latest
docker run -d --name lucoa --init --restart=unless-stopped \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --stop-timeout=20 \
  --env-file .env \
  -p 0.0.0.0:7317:7317 -p 0.0.0.0:2222:2222 \
  -v lucoa-home:/home/node -v lucoa-workspace:/workspace \
  ghcr.io/lutvzn/lucoa:latest
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

The checked-in [`compose.yaml`](compose.yaml) uses GHCR by default. Set
`LUCOA_IMAGE` in `.env` to select a different published tag or digest.

**Pull and start:**

```sh
docker compose pull
LUCOA_BIND_IP=0.0.0.0 docker compose up -d
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

- The browser binding defaults to `0.0.0.0`. Set `LUCOA_BIND_IP` in `.env` or
  prefix `up` as above to choose the address. SSH separately publishes on
  `0.0.0.0:2222`; edit its mapping in `compose.yaml` to restrict it.
- Compose normally creates project-prefixed volumes such as `lucoa_home` and
  `lucoa_workspace`, not `lucoa-home` and `lucoa-workspace`. Switching methods
  does not migrate your data.
- `LBOA_BIND_IP` remains a fallback when `LUCOA_BIND_IP` is unset.

### Podman run

Run as your normal host user, not root.

**Pull and start:**

```sh
podman pull ghcr.io/lutvzn/lucoa:latest
podman run -d --name lucoa --init --restart=unless-stopped \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --stop-timeout=20 \
  --env-file .env \
  -p 0.0.0.0:7317:7317 -p 0.0.0.0:2222:2222 \
  -v lucoa-home:/home/node -v lucoa-workspace:/workspace \
  ghcr.io/lutvzn/lucoa:latest
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

### Podman Quadlet

The ready-to-copy [`examples/quadlet/lucoa.container`](examples/quadlet/lucoa.container)
runs the GHCR image as a rootless user service. It publishes both ports on
`0.0.0.0` and uses the `lucoa-home` / `lucoa-workspace` named volumes.

**Pull and install as the host user who will run the service:**

```sh
podman pull ghcr.io/lutvzn/lucoa:latest
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
- You decide which interfaces to publish: edit each `PublishPort=` in the unit.
  Both default to `0.0.0.0`; use a specific host IP or `127.0.0.1` if preferred.
  Host/network firewall rules determine which clients can connect.
  `LUCOA_BIND_IP` and `LBOA_BIND_IP` in its environment file do not control
  Quadlet publishing.
- `Image=ghcr.io/lutvzn/lucoa:latest` selects the image. Change it to pin a release.
  `Pull=missing` pulls only if absent; pull explicitly before restarting to update.
  Private pulls need registry credentials usable by the service's host user.
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

Open **http://10.0.0.50:7317** from an allowed device, or
**http://127.0.0.1:7317** on the container host, and sign in with your Ovis token.
Use your deployment host's address if different; do not browse to `0.0.0.0`.
Plain HTTP is for testing; use Traefik HTTPS for normal network access.

If you restrict the browser port to localhost, use the host's SSH server to
tunnel it from another device:

```sh
ssh -N -L 7317:127.0.0.1:7317 lutvzn@10.0.0.50
```

Then open the same localhost URL on that device. Adjust the host user/address
if deploying elsewhere.

**This tunnel reaches Ovis, not container SSH.** Use port `2222` for SSH into
the container as described below. Applying new port mappings or an updated image
requires container recreation; these examples do not change the live deployment.

## SSH and Herdr Desktop

Dropbear runs as **`node` (UID 1000)** on port **2222**, alongside Ovis. It requires
a public key; password login, root login, and port forwarding are disabled.
It does not require root, extra capabilities, or an unlocked password account.
There is no bundled SCP/SFTP subsystem; Herdr's `hc connect` uses command/stdio.

### 1. Authorize your desktop's public key

If needed, create a key **on your desktop** (use a passphrase when prompted):

```sh
ssh-keygen -t ed25519 -f "$HOME/.ssh/lucoa_ed25519"
```

Supply only the `.pub` file to the deployment host. Keep the private key on your
desktop; do not put it in the container, `.env`, or the image.

On the deployment host, append the public key to the running container's
persistent `authorized_keys`. Choose the command for your deployment:

```sh
# Docker run:
docker exec -i lucoa sh -eu -c 'umask 077; mkdir -p "$HOME/.ssh"; cat >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"' < lucoa_ed25519.pub

# Docker Compose:
docker compose exec -T lucoa sh -eu -c 'umask 077; mkdir -p "$HOME/.ssh"; cat >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"' < lucoa_ed25519.pub

# Podman run or the supplied Quadlet:
podman exec -i lucoa sh -eu -c 'umask 077; mkdir -p "$HOME/.ssh"; cat >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"' < lucoa_ed25519.pub
```

Replace `lucoa_ed25519.pub` with the host path to your public key. New keys are
accepted without a service restart. To revoke a key, remove its line from
`/home/node/.ssh/authorized_keys`; existing authenticated connections must be
closed separately. Keep `.ssh` mode `0700` and `authorized_keys` mode `0600`,
owned by UID 1000.

### Alternative: public-key text in an environment variable

Set **`LUCOA_SSH_AUTHORIZED_KEYS`** to the complete public-key line. For a single
key, add this to your deployment environment file (`.env` for direct run/Compose,
`~/.config/lucoa/lucoa.env` for the supplied Quadlet):

```dotenv
LUCOA_SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAAC3...replace-with-your-complete-public-key... desktop
```

Use the contents of your `.pub` file, not the placeholder. A public key is not a
secret, but this environment file also contains the private Ovis token, so retain
mode `0600`. Never put a private key in any environment variable.

- **Docker / Podman run:** the existing `--env-file .env` reads this variable.
- **Compose:** `compose.yaml` explicitly forwards it from `.env`.
- **Quadlet:** its `EnvironmentFile=` reads it, or add under `[Container]`:

  ```ini
  Environment="LUCOA_SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAAC3...complete-public-key... desktop"
  ```

For direct runs, you can instead read the public key into the host environment
and add `-e LUCOA_SSH_AUTHORIZED_KEYS` **before the image name** in `docker run`
or `podman run`:

```sh
export LUCOA_SSH_AUTHORIZED_KEYS="$(cat ./lucoa_ed25519.pub)"
# Run your chosen command with: -e LUCOA_SSH_AUTHORIZED_KEYS
# The Compose example also reads this exported variable.
```

Multiple keys are supported as newline-separated text in that exported variable;
use a mounted file for multiple keys when using portable engine environment
files (do not use literal `\n` escapes or split a key across lines).

### Alternative: mount a public-key file

Create a host file named `authorized_keys` containing one complete public key per
line. Mount it at a **separate source path** and set
`LUCOA_SSH_AUTHORIZED_KEYS_FILE` to that path. The file must be readable by UID
1000 or its rootless host mapping. Since it contains only public keys, mode
`0644` is acceptable for the source file; the persistent destination uses `0600`.
SELinux hosts may need a dedicated `:Z` label on the bind mount.

For **Docker run or Podman run**, add these arguments before the image name in
the corresponding run example (replace the host path with an absolute path):

```text
--mount type=bind,src=/absolute/path/authorized_keys,dst=/run/lucoa-authorized-keys,readonly
-e LUCOA_SSH_AUTHORIZED_KEYS_FILE=/run/lucoa-authorized-keys
```

For **Compose**, save a local `compose.ssh.yaml` override:

```yaml
services:
  lucoa:
    environment:
      LUCOA_SSH_AUTHORIZED_KEYS_FILE: /run/lucoa-authorized-keys
    volumes:
      - ./authorized_keys:/run/lucoa-authorized-keys:ro
```

Use both files for subsequent Compose operations:

```sh
docker compose -f compose.yaml -f compose.ssh.yaml up -d
```

For **Quadlet**, add under `[Container]` (place the source in the host user's
`~/.config/lucoa/authorized_keys`):

```ini
Volume=%h/.config/lucoa/authorized_keys:/run/lucoa-authorized-keys:ro
Environment=LUCOA_SSH_AUTHORIZED_KEYS_FILE=/run/lucoa-authorized-keys
```

### Key provisioning behavior

| Input | Startup behavior |
| --- | --- |
| No key variable | Preserve existing `~/.ssh/authorized_keys`; create an empty file if missing |
| `LUCOA_SSH_AUTHORIZED_KEYS` | Replace `authorized_keys` with the supplied public-key text |
| `LUCOA_SSH_AUTHORIZED_KEYS_FILE` | Replace `authorized_keys` with the mounted file contents |
| Both nonempty inputs | Refuse startup; choose one method |

The two startup inputs replace the file rather than append, so they can remove
previously authorized keys. Empty variables count as unset; they do **not** clear
existing keys. Changes to startup inputs apply on the next startup: recreate a
direct-run/Compose container when changing its environment, or reload/restart
Quadlet. Changes to a mounted source require a restart to be copied. Removing a
variable does not revoke previously copied keys—edit the persisted file or
supply a replacement key set. Already authenticated connections must be closed
separately.

When managing keys by `exec`, do not also set a startup input unless you intend
to overwrite those edits on restart. Never mount your private key or overwrite
the persistent server host key.

### 2. Verify the host identity and connect

The host key is generated on first startup and persisted at
`/home/node/.ssh/dropbear_ed25519_host_key`. Do not delete it during upgrades.
Display its public fingerprint through the trusted container engine:

```sh
# Use docker exec / docker compose exec instead for Docker deployments.
podman exec lucoa dropbearkey -y -f /home/node/.ssh/dropbear_ed25519_host_key
```

On your desktop, add to `~/.ssh/config`:

```sshconfig
Host lucoa
    HostName 10.0.0.50
    Port 2222
    User node
    IdentityFile ~/.ssh/lucoa_ed25519
    IdentitiesOnly yes
```

Use your deployment host's address if different. Then connect:

```sh
ssh lucoa
ssh lucoa 'id -u; hc --version; claude --version; pi --version'
```

Compare the first-connection fingerprint with the one obtained through the
engine before accepting it. SSH sessions start in `/workspace`, with tools on
PATH even for non-interactive commands. They share the default herdr-core
configuration, state, and runtime socket paths with Ovis. The Ovis token and
other service environment secrets are **not** forwarded into SSH sessions;
configure agent credentials in the persistent home or through another deliberate
per-session mechanism. These are still the same trusted user: SSH users can
access the home and other files available to Ovis.

### 3. Connect Herdr Desktop

In Herdr Desktop, open **Settings → Machines → Add machine** and choose the
`lucoa` SSH host. Verify SSH works first. Load a passphrase-protected key into
your desktop's SSH agent if Herdr cannot prompt for it:

```sh
ssh-add "$HOME/.ssh/lucoa_ed25519"
```

The SSH and `hc connect` transport is tested; graphical Herdr Desktop onboarding
and compatibility with your desktop/core versions still need validation.
Do not accept an unexpected core upgrade without reviewing the image's pins.

### Disable SSH

Set `LUCOA_SSH_ENABLED=0` in the direct-run/Compose environment file, or add
`Environment=LUCOA_SSH_ENABLED=0` to Quadlet, then recreate/restart as appropriate.
Remove the published SSH port too if it is not needed. Command overrides such as
`/bin/bash` do not start either server.

Ovis and SSH are supervised together: an unexpected exit of either stops the
container for engine/systemd recovery. Normal shutdown signals both services.

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

The base is Debian (glibc), so standard `manylinux` wheels apply. Native
extensions without wheels need extra build dependencies; compilers, Python
development headers, and pip are not bundled.
Recreate virtual environments after an incompatible system Python update, and
do not reuse environments created on incompatible hosts.

## Persistent storage

| Container path | Contents | Storage |
| --- | --- | --- |
| `/home/node` | Credentials, sessions, configuration, caches | Home volume |
| `/home/node/.ssh` | SSH authorized public keys and persistent server host key | Home volume |
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

### Published ports and access control

New examples bind TCP **7317** (Ovis) and **2222** (key-only SSH) to `0.0.0.0`.
This exposes them on every host IPv4 interface allowed by the host/network.
It does not configure an IPv6 publication or a client allowlist.

**Decide your access policy before starting:**

1. Configure host/network ingress rules for both ports. On this deployment LAN,
   the intended browser clients are `10.0.0.0/24` and Traefik as needed; choose
   explicitly which clients may reach SSH.
2. Verify the rules cover the engine's published-port forwarding path. Generic
   input-chain or UFW rules may not filter Docker-forwarded traffic.
3. Test rejection from disallowed networks and check for unintended IPv6 or
   other-interface exposure. Avoid accidental WAN exposure.
4. If desired, restrict the bind address in `-p`, Compose's port mappings, or
   Quadlet's `PublishPort=` entries. For local-only use, choose `127.0.0.1`.

Binding an IP is **not** a source allowlist. Quadlet lets you choose published
interfaces; host/network ingress rules restrict source clients. This project
does not install firewall rules on the host or inside the container.
Ovis authentication remains required, even behind a proxy.

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
| Docker run | `docker pull ghcr.io/lutvzn/lucoa:latest`; `docker stop lucoa && docker rm lucoa`; repeat the run command |
| Docker Compose | `docker compose pull`, then `docker compose up -d` (retains the binding configured in `.env`) |
| Podman run | `podman pull ghcr.io/lutvzn/lucoa:latest`; `podman stop lucoa && podman rm lucoa`; repeat the run command |
| Quadlet | Pull the configured image as the service's host user; `systemctl --user restart lucoa.service` |

If you pinned a tag/digest, update the image reference deliberately. Use the same
Compose override files during updates if you configured a public-key file mount.

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
docker run --rm -it ghcr.io/lutvzn/lucoa:latest /bin/bash
podman run --rm -it ghcr.io/lutvzn/lucoa:latest /bin/bash
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

### Build locally instead of pulling

```sh
docker build -t lucoa:local .
# Rootless Podman: retain the image health check with Docker image format.
podman build --format docker -t localhost/lucoa:local .
```

Use that local image name instead of GHCR in direct-run commands. For Compose,
set `LUCOA_IMAGE=lucoa:local` in `.env` after building and run
`docker compose up -d --pull never`. For Quadlet, set
`Image=localhost/lucoa:local` and `Pull=never`, then reload/restart the service.

Local builds need access to the container registry, Debian repositories, npm,
GitHub, and `releases.herdr.dev`, but never provider credentials.

### Included versions

| Component | Pin |
| --- | --- |
| Base | `node:26-trixie-slim`, digest pinned in `Dockerfile` |
| Node / Debian at that digest | 26.13.0 / 13 (trixie) |
| Ovis | 0.4.22, revision `a4ff0c942716602c43362f05c8511984e2bcae44` |
| herdr-core (`hc`) | 0.1.17, protocol generation 1 |
| Bun (glibc, x64 baseline) | 1.4.2 |
| Claude Code (glibc native package) | 2.1.317 |
| pi | `@earendil-works/pi-coding-agent` 1.5.0 |
| Python 3 | Debian package; version follows its repository |
| Dropbear SSH | Debian `dropbear-bin` package; version follows its repository |
| uv / uvx (glibc) | 0.13.7 |

Upstream archives are SHA-256 checked against [`build/versions.env`](build/versions.env).
Agent dependencies use [`build/agents/package-lock.json`](build/agents/package-lock.json);
Ovis uses its upstream Bun lockfile and patches. Debian repositories are not
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

Publishing does **not** deploy or restart containers. Deployment examples use
the published registry image; the workflow must run successfully before new
source features are available there. The manual workflow must exist on the
default branch to show **Run workflow**. Since `latest` can be published from
any selected branch, choose carefully.

## Validation

Run smoke tests against a **disposable deployment**, never the live instance:

```sh
sh tests/smoke.sh lucoa:local

# Rootless Podman:
CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local

# SSH integration (requires host ssh and ssh-keygen):
CONTAINER_ENGINE=podman sh tests/ssh.sh localhost/lucoa:local
# Docker: sh tests/ssh.sh lucoa:local

# Optional bounded readiness soak (seconds, maximum 86400):
LUCOA_SOAK_SECONDS=60 CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
```

The main smoke suite creates disposable volumes and an ephemeral token, publishes
no ports, and checks non-root tools, authentication, core-backed workspaces,
WebSocket I/O/reconnect, file persistence, and shutdown. The SSH suite additionally
publishes an ephemeral **loopback-only test port**, generates disposable keys,
and checks key login, denied authentication, PTY access, `hc connect` RPC,
disconnect continuity, host-key persistence, and service failure propagation.
Neither suite modifies Traefik or the firewall.

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
