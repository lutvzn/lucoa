# Agents and Python

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

Building images from inside lucoa, and the dedicated builder account, are documented in
[docs/podman-remote.md](podman-remote.md).
