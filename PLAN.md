# lucoa plan and status

## Goal

Build **lucoa**: an always-on, browser-accessible agent server based on **`node:26-trixie-slim`** (Debian 13; formerly `node:26-alpine`). Run **Ovis** (https://ovis.sh) continuously with **`OVIS_RUNTIME=herdr-core`**, backed by bundled **herdr-core**, **Claude Code**, and **pi agent**, all under an unprivileged user.

The primary workflow is opening Ovis in a browser, starting agents, interacting through chat/live terminals, and reconnecting later without stopping the agents. An interactive container shell is a maintenance override, not the default workload.

This document tracks implementation plans and upstream findings. Source review is not proof of container compatibility; runtime checks remain pending unless explicitly marked complete. `AGENTS.md` defines the project requirements.

## Status (2026-11-13)

- Image builds on `fedora:45` with fnm-managed Node 26.13.0. Lint passes.
- Smoke, SSH, podman-remote and the bash HTTP/WebSocket test pass on the current image.
- Runtime `lutvzn` (5997); `node` account removed; host admin moved to `../lucoa-host`.
- Node is kept for Claude Code and pi only. Ovis runs on Bun.

## Open items

- Decide whether podman-remote and the builder socket stay in the image.
- Decide whether the optional Python/uv tooling and the SSH key input modes stay.
- Run the dotfiles bootstrap in a container; it still assumes Homebrew or sudo for some steps.
- `ci/bump-versions.mjs` still runs on CI and does not know about the fnm pins.
- Not verified: arm64, hosted CI, graphical browser UI, provider logins, Quadlet boot, long soak,
  LAN source filtering, Traefik HTTPS.

Full history: [docs/history/PLAN-2026-11.md](docs/history/PLAN-2026-11.md).
