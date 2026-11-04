"""Offline, non-root Python/uv integration check; no pip or build backend needed."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

assert os.getuid() == 1000
assert importlib.util.find_spec("pip") is None
with tempfile.TemporaryDirectory(prefix="lucoa-python-", dir="/workspace") as directory:
    root = Path(directory)
    env = root / ".venv"
    subprocess.run(
        ["uv", "venv", "--offline", "--python", "/usr/bin/python3", str(env)],
        check=True,
    )
    wheel = root / "lucoa_smoke-1.0-py3-none-any.whl"
    files = {
        "lucoa_smoke.py": 'VALUE = "uv-installed"\n',
        "lucoa_smoke-1.0.dist-info/METADATA":
            "Metadata-Version: 2.1\nName: lucoa-smoke\nVersion: 1.0\n",
        "lucoa_smoke-1.0.dist-info/WHEEL":
            "Wheel-Version: 1.0\nGenerator: lucoa-smoke\n"
            "Root-Is-Purelib: true\nTag: py3-none-any\n",
    }
    files["lucoa_smoke-1.0.dist-info/RECORD"] = "".join(
        f"{name},,\n" for name in [*files, "lucoa_smoke-1.0.dist-info/RECORD"]
    )
    with zipfile.ZipFile(wheel, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    subprocess.run(
        ["uv", "pip", "install", "--offline", "--python", str(env / "bin/python"), str(wheel)],
        check=True,
    )
    subprocess.run(
        [str(env / "bin/python"), "-c",
         'import lucoa_smoke; assert lucoa_smoke.VALUE == "uv-installed"'],
        check=True,
    )
    subprocess.run(
        ["uv", "run", "--offline", "--no-project", "--python", str(env / "bin/python"),
         "python", "-c", "import lucoa_smoke"],
        check=True,
    )
print("PASS: non-root Python, uv venv/run, offline wheel installation without pip")
