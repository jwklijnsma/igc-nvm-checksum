"""igc-patch.py: the NVM checksum bypass and the xsk API compat fix."""
import shutil
import subprocess
import sys

import pytest

from conftest import VENDOR, VENDORED

NEW_XSK_HDR = ("static inline void xsk_tx_metadata_request(const struct xsk_buff_pool *pool,\n"
               "\tstruct xsk_tx_metadata *meta, const struct xsk_tx_metadata_ops *ops, void *priv);\n")
OLD_XSK_HDR = ("static inline void xsk_tx_metadata_request(const struct xsk_tx_metadata *meta,\n"
               "\tconst struct xsk_tx_metadata_ops *ops, void *priv);\n")


def run(patcher, main_c, hdr):
    return subprocess.run([sys.executable, str(patcher), str(main_c), str(hdr)],
                          capture_output=True, text=True)


def test_vendor_sources_are_complete():
    assert len(VENDORED) >= 5
    for tag in VENDORED:
        d = VENDOR / tag
        for f in ("igc_main.c", "igc.h", "Makefile"):
            assert (d / f).is_file(), f"{tag}/{f} missing"


@pytest.mark.parametrize("tag", VENDORED)
def test_bypass_applies_to_every_vendored_kernel(tag, patcher, tmp_path):
    main_c = tmp_path / "igc_main.c"
    shutil.copy(VENDOR / tag / "igc_main.c", main_c)
    before = main_c.read_text()
    r = run(patcher, main_c, tmp_path / "missing.h")
    assert r.returncode == 0, r.stdout + r.stderr
    after = main_c.read_text()
    assert "NVM checksum bypass applied" in r.stdout
    assert "err = -EIO;\n\t\t\tgoto err_eeprom;" not in after.split("igc_get_flash_presence_i225(hw)")[1][:400]
    assert 'dev_warn(&pdev->dev, "The NVM Checksum Is Not Valid (ignoring, patched driver)\\n");' in after
    # nothing else changed: exactly one hunk, and the probe still validates (and warns)
    assert before.count("hw->nvm.ops.validate(hw)") == after.count("hw->nvm.ops.validate(hw)")
    assert len(after) < len(before) and len(before) - len(after) < 200


@pytest.mark.parametrize("tag", VENDORED)
def test_patch_is_idempotent(tag, patcher, tmp_path):
    main_c = tmp_path / "igc_main.c"
    shutil.copy(VENDOR / tag / "igc_main.c", main_c)
    run(patcher, main_c, tmp_path / "x.h")
    once = main_c.read_text()
    r = run(patcher, main_c, tmp_path / "x.h")
    assert r.returncode == 0 and "already present" in r.stdout
    assert main_c.read_text() == once


def test_bypass_tolerates_whitespace_and_label_changes(patcher, tmp_path):
    main_c = tmp_path / "igc_main.c"
    main_c.write_text(
        "static int probe(void) {\n"
        "    if ( hw->nvm.ops.validate( hw ) < 0 )\n    {\n"
        '        dev_err( &pdev->dev,\n                 "The NVM Checksum Is Not Valid\\n" );\n'
        "        err = -EIO ;\n        goto err_somewhere_else;\n    }\n}\n")
    assert run(patcher, main_c, tmp_path / "x.h").returncode == 0
    out = main_c.read_text()
    assert "goto err_somewhere_else" not in out
    assert out.startswith("static int probe(void) {\n    if (hw->nvm.ops.validate(hw) < 0)\n    \tdev_warn(")


def test_unknown_upstream_code_fails_loudly(patcher, tmp_path):
    main_c = tmp_path / "igc_main.c"
    main_c.write_text("int nothing_to_patch;\n")
    r = run(patcher, main_c, tmp_path / "x.h")
    assert r.returncode != 0 and "NVM checksum block not found" in r.stderr
    assert main_c.read_text() == "int nothing_to_patch;\n"     # left untouched


@pytest.mark.parametrize("tag", [t for t in VENDORED if t.startswith(("v6.14", "v6.17", "v7.0"))])
def test_xsk_compat_rewrites_the_old_call_for_backported_headers(tag, patcher, tmp_path):
    main_c, hdr = tmp_path / "igc_main.c", tmp_path / "xdp_sock_drv.h"
    shutil.copy(VENDOR / tag / "igc_main.c", main_c)
    hdr.write_text(NEW_XSK_HDR)
    r = run(patcher, main_c, hdr)
    assert "pool-based API" in r.stdout
    assert "xsk_tx_metadata_request(pool, &meta, &igc_xsk_tx_metadata_ops, &meta_req);" in main_c.read_text()


@pytest.mark.parametrize("tag", VENDORED)
def test_xsk_compat_leaves_matching_sources_alone(tag, patcher, tmp_path):
    main_c, hdr = tmp_path / "igc_main.c", tmp_path / "xdp_sock_drv.h"
    shutil.copy(VENDOR / tag / "igc_main.c", main_c)
    hdr.write_text(OLD_XSK_HDR)
    run(patcher, main_c, hdr)
    assert "pool-based API" not in main_c.read_text()
    assert main_c.read_text().count("xsk_tx_metadata_request(pool, &meta") == \
        (VENDOR / tag / "igc_main.c").read_text().count("xsk_tx_metadata_request(pool, &meta")


def test_v7_3_already_uses_the_new_api(patcher, tmp_path):
    tag = next((t for t in VENDORED if t.startswith("v7.3")), None)
    if not tag:
        pytest.skip("no v7.3 vendor source")
    main_c, hdr = tmp_path / "igc_main.c", tmp_path / "xdp_sock_drv.h"
    shutil.copy(VENDOR / tag / "igc_main.c", main_c)
    hdr.write_text(NEW_XSK_HDR)
    r = run(patcher, main_c, hdr)
    assert "pool-based API" not in r.stdout       # nothing to adapt
