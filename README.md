# lucoa

Run **Claude Code** and **pi** in your browser with [Ovis](https://ovis.sh)
and **herdr-core**. lucoa packages them in an always-on, non-root container,
with persistent storage for your projects, settings, and agent credentials.

```text
Browser → Ovis → herdr-core → Claude Code / pi
```

- **Base:** Fedora 45 (glibc, digest pinned) with Node 26 managed by fnm.
- **Runtime user:** `lutvzn`, UID/GID `5997:5997`; no sudo or privileged mode.
- **Default workload:** Ovis in the foreground with `OVIS_RUNTIME=herdr-core`.
- **Also included:** Python 3, uv, uvx, and key-only SSH via Dropbear.
- **Access:** authenticated browser UI; use the existing Traefik proxy for HTTPS.

## Contents

- [Setup](#setup)
- [Choose a deployment method](#choose-a-deployment-method)
- [Open the browser UI](#open-the-browser-ui)
- [SSH and Herdr Desktop](#ssh-and-herdr-desktop)
- [Persistent storage](#persistent-storage)
- [Networking and HTTPS](#networking-and-https)
- [Documentation](#documentation)

## Setup

### 1. Check requirements

Use Docker with Compose v2, or rootless Podman. Quadlet additionally requires
Linux, a user systemd manager, cgroup v2, and a compatible Podman version.

The deployment examples use **`ghcr.io/lutvzn/lucoa:latest`**. Pulls need access
to GHCR; private packages require `docker login ghcr.io` or `podman login ghcr.io`.
Use this repository for the supplied Compose/Quadlet files.

**Use an image published from this SSH-capable source.** Local code changes do
not publish a new GHCR image, and an older `latest` may lack these SSH options.
See [docs/build-and-ci.md](docs/build-and-ci.md#ci-and-publishing-github-and-forgejo). For reproducible deployments, replace
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
The mounted file must be readable by UID 5997 or its rootless host mapping;
startup does not repair permissions. The Compose example uses `OVIS_TOKEN`.

## Choose a deployment method

Choose **one** method. Every example below publishes on **all host IPv4
interfaces** and uses init, dropped capabilities, and `no-new-privileges`:

| Host binding | Container port | Purpose |
| --- | --- | --- |
| `0.0.0.0:7317` | `7317` | Ovis browser UI |
| `0.0.0.0:2222` | `2222` | Key-only SSH as `lutvzn` |

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
  -v lucoa-home:/home/lutvzn -v lucoa-workspace:/workspace \
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
  -v lucoa-home:/home/lutvzn -v lucoa-workspace:/workspace \
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
  `LUCOA_BIND_IP` in its environment file does not control Quadlet publishing.
- `Image=ghcr.io/lutvzn/lucoa:latest` selects the image. Change it to pin a release.
  `Pull=missing` pulls only if absent; pull explicitly before restarting to update.
  Private pulls need registry credentials usable by the service's host user.
- Named volumes are created if absent.
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

Optional key-only SSH on port 2222 (Dropbear) for Herdr Desktop, SFTP and scp. Authorize your desktop's
public key, then connect as `lutvzn`. Key provisioning, host-key checks and SFTP details are in
[docs/ssh.md](docs/ssh.md). Disable it with `LUCOA_SSH_ENABLED=0`.

## Persistent storage

| Container path | Contents | Storage |
| --- | --- | --- |
| `/home/lutvzn` | Credentials, sessions, configuration, caches | Home volume |
| `/home/lutvzn/.ssh` | SSH authorized public keys and persistent server host key | Home volume |
| `/home/lutvzn/.config/ovis` | Ovis devices, pairing, settings, keys | Home volume |
| `/home/lutvzn/.config/herdr-core` | Core configuration and templates | Home volume |
| `/home/lutvzn/.local/state/herdr-core` | Core records, logs, saved terminal state | Home volume |
| `/workspace` | Projects and working files | Workspace volume |
| `/tmp/lucoa-runtime` | Private hc runtime sockets | Ephemeral |
| `/opt/lucoa` | Installed tools and Ovis build | Image |

Home/config/state/runtime directories are private (`0700`). Installed tools stay
outside persistent mounts so an old home volume does not hide image upgrades.

Backups, restores, and moving existing volumes to a newer image are in
[docs/operations.md](docs/operations.md).

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

## Documentation

- [docs/ssh.md](docs/ssh.md): SSH, key provisioning, Herdr Desktop, SFTP
- [docs/agents-and-python.md](docs/agents-and-python.md): Claude Code, pi, Python with uv
- [docs/podman-remote.md](docs/podman-remote.md): building images from inside lucoa
- [docs/operations.md](docs/operations.md): upgrades, backups, maintenance, security boundary
- [docs/build-and-ci.md](docs/build-and-ci.md): local builds, pins, CI and publishing
- [docs/testing.md](docs/testing.md): validation suites
- [lucoa-host](../lucoa-host): host-side builder account and Quadlet CLI
