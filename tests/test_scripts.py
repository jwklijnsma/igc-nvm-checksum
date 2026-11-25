"""The bash pieces: tag selection, source lookup + Makefile rewrite, and the
build wrapper's stock-driver fallback. Fixed system paths in the extracted
scripts are pointed at a temp dir; git is stubbed to fail (offline)."""
import os
import shutil
import stat
import subprocess

import pytest

from conftest import INSTALLER, VENDOR, VENDORED, bash, heredoc, shell_function


def test_installer_syntax_and_help_free_parse():
    assert subprocess.run(["bash", "-n", str(INSTALLER)]).returncode == 0


@pytest.mark.parametrize("kver,tags", [
    ("7.3.5-1-pve", "v7.3.5 v7.3"),
    ("6.8.12-4-pve", "v6.8.12 v6.8"),
    ("6.8.0-45-generic", "v6.8"),       # .0 -> mainline tag only
    ("6.12-amd64", "v6.12"),
    ("6.1.0-26-cloud-amd64", "v6.1"),
])
def test_kernel_tags(kver, tags):
    r = bash(shell_function("kernel_tags") + 'kernel_tags "$1"', kver)
    assert r.stdout.strip() == tags


@pytest.fixture
def world(tmp_path):
    """A fake filesystem for igc-fetch-patch.sh: cache, vendor, headers, override."""
    w = {k: tmp_path / k for k in ("cache", "vendor", "mods", "etc", "build", "bin")}
    for d in w.values():
        d.mkdir()
    script = heredoc("igc-fetch-patch.sh")
    for old, new in (('CACHE="/var/cache/igc-nvmfix"', f'CACHE="{w["cache"]}"'),
                     ('VENDOR="/usr/share/igc-nvmfix/vendor/igc"', f'VENDOR="{w["vendor"]}"'),
                     ('OFFLINE_FLAG="/etc/igc-nvmfix/offline"', f'OFFLINE_FLAG="{w["etc"]}/offline"'),
                     ('HDR="/lib/modules/${KVER}/build"', f'HDR="{w["mods"]}/${{KVER}}/build"'),
                     ("/etc/igc-nvmfix/src/", f'{w["etc"]}/src/')):
        assert old in script, old
        script = script.replace(old, new)
    (w["build"] / "igc-fetch-patch.sh").write_text(script)
    (w["build"] / "igc-patch.py").write_text(heredoc("igc-patch.py"))
    git = w["bin"] / "git"
    git.write_text("#!/bin/sh\necho git \"$@\" >> \"$(dirname \"$0\")/git.log\"\nexit 1\n")
    git.chmod(git.stat().st_mode | stat.S_IEXEC)
    w["env"] = {**os.environ, "PATH": f'{w["bin"]}:{os.environ["PATH"]}'}
    return w


def vendor(w, tag, where="vendor"):
    shutil.copytree(VENDOR / tag, w[where] / tag)


def fetch_patch(w, kver):
    (w["mods"] / kver / "build" / "include" / "net").mkdir(parents=True, exist_ok=True)
    return subprocess.run(["bash", "./igc-fetch-patch.sh", kver], cwd=w["build"], env=w["env"],
                          capture_output=True, text=True)


def test_exact_vendored_source_is_used_and_patched(world):
    tag = VENDORED[-1]
    vendor(world, tag)
    r = fetch_patch(world, f"{tag[1:]}-1-pve")
    assert r.returncode == 0, r.stderr
    assert f"Using local source {world['vendor']}/{tag}" in r.stderr
    assert "ignoring, patched driver" in (world["build"] / "igc_main.c").read_text()
    mk = (world["build"] / "Makefile").read_text()
    assert "obj-m += igc.o" in mk and "CONFIG_IGC)" not in mk.split("igc-y")[0]
    assert not (world["bin"] / "git.log").exists()      # no network needed


def test_cache_wins_over_vendor(world):
    tag = VENDORED[0]
    vendor(world, tag)
    vendor(world, tag, "cache")
    r = fetch_patch(world, f"{tag[1:]}-2-pve")
    assert f"Using local source {world['cache']}/{tag}" in r.stderr


def test_local_override_wins(world):
    tag = VENDORED[0]
    kver = f"{tag[1:]}-9-pve"
    vendor(world, tag)
    shutil.copytree(VENDOR / VENDORED[1], world["etc"] / "src" / kver)
    r = fetch_patch(world, kver)
    assert f"Using local override source {world['etc']}/src/{kver}" in r.stderr


def test_online_tries_every_mirror_then_falls_back_to_the_same_series(world):
    # Only v7.3.5 is local; the kernel is 7.3.9 -> download attempts, then nearest v7.3.x
    tag = next(t for t in VENDORED if t.startswith("v7.3"))
    vendor(world, tag)
    r = fetch_patch(world, "7.3.9-1-pve")
    assert r.returncode == 0, r.stderr
    log = (world["bin"] / "git.log").read_text()
    assert log.count("clone") == 6            # 3 mirrors x (v7.3.9, v7.3)
    assert "--branch v7.3.9" in log and "--branch v7.3 " in log
    assert f"using nearest local source {world['vendor']}/{tag}" in r.stderr


def test_offline_flag_skips_downloads(world):
    tag = next(t for t in VENDORED if t.startswith("v6.8"))
    vendor(world, tag)
    (world["etc"] / "offline").touch()
    r = fetch_patch(world, "6.8.99-1-pve")
    assert r.returncode == 0
    assert not (world["bin"] / "git.log").exists()


def test_nearest_local_never_crosses_series(world):
    vendor(world, next(t for t in VENDORED if t.startswith("v6.14")))
    (world["etc"] / "offline").touch()
    r = fetch_patch(world, "6.1.100-1-pve")      # v6.14 must NOT be picked for 6.1
    assert r.returncode == 1 and "No igc source for 6.1.100-1-pve" in r.stderr


def test_nearest_local_picks_the_highest_patch_release(world, tmp_path):
    tag = next(t for t in VENDORED if t.startswith("v6.8"))
    for fake in ("v6.8.2", "v6.8.30"):
        shutil.copytree(VENDOR / tag, world["vendor"] / fake)
    (world["etc"] / "offline").touch()
    r = fetch_patch(world, "6.8.99-1-pve")
    assert f"nearest local source {world['vendor']}/v6.8.30" in r.stderr   # sort -V, not lexical


def test_missing_headers_fail(world):
    r = subprocess.run(["bash", "./igc-fetch-patch.sh", "6.8.12-1-pve"], cwd=world["build"],
                       env=world["env"], capture_output=True, text=True)
    assert r.returncode == 1 and "Headers for 6.8.12-1-pve missing" in r.stderr


def test_prepare_never_fails_and_flags_the_failure(tmp_path):
    (tmp_path / "igc-prepare.sh").write_text(heredoc("igc-prepare.sh"))
    (tmp_path / "igc-fetch-patch.sh").write_text("exit 3\n")
    r = subprocess.run(["bash", "./igc-prepare.sh", "6.8.12-1-pve"], cwd=tmp_path, capture_output=True, text=True)
    assert r.returncode == 0 and (tmp_path / ".igc-prepare-failed").exists()
    (tmp_path / "igc-fetch-patch.sh").write_text("exit 0\n")
    subprocess.run(["bash", "./igc-prepare.sh", "6.8.12-1-pve"], cwd=tmp_path, check=True)
    assert not (tmp_path / ".igc-prepare-failed").exists()


@pytest.mark.parametrize("suffix,pack", [
    ("", None), (".zst", ["zstd", "-q"]), (".xz", ["xz"]), (".gz", ["gzip"]),
])
def test_build_falls_back_to_the_stock_driver(tmp_path, suffix, pack):
    if pack and not shutil.which(pack[0]):
        pytest.skip(f"{pack[0]} not installed")
    mods = tmp_path / "lib-modules"
    stock_dir = mods / "6.8.12-1-pve/kernel/drivers/net/ethernet/intel/igc"
    stock_dir.mkdir(parents=True)
    (stock_dir / "igc.ko").write_bytes(b"\x7fELF stock igc")
    if pack:
        subprocess.run([*pack, str(stock_dir / "igc.ko")], check=True)
    build = tmp_path / "build"
    build.mkdir()
    (build / "igc-build.sh").write_text(heredoc("igc-build.sh").replace("/lib/modules/", f"{mods}/"))
    (build / ".igc-prepare-failed").touch()
    r = subprocess.run(["bash", "./igc-build.sh", "6.8.12-1-pve", "/nonexistent"], cwd=build,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "FALLBACK: the NVM checksum bypass is NOT active on 6.8.12-1-pve" in r.stdout
    assert (build / "igc.ko").read_bytes() == b"\x7fELF stock igc"


def test_build_without_a_stock_driver_fails(tmp_path):
    (tmp_path / "igc-build.sh").write_text(heredoc("igc-build.sh").replace("/lib/modules/", f"{tmp_path}/none/"))
    (tmp_path / ".igc-prepare-failed").touch()
    r = subprocess.run(["bash", "./igc-build.sh", "6.8.12-1-pve", "/x"], cwd=tmp_path, capture_output=True, text=True)
    assert r.returncode == 1 and "No stock igc module" in r.stdout


def test_dkms_conf_is_well_formed():
    text = INSTALLER.read_text()
    conf = text.split('cat > "${SRCDIR}/dkms.conf" <<EOF\n', 1)[1].split("\nEOF\n", 1)[0]
    keys = dict(line.split("=", 1) for line in conf.splitlines())
    assert keys["BUILT_MODULE_NAME[0]"] == '"igc"'
    assert keys["DEST_MODULE_LOCATION[0]"] == '"/updates/dkms"'
    assert keys["AUTOINSTALL"] == '"yes"'
    assert "igc-prepare.sh" in keys["PRE_BUILD"] and "igc-build.sh" in keys["MAKE[0]"]


def test_generated_scripts_parse():
    for name in ("igc-prepare.sh", "igc-build.sh", "igc-fetch-patch.sh"):
        r = subprocess.run(["bash", "-n"], input=heredoc(name), text=True, capture_output=True)
        assert r.returncode == 0, f"{name}: {r.stderr}"
    r = subprocess.run(["bash", "-n"], input=heredoc("/usr/sbin/igc-nvmfix-ensure"), text=True, capture_output=True)
    assert r.returncode == 0


def test_requires_root(tmp_path):
    if os.geteuid() == 0:
        pytest.skip("running as root")
    r = subprocess.run(["bash", str(INSTALLER), "--status"], capture_output=True, text=True)
    assert r.returncode == 1 and "Run this as root" in r.stderr


def test_unknown_option_is_refused():
    r = bash(f'EUID=0 true; sed "s/^\\[\\[ \\$EUID -eq 0 \\]\\] || die.*$/:/" "{INSTALLER}" > /tmp/igc-noroot.sh && bash /tmp/igc-noroot.sh --frobnicate')
    assert r.returncode == 1 and "Unknown option: --frobnicate" in r.stderr
