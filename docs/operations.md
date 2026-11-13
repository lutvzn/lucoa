# Operations

## Upgrading from the `node` (UID 1000) image

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

## Back up and restore volumes

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

## Use a host project directory

Replace the workspace volume with a bind mount in a local Compose override.
The runtime user must be able to write it:

- Rootful Docker usually needs ownership compatible with UID/GID 5997.
- Rootless Podman uses user-namespace mappings; arrange permissions through the
  host mapping or a deliberate `--userns` strategy.
- SELinux hosts may need a dedicated `:Z` mount label.

Do not recursively change host ownership without reviewing the affected files.
The container never elevates privileges or fixes ownership at startup.

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
| Quadlet | `lucoa update` (see the [lucoa-host](../../lucoa-host) repository), or pull the configured image as the service's host user and `systemctl --user restart lucoa.service` |

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
