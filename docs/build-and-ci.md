# Building and CI

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
