# igc-nvm-checksum

DKMS workaround for Intel **i225 / i226** NICs (Linux `igc` driver) that refuse to come up with:

```
igc 0000:xx:00.0: The NVM Checksum Is Not Valid
igc: probe of 0000:xx:00.0 failed with error -5
```

The installer sets up a DKMS package (`igc-nvmfix`) that rebuilds a patched `igc` module **for every kernel you install**, so the fix survives kernel upgrades.

> ⚠️ **This disables a hardware sanity check.** It does not repair the NVM; it only lets the driver continue when the checksum is invalid. A BIOS/firmware update or a proper NVM reflash is the real fix. Use this only when those aren't available or didn't work.

## Quick start

```bash
git clone https://github.com/jwklijnsma/igc-nvm-checksum.git
cd igc-nvm-checksum
sudo ./install-igc-nvmfix-dkms.sh
```

| Command | What it does |
|---|---|
| `sudo ./install-igc-nvmfix-dkms.sh` | Install or reinstall, build for the running kernel and every other installed kernel with headers |
| `sudo ./install-igc-nvmfix-dkms.sh --status` | Show DKMS status, which `igc.ko` is in use, recent dmesg |
| `sudo ./install-igc-nvmfix-dkms.sh --uninstall` | Remove the package and go back to the stock driver |

## How it works

1. Installs `dkms`, build tools, headers for the running kernel, and a **headers metapackage** (`proxmox-default-headers` on Proxmox VE, `linux-headers-<flavour>` on Debian/Ubuntu) so headers for future kernels arrive automatically.
2. Writes a DKMS source tree to `/usr/src/igc-nvmfix-<version>/`.
3. On every DKMS build (now, and automatically from the kernel postinst hook on upgrades) the `PRE_BUILD` step:
   - fetches only `drivers/net/ethernet/intel/igc` for **that kernel's version** with a sparse git checkout, exact stable tag first (`v6.8.12`) and then mainline (`v6.8`), cached in `/var/cache/igc-nvmfix`;
   - turns the fatal NVM checksum check into a warning;
   - adapts the `xsk_tx_metadata_request()` call when the installed headers expose the pool-based AF_XDP API (vendor backports such as `-pve` kernels);
   - builds with the upstream igc `Makefile`, so the object list always matches the version.
4. Installs the module into `/lib/modules/<kver>/updates/dkms`, which takes priority over the in-tree driver. **The stock driver is never overwritten.**
5. Updates the initramfs and reloads `igc`.

### Kernel upgrades never break apt

A failing DKMS build makes the kernel package's postinst fail, which leaves dpkg half-configured. To prevent that:

- if fetching, patching or compiling fails for a **new** kernel, the build installs the **stock** igc driver for that kernel and logs `FALLBACK` in its `make.log`. The kernel upgrade completes normally, but the bypass is not active on that kernel. `--status` lists such kernels;
- `/usr/share/dkms/modules_to_force_install/igc-nvmfix` tells DKMS to skip its "module already installed" version check, so the stock fallback isn't refused;
- for the **running** kernel the installer still fails hard, so you notice right away.

After loading you'll see this instead of the probe failure:

```
igc 0000:xx:00.0: The NVM Checksum Is Not Valid (ignoring, patched driver)
```

## Supported systems

- Debian / Ubuntu / Proxmox VE (apt based)
- Kernels where `igc` is built as a module (`CONFIG_IGC=m`)
- Tested patch against upstream igc sources v6.1, v6.8.12 and v6.14

## Notes

- **Network on upgrade:** building for a new kernel needs internet access, unless the source for that version is already cached. If the build fails, that kernel uses the stock (unpatched) driver. Check with `dkms status`.
- **Exact vendor source / offline:** place the igc driver directory for a kernel in `/etc/igc-nvmfix/src/<uname -r>/` (with `igc_main.c`, `Makefile`, …) and it's used instead of downloading.
- **Secure Boot:** the module must be signed with an enrolled MOK. If `modprobe` reports `Key was rejected`, run `mokutil --import /var/lib/dkms/mok.pub` and reboot to enroll.
- **Coming from the old non-DKMS script:** that script overwrote the in-tree `igc.ko` for the running kernel. The DKMS copy takes priority anyway, but to restore the original, reinstall the kernel package or copy it back from `/root/igc-backup-*`.

## Recovering a broken apt (`igc-nvmfix/1.0 ... bad exit status`)

Older 1.0 versions of this module made kernel installs fail, with errors like:

```
Autoinstall on 7.0.14-28-pve failed for module(s) igc-nvmfix(10).
dpkg: error processing package proxmox-kernel-7.0.14-28-pve-signed (--configure)
```

Running the current installer fixes this: it removes every older `igc-nvmfix` version, runs `dpkg --configure -a` and then builds the current version for all installed kernels. To fix it by hand:

```bash
dkms remove igc-nvmfix/1.0 --all
rm -rf /usr/src/igc-nvmfix-1.0
dpkg --configure -a
```

## Troubleshooting

```bash
dkms status igc-nvmfix
cat /var/lib/dkms/igc-nvmfix/*/build/make.log
modinfo -n igc            # should point to .../updates/dkms/igc.ko*
dmesg | grep -i igc
```

If the build fails with `NVM checksum block not found`, upstream changed the code around the check and `igc-patch.py` (embedded in the installer) needs updating. Please open an issue with your `uname -r`.
