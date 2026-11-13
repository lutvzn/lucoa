# SSH and Herdr Desktop

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
