"""Helpers: pull the helper scripts the installer writes (heredocs) out of
install-igc-nvmfix-dkms.sh, so the tests always exercise the shipped code."""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install-igc-nvmfix-dkms.sh"
VENDOR = ROOT / "vendor" / "igc"
VENDORED = sorted(p.name for p in VENDOR.iterdir() if (p / ".complete").exists())


def heredoc(target: str) -> str:
    """Body of `cat > "${SRCDIR}/<target>" <<'TAG'` (or another absolute target)."""
    text = INSTALLER.read_text()
    m = re.search(r'cat > "?[^"\n]*' + re.escape(target) + r'"? <<\'(\w+)\'\n(.*?)\n\1\n', text, re.S)
    assert m, f"heredoc for {target} not found in the installer"
    return m.group(2) + "\n"


def shell_function(name: str) -> str:
    """Source of a top-level bash function in the installer."""
    text = INSTALLER.read_text()
    m = re.search(rf"^{name}\(\) \{{.*?^\}}\n", text, re.S | re.M)
    assert m, f"function {name} not found"
    return m.group(0)


def bash(script: str, *args, cwd=None, env=None, check=False):
    return subprocess.run(["bash", "-c", script, "bash", *args], cwd=cwd, env=env,
                          capture_output=True, text=True, check=check)


@pytest.fixture
def patcher(tmp_path):
    p = tmp_path / "igc-patch.py"
    p.write_text(heredoc("igc-patch.py"))
    return p
