# Building images from inside lucoa

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
the dedicated builder account in the [lucoa-host](../../lucoa-host) repository.

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

The dedicated builder account and its socket are set up on the host with the
`setup-builder.sh` script in the sibling [lucoa-host](../../lucoa-host) repository.
