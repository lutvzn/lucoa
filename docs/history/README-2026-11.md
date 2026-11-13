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
- [CI and publishing (GitHub and Forgejo)](#ci-and-publishing-github-and-forgejo)
- [Validation](#validation)

## Setup

### 1. Check requirements

Use Docker with Compose v2, or rootless Podman. Quadlet additionally requires
Linux, a user systemd manager, cgroup v2, and a compatible Podman version.

The deployment examples use **`ghcr.io/lutvzn/lucoa:latest`**. Pulls need access
to GHCR; private packages require `docker login ghcr.io` or `podman login ghcr.io`.
Use this repository for the supplied Compose/Quadlet files.

**Use an image published from this SSH-capable source.** Local code changes do
not publish a new GHCR image, and an older `latest` may lack these SSH options.
See [CI and publishing](#ci-and-publishing-github-and-forgejo). For reproducible deployments, replace
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

Dropbear runs as **`lutvzn` (UID 5997)** on port **2222**, alongside Ovis. It requires
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
`/home/lutvzn/.ssh/authorized_keys`; existing authenticated connections must be
closed separately. Keep `.ssh` mode `0700` and `authorized_keys` mode `0600`,
owned by UID 5997.

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
5997 or its rootless host mapping. Since it contains only public keys, mode
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
`/home/lutvzn/.ssh/dropbear_ed25519_host_key`. Do not delete it during upgrades.
Display its public fingerprint through the trusted container engine:

```sh
# Use docker exec / docker compose exec instead for Docker deployments.
podman exec lucoa dropbearkey -y -f /home/lutvzn/.ssh/dropbear_ed25519_host_key
```

On your desktop, add to `~/.ssh/config`:

```sshconfig
Host lucoa
    HostName 10.0.0.50
    Port 2222
    User lutvzn
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

### Copy files with SFTP or scp

The SSH port also serves SFTP (Fedora's `sftp-server` from `openssh-server`, run by Dropbear as
`lutvzn`). Sessions start in `/workspace`; modern `scp` uses SFTP too:

```sh
sftp lucoa
scp ./notes.md lucoa:/workspace/
scp lucoa:/workspace/report.txt .
```

The same key-only rules apply. Files are written as UID 5997 with the
container's private umask (`0600` files, `0700` directories).

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

The base is Fedora (glibc), so standard `manylinux` wheels apply. Native
extensions without wheels need extra build dependencies; compilers, Python
development headers, and pip are not bundled.
Recreate virtual environments after an incompatible system Python update, and
do not reuse environments created on incompatible hosts.

### Build container images with podman-remote

The image includes the `podman-remote` client (also available as `podman`), so
agents can build and test images **on the host's Podman** without running a
container engine or root inside lucoa. Nothing happens until you mount a host
Podman API socket. Without one, `podman` commands fail with a connection error.

> **Security:** the socket gives everything in lucoa (agents, SSH users, browser
> terminals) full control of that host account's Podman. That includes stopping
> or inspecting its other containers, reading their environment (for example an
> `OVIS_TOKEN` passed with `-e`), and bind-mounting any host path the account can
> read. Use a **dedicated host account** whose Podman holds nothing else, prefer
> its **rootless** socket, and never mount a rootful `/run/podman/podman.sock`
> (that is equivalent to host root). With a socket mounted, prefer
> `OVIS_TOKEN_FILE` over `-e OVIS_TOKEN`. This is opt-in and not part of the
> default deployment examples.

The quick setup below shares the Podman of the account that runs lucoa. To use
a separate, locked-down account instead, follow
[Dedicated builder account](#dedicated-builder-account-recommended).

1. On the host, as the account that runs lucoa, enable its rootless API socket:

   ```sh
   systemctl --user enable --now podman.socket
   ls -l "$XDG_RUNTIME_DIR/podman/podman.sock"
   ```

2. Add these options to the `podman run` command. `keep-id` maps the host
   account, which owns the socket, to the container's `lutvzn` user (UID 5997).
   `label=disable` allows the socket connection on SELinux hosts:

   ```sh
     --userns=keep-id:uid=5997,gid=5997 \
     --security-opt label=disable \
     -v "$XDG_RUNTIME_DIR/podman/podman.sock:/run/podman/podman.sock" \
   ```

   For Quadlet, add to `[Container]`:

   ```ini
   UserNS=keep-id:uid=5997,gid=5997
   SecurityLabelDisable=true
   Volume=%t/podman/podman.sock:/run/podman/podman.sock
   ```

   `keep-id` changes how container UIDs map to the host, so start it with
   fresh volumes or check ownership of existing ones first. The entrypoint
   reports volumes that UID 5997 does not own.

3. Inside lucoa (browser terminal or SSH):

   ```sh
   podman info --format '{{.Host.Security.Rootless}}'   # expect: true
   podman build -t localhost/my-test .
   podman run --rm localhost/my-test
   ```

Builds and containers run on the host, so images, volumes, and bind-mount paths
refer to **host** storage and paths, not lucoa's filesystem. The build context
is uploaded from lucoa, so `podman build .` in `/workspace` works as expected.
`CONTAINER_HOST` defaults to `unix:///run/podman/podman.sock`; SSH shells use
that default. The client is Fedora's 6.1 series; keep the host on a compatible
Podman 5.x. `podman-remote` cannot talk to a Docker daemon.

Docker hosts are not supported for this feature. Running a nested engine inside
lucoa instead would need privileged mode or extra capabilities, which the
project avoids.

### Dedicated builder account (recommended)

[`host/setup-builder.sh`](host/setup-builder.sh) sets up the dedicated account
described above. Run it on the **host** as root (it is not part of the image).
Name the host account that runs lucoa with `--client`:

```sh
sudo sh host/setup-builder.sh --dry-run --client "$USER"   # review first
sudo sh host/setup-builder.sh --client "$USER"
```

What it configures:

| Item | Setting |
| --- | --- |
| Account `lucoa-builder` | UID/GID **6000** by default: the smallest number from 6000 up that is free as both. Set it with `--uid N`; an existing account is never renumbered. Login shell is `nologin`, password is locked, home is `0700`. The script refuses accounts with UID/GID 0, privileged groups (`wheel`, `sudo`, `docker`, …) or sudo rules |
| Subordinate IDs | A free 65536-ID range in `/etc/subuid` and `/etc/subgid`, used for rootless Podman |
| Resource limits | Root-owned drop-in for `user-<uid>.slice`: `MemoryMax=50%`, no swap, `TasksMax=4096`, `CPUWeight=50`, `IOWeight=50`. It covers the API service and every container it starts. Change with `--memory-max`, `--tasks-max`, `--cpu-weight`, `--io-weight`, `--cpu-quota` |
| Socket directory | `/run/lucoa-builder`, owned by root with mode `0700`, recreated at boot by `tmpfiles.d`. Its ACL lets the builder create the socket and lets only the `--client` UIDs traverse it |
| API socket | `/run/lucoa-builder/podman.sock`, owned by the builder with mode `0600`, plus an ACL granting the `--client` UIDs read/write. It activates a rootless `podman system service` in the builder's user manager (units in `/etc/systemd/user/lucoa-builder-podman.*`). Lingering is enabled, so it runs without a login |

At the end, the script checks that the socket is not world-accessible, that an
unrelated UID cannot reach the directory, and that each client account gets a
**rootless** API through the socket.

**Mount the directory, not the socket file**, so restarts of the socket do not
leave a stale mount. Do not add `:z`/`:Z`, because relabeling would fail and is
not needed with `label=disable`:

```sh
  --userns=keep-id:uid=5997,gid=5997 \
  --security-opt label=disable \
  -v /run/lucoa-builder:/run/podman \
```

Quadlet: `UserNS=keep-id:uid=5997,gid=5997`, `SecurityLabelDisable=true`,
`Volume=/run/lucoa-builder:/run/podman`.

**Without `keep-id`**, lucoa's `lutvzn` user maps to a subordinate host UID, not
to the client account. Pass that UID instead: for rootless Podman it is the
first `/etc/subuid` value of the account that runs lucoa, plus 999. Example:
`--client 525287` for `lutvzn:524288:65536`. You can pass `--client` more than
once. Rerun the script to change clients or limits.

**What stays possible:** anything inside lucoa that reaches the socket fully
controls `lucoa-builder`. It can build and run containers, publish ports on
the host (above `ip_unprivileged_port_start`), use the network, and bind-mount
any host path that `lucoa-builder` can read (world-readable files only). Keep
nothing else in that account. Image and volume storage in
`/home/lucoa-builder` has no size limit from the slice, so prune it from inside
lucoa with `podman system prune --all`.

**Remove:**

```sh
sudo sh host/setup-builder.sh --uninstall                 # keeps the account and its images
sudo sh host/setup-builder.sh --uninstall --delete-user   # also deletes its home and subuid ranges
```

`--delete-user` refuses accounts that the script did not create. Use `--user`
and `--socket-dir` to choose other names. An existing account is adopted only
with `--reuse-user`, which also hardens it.

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

### Upgrading from the `node` (UID 1000) image

The runtime account is now `lutvzn` (UID/GID 5997) and the `node` account is gone.
Volumes created by the older image are owned by UID 1000, so the new image cannot
write to them until ownership is moved. Stop the container, then re-own the volumes
before starting the new image:

```sh
podman run --rm --user 0 -v lucoa-home:/home/lutvzn -v lucoa-workspace:/workspace \
  --entrypoint sh localhost/lucoa:NEW -c \
  'chown -R 5997:5997 /home/lutvzn /workspace'
```

Rootless hosts can instead use `podman unshare chown -R 5997:5997` on the volume
mount points. Keep the old volumes until the new image passes a health check, and
run `--userns=keep-id:uid=5997,gid=5997` as shown in the host-socket section.
Ovis's adapter socket lives in its state directory, but sockets are not portable
persisted process state.

**Persistence saves files, not live processes.** Closing the browser leaves
agents running. Stopping or recreating the container ends its live processes;
volumes do not guarantee resuming in-flight work.

### Back up and restore volumes

The home volume holds provider credentials, the SSH host key, Ovis pairing
keys, and terminal history, so treat backups as secrets. Stop the service first
for a consistent copy (this ends live agent processes), then stream each volume
through `tar` in a disposable container. Nothing is written inside the image and
no host bind mount or root access is needed:

```sh
# Use docker instead of podman as appropriate; substitute your volume names.
podman stop lucoa
umask 077
podman run --rm --cap-drop=ALL --security-opt=no-new-privileges \
  -v lucoa-home:/home/lutvzn:ro ghcr.io/lutvzn/lucoa:latest \
  tar -C /home/lutvzn -cf - . > lucoa-home.tar
podman run --rm --cap-drop=ALL --security-opt=no-new-privileges \
  -v lucoa-workspace:/workspace:ro ghcr.io/lutvzn/lucoa:latest \
  tar -C /workspace -cf - . > lucoa-workspace.tar
podman start lucoa
```

Restore into a **new, empty** volume and point a deployment at it, rather than
extracting over a volume in use:

```sh
podman volume create lucoa-home-restored
podman run --rm -i --cap-drop=ALL --security-opt=no-new-privileges \
  -v lucoa-home-restored:/home/lutvzn ghcr.io/lutvzn/lucoa:latest \
  tar -C /home/lutvzn -xf - < lucoa-home.tar
```

The smoke suite exercises this round trip on disposable volumes.

### Use a host project directory

Replace the workspace volume with a bind mount in a local Compose override.
The runtime user must be able to write it:

- Rootful Docker usually needs ownership compatible with UID/GID 5997.
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
| Quadlet | `lucoa update` (see [Host management command](#host-management-command-quadlet)), or pull the configured image as the service's host user and `systemctl --user restart lucoa.service` |

If you pinned a tag/digest, update the image reference deliberately. Use the same
Compose override files during updates if you configured a public-key file mount.

Removing a container is not permission to delete its volumes. Back up home and
workspace volumes **while stopped**. Treat backups as secrets: they may include
credentials, terminal histories, and source code.

Update checked-in pins/lockfiles to change bundled tool versions. Ovis automatic
updates and Claude background updates are disabled; startup bypasses Ovis's
managed updater. Manual installation can still modify user-owned tools.
Recreating the container restores image-provided tools outside persistent mounts.

### Host management command (Quadlet)

`host/lucoa` is a small POSIX shell CLI for a rootless Quadlet deployment. Run
it on the host as the user that owns the Quadlet, never as root and never inside
lucoa. It reads `Image=` and `ContainerName=` from the first `lucoa.container`
under `~/.config/containers/systemd` (override with `LUCOA_QUADLET`).

```sh
sh host/lucoa install        # copies the script to ~/.local/bin/lucoa
lucoa status                 # unit, container, running vs pulled image, health, builder socket
lucoa start | stop | restart # systemctl --user; start/restart wait for the health check
lucoa logs [-f] [-n N]       # container output (podman logs); --unit for the systemd journal
lucoa health                 # the image's token-free readiness check, via podman exec
lucoa update [--check]       # pull Image=; restart only if it changed; auto-rollback if unhealthy
lucoa rollback               # back to the image that ran before the last update
lucoa edit                   # edit a copy, validate with quadlet -dryrun, install, daemon-reload
lucoa reload                 # validate + daemon-reload after editing the file yourself
lucoa shell [CMD...]         # login shell (or CMD) as the container's default user
```

- **Updates are per service.** `lucoa update` pulls only this Quadlet's image,
  unlike `podman auto-update`, which updates every `AutoUpdate=` container of
  the user. Before restarting, it tags the previous image as
  `localhost/<quadlet-name>:rollback`. If the new container is not healthy within
  `LUCOA_HEALTH_TIMEOUT` seconds (default 120), it retags the old image and
  restarts again. `AutoUpdate=registry` can later move the tag forward again.
- **Restarting ends live sessions.** `stop`, `restart`, `update` and an applied
  `edit` end agents and terminals running inside lucoa. Persistent files stay.
- **`edit` never installs an invalid file.** It keeps the previous version as
  `lucoa.container.bak` and asks before restarting. Without a terminal it does
  not restart.
- **Install a copy, not a symlink.** The script runs with the host user's full
  privileges, and the repository may be writable from inside lucoa (for
  example, through a `/Projects` mount). Review changes before rerunning
  `install`, and prefer running the installed copy over `host/lucoa`.
- The CLI prints only selected inspect fields. It never prints the environment
  file or the container's environment.

### Disposable maintenance shells

A command override runs instead of Ovis and does not require a token at the image
entrypoint level:

```sh
docker run --rm -it ghcr.io/lutvzn/lucoa:latest /bin/bash
podman run --rm -it ghcr.io/lutvzn/lucoa:latest /bin/bash
# Compose still requires its .env interpolation:
docker compose run --rm lucoa hc --version
```

For tasks with no rootless alternative, a command override may run as root
with `--user 0` (the entrypoint prints a warning). Prefer the default `lutvzn`
user. The Ovis server still refuses to start as root. The image has no `sudo`
or setuid helpers, so root is chosen when the container starts, never gained
from inside it. Root in a rootless-Podman container is your host account, not
host root. Avoid running as root against persistent volumes, because files it
creates there may not be writable by `lutvzn` afterwards.

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

Local builds need access to the container registry, Fedora repositories, nodejs.org, npm,
GitHub, and `releases.herdr.dev`, but never provider credentials.

`sh ci/build.sh IMAGE` does the same with Docker or Podman (it adds
`--format docker` for Podman) and refuses non-x86_64 hosts.

### Extra Fedora packages

Add packages at build time, for example a compiler toolchain for Python native
extensions:

```sh
podman build --format docker --build-arg EXTRA_DNF_PACKAGES="gcc make" \
  -t localhost/lucoa:full .
# Or: LUCOA_EXTRA_DNF_PACKAGES="gcc make" sh ci/build.sh localhost/lucoa:full
```

Only Fedora package-name characters are accepted. Extra packages must work
unprivileged: the build still strips every setuid/setgid bit, and the smoke
suite still requires that no privilege-escalation tool is present.

### Keep pins current

[`ci/bump-versions.mjs`](ci/bump-versions.mjs) checks every pin (Bun, uv,
herdr-core, Ovis, the npm agents, the base image digest, CI tools, and
workflow action SHAs) and can rewrite them with fresh checksums:

```sh
node ci/bump-versions.mjs                       # report only
node ci/bump-versions.mjs --write               # update all pins
node ci/bump-versions.mjs --write --only bun,agents
```

Releases younger than 14 days are skipped (`--min-age-days N`), pins are never
downgraded, and herdr-core releases with a protocol generation other than 1 are
refused. arm64 checksums are kept in step even though only amd64 is built.
Nothing is built by the script: rebuild and run both test suites before
committing new pins. Set `LUCOA_GITHUB_API_TOKEN` to avoid GitHub's anonymous
API rate limit.

### Included versions

| Component | Pin |
| --- | --- |
| Base | `fedora:45`, digest pinned in `Dockerfile` |
| fnm / Node | fnm 1.39.0; Node 26.13.0 under `FNM_DIR=/opt/lucoa/fnm`, tarball SHA-256 pinned in `build/versions.env` |
| Ovis | 0.4.22, revision `a4ff0c942716602c43362f05c8511984e2bcae44` |
| herdr-core (`hc`) | 0.1.17, protocol generation 1 |
| Bun (glibc, x64 baseline) | 1.4.2 |
| Claude Code (glibc native package) | 2.1.317 |
| pi | `@earendil-works/pi-coding-agent` 1.5.0 |
| Python 3 | Fedora package (3.15 series at this digest) |
| Dropbear SSH | Fedora `dropbear` package; version follows its repository |
| uv / uvx (glibc) | 0.13.7 |
| SFTP | Fedora `openssh-server` sftp-server (`/usr/libexec/openssh/sftp-server`); sshd binary and units removed |
| Extra CLI tools | Fedora `openssh-clients`, `jq`, `less`, `procps-ng` |
| podman-remote (`podman`) | Fedora `podman-remote` (6.1 series), client only |

### Node and fnm

Node is managed by [fnm](https://github.com/Schniz/fnm), not installed system-wide.
`FNM_DIR` is `/opt/lucoa/fnm`, and its `default` alias (Node 26.13.0) is on `PATH`
for every shell and for Claude Code and pi. fnm 1.39 does not verify Node archives,
so the image checks the pinned tarball itself before placing it in fnm's layout.

Your dotfiles' fnm bootstrap works unchanged: it finds `/opt/lucoa/bin/fnm` and the
existing Node 26 installation. Versions installed from inside a running container
go under `/opt/lucoa` and are lost when the container is recreated; mount a volume
at `FNM_DIR` if you need them to persist. fnm has no arm64 Linux build pinned here.

Upstream archives are SHA-256 checked against [`build/versions.env`](build/versions.env).
Agent dependencies use [`build/agents/package-lock.json`](build/agents/package-lock.json);
Ovis uses its upstream Bun lockfile and patches. Fedora repositories are not
snapshotted, so OS builds are not bit-for-bit reproducible.

Bun builds the UI during image construction. Startup runs the production server,
not Vite or a runtime frontend build.

## CI and publishing (GitHub and Forgejo)

Both platforms run the same scripts in [`ci/`](ci); the workflow files are thin
wrappers. Only **linux/amd64** is built, and the scripts refuse other runners.

| Script | Purpose |
| --- | --- |
| `ci/install-tools.sh` | Checksum-pinned ShellCheck, hadolint, Trivy, cosign ([`ci/tools.env`](ci/tools.env)) into `.ci/bin` |
| `ci/lint.sh` | Shell/JS/Python syntax, ShellCheck, hadolint ([`.hadolint.yaml`](.hadolint.yaml)) |
| `ci/build.sh IMAGE` | Docker or Podman build with OCI labels |
| `ci/test.sh IMAGE` | Disposable suites: smoke, SSH/SFTP, and podman-remote on Podman runners |
| `ci/scan.sh IMAGE` | Trivy scan and CycloneDX SBOM in `.ci/out/`; fails on fixable CRITICAL issues |
| `ci/publish.sh IMAGE` | Tag, push, and optionally sign/attest |

The engine is `CONTAINER_ENGINE` if set, otherwise Docker, then Podman. Scan
policy: `LUCOA_SCAN_FAIL_SEVERITY` (default `CRITICAL`, or `none`) and
`LUCOA_SCAN_REPORT_SEVERITY` (default `HIGH,CRITICAL`).

| Workflow | GitHub (`.github/workflows`) | Forgejo (`.forgejo/workflows`) |
| --- | --- | --- |
| Container: lint, build, test, scan | push, pull request, manual | push, manual (no pull requests) |
| Publish | `v*` tags, manual | `v*` tags, manual |
| Weekly freshness: pin report plus no-cache rebuild/test/scan | Mondays 05:17 UTC, manual | Same |

Freshness runs only *report* newer pins. Apply them with
`node ci/bump-versions.mjs --write`, then commit through normal CI.

### Image tags

| Tag | When published |
| --- | --- |
| `sha-<full-commit-sha>` | Every successful publish run |
| `X.Y.Z` and `X.Y` | Pushing tag `vX.Y.Z` (pre-releases like `v1.0.0-rc.1` get only `1.0.0-rc.1`) |
| `latest` | Stable `vX.Y.Z` tags, or a manual run with **Also tag as latest** |

Publishing runs lint, build, both test suites, and the scan first. It does **not**
deploy or restart containers. A manual workflow must exist on the default branch
to show **Run workflow**. Since `latest` can be published from any selected
branch, choose carefully.

### GitHub (GHCR)

Open **Actions → Publish container to GHCR → Run workflow**, or push a `v*` tag.
Images go to `ghcr.io/<owner>/<repo>` using the automatic `GITHUB_TOKEN` with
`packages: write`; repository or organization policy must allow it. New packages
may start private, and private pulls need registry authentication. SBOMs and
scan reports are uploaded as workflow artifacts.

### Forgejo

Forgejo uses `.forgejo/workflows` and ignores `.github/workflows` while it exists.

1. **Register an x86_64 host runner** with the label `lucoa-host:host`, so jobs
   run directly on a machine with a real container engine (Docker, or rootless
   Podman as the runner user). The host needs `git`, `curl`, `node` (for the
   checkout action and bump script), `python3`, and OpenSSH clients (`ssh`,
   `ssh-keygen`, `sftp`). Set `CONTAINER_ENGINE=podman` in the runner's
   environment to force Podman.
2. **Security:** host runners have no isolation, so these workflows do not
   trigger on pull requests. Use a dedicated runner account, never an account
   running production services, and keep its engine free of production
   containers.
3. **Registry secrets** (repository or organization): `REGISTRY_TOKEN`, an
   access token with package write scope (required; the automatic workflow token
   is not used for pushes), and optionally `REGISTRY_USER` (token owner, which
   defaults to the triggering user). Images go to `<forgejo-host>/<owner>/<repo>`.
   The Forgejo instance must serve its registry at the host root.
4. Optional `LUCOA_GITHUB_API_TOKEN` secret: a *GitHub* token for the weekly pin
   report's API rate limit. The Forgejo token is never sent to GitHub.

Actions are pinned to commit SHAs from `https://data.forgejo.org`, Forgejo's
mirror, which carries the same commit as GitHub. The bump script refuses to
update a pin if the mirror and GitHub disagree.

### Signing (optional, both platforms)

With a `COSIGN_PRIVATE_KEY` secret (and `COSIGN_PASSWORD` if the key is
encrypted), publish signs the pushed digest and attaches the CycloneDX SBOM as a
signed attestation. Without the secret, publishing still works and reports that
the image is unsigned.

```sh
cosign generate-key-pair        # store cosign.key + password as secrets; keep cosign.pub
cosign verify --key cosign.pub ghcr.io/<owner>/<repo>:latest
cosign verify-attestation --key cosign.pub --type cyclonedx ghcr.io/<owner>/<repo>:latest
```

Cosign's default signing configuration records signatures in Sigstore's
**public** Rekor transparency log (image digest and signature, not image
contents). For private registries where that is unwanted, pass a custom
configuration through `COSIGN_SIGN_ARGS` (for example
`--signing-config FILE`).

## Validation

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
