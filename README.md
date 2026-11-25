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
| `sudo ./install-igc-nvmfix-dkms.sh --no-mac` | Install, but don't pin a MAC address (see below) |
| `sudo ./install-igc-nvmfix-dkms.sh --make-bundle [DIR]` | On a machine **with** internet: download everything for an offline install into `DIR` (default `./bundle`) |
| `sudo ./install-igc-nvmfix-dkms.sh --offline [DIR]` | Install from that bundle with **no network at all** |

## Offline use

When the igc port is a node's only NIC, a broken driver means no network to download anything. Prepare for that while the network still works.

**1. Make a bundle** on a node with internet, running the same Debian/Proxmox release. Ideally do it on the node itself:

```bash
sudo ./install-igc-nvmfix-dkms.sh --make-bundle                 # -> ./bundle
sudo ./install-igc-nvmfix-dkms.sh --make-bundle /mnt/usb/igc \
     --kernels "7.0.14-30-pve 7.3.5-1-pve" --with-kernel-images
```

The bundle contains:
- `debs/`: dkms, the build toolchain and all their dependencies, plus the headers for each kernel. With `--with-kernel-images` it also has the kernel image packages, which restore a deleted stock `igc.ko`;
- `src/`: the igc source for each kernel;
- a copy of the installer, this README and `vendor/`, so the bundle folder is self-contained. Copy it to a USB stick or to the node itself.

Defaults: every kernel in `/lib/modules`, plus the newest kernel apt offers for the installed Proxmox series. Expect a few hundred MB, or more with kernel images. `bundle/` and `*.deb` are git-ignored.

**2. Install offline:**

```bash
cd /path/to/bundle            # or the repo, if the bundle is in ./bundle
sudo ./install-igc-nvmfix-dkms.sh --offline [DIR]
```

This installs only the packages from the bundle that are missing or older (it never downgrades), and never touches the network. It also:
- creates `/etc/igc-nvmfix/offline`, so later DKMS builds don't try to download (delete it, or re-run without `--offline`, once you're back online);
- keeps the header and kernel `.deb` files in `/usr/share/igc-nvmfix/debs/`, so `igc-nvmfix-ensure` can install headers for those kernels later without network.

**Bundled sources:** `vendor/igc/` in this repo holds unmodified igc sources for **v6.8.12, v6.14.11, v6.17.13, v7.0.14 and v7.3.5** (~3 MB). They're installed to `/usr/share/igc-nvmfix/vendor`. A build uses the exact tag when available, otherwise the newest bundled source of the same series (e.g. v7.3.5 for 7.3.2). So any kernel whose **headers** are installed can be built without network. Headers are the one thing that must come from apt or a bundle.

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

### Every kernel, including opt-in kernels

Headers metapackages only follow the **default** kernel series. `proxmox-default-headers` won't pull headers for an opt-in kernel, for example 7.3 when 7.0 is the default, and DKMS silently skips kernels without headers. You then boot into the stock driver and get `probe ... failed with error -5`. To prevent that the installer adds:

- `/usr/sbin/igc-nvmfix-ensure`: installs missing headers (`proxmox-headers-<kver>` / `linux-headers-<kver>`) and builds the module for **every** installed kernel;
- an APT hook (`/etc/apt/apt.conf.d/99igc-nvmfix`) that runs it in the background 30 s after each apt/dpkg run, so a newly installed kernel gets headers and the module before you reboot;
- `igc-nvmfix-ensure.service`, which runs it at boot. If the running kernel only got the module then, it loads it and runs `ifreload -a`. This needs network through another NIC (or a cached source plus headers already installed).

### Kernel upgrades never break apt

A failing DKMS build makes the kernel package's postinst fail, which leaves dpkg half-configured. To prevent that:

- if fetching, patching or compiling fails for a **new** kernel, the build installs the **stock** igc driver for that kernel and logs `FALLBACK` in its `make.log`. The kernel upgrade completes normally, but the bypass is not active on that kernel. `--status` lists such kernels;
- `/usr/share/dkms/modules_to_force_install/igc-nvmfix` tells DKMS to skip its "module already installed" version check, so the stock fallback isn't refused;
- for the **running** kernel the installer still fails hard, so you notice right away.

After loading you'll see this instead of the probe failure:

```
igc 0000:xx:00.0: The NVM Checksum Is Not Valid (ignoring, patched driver)
```

## Placeholder MAC address

A corrupt NVM often has no valid MAC either. The driver then comes up with a placeholder such as:

```
igc 0000:02:00.0 eth0: MAC: 00:a0:c9:00:00:00
```

Every affected card gets **the same** MAC, which causes ARP, switch-table and DHCP conflicts between nodes. When the installer sees such a placeholder (`00:a0:c9:00:00:00`, all zeros or all `ff`), it writes `/etc/systemd/network/10-igc-nvmfix-<pci>.link`. That file pins a unique, locally administered MAC (`02:…`), derived from `/etc/machine-id` and the PCI address, so it stays the same across re-runs. The interface name stays the same. udev applies it at the module reload and on every boot.

- An existing `.link` file that already matches the port is never overwritten. The installer warns instead.
- Use `--no-mac` to skip this. Delete the `.link` file to undo it.
- After the change, update any DHCP reservation or static ARP/switch entries.

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

The same happens with other earlier attempts, e.g. `igc-patched/1.0`. Running the current installer fixes this: it removes every older `igc-nvmfix` version **and any other DKMS package that builds an `igc` module**, runs `dpkg --configure -a` and then builds the current version for all installed kernels. To fix it by hand:

```bash
dkms status                                  # find the failing igc module + version
dkms remove igc-patched/1.0 --all            # repeat for each old igc package
rm -rf /usr/src/igc-patched-1.0
dpkg --configure -a
```

## `reboot`: "Transport endpoint is not connected"

```
Failed to set wall message, ignoring: Transport endpoint is not connected
Call to Reboot failed: Transport endpoint is not connected
```

systemd (PID 1) lost its control socket, usually after a systemd upgrade inside an interrupted apt run. The installer checks for this after `dpkg --configure -a` and at the end, and re-executes systemd if needed. To fix it by hand:

```bash
kill -TERM 1        # same as 'systemctl daemon-reexec'
sleep 5
systemctl reboot
# still failing? clean reboot via the Ctrl+Alt+Del target:
kill -INT 1
```

## `modprobe: FATAL: Module igc not found`

Earlier scripts deleted or overwrote the kernel's own `igc.ko`. Once the old DKMS package is removed, no igc driver is left. The installer detects this for every installed kernel and reinstalls the kernel package that owns it, which restores the stock driver. To do it by hand:

```bash
apt install --reinstall "$(dpkg -S /boot/vmlinuz-$(uname -r) | cut -d: -f1)"
```

## Troubleshooting

```bash
dkms status igc-nvmfix
cat /var/lib/dkms/igc-nvmfix/*/build/make.log
modinfo -n igc            # should point to .../updates/dkms/igc.ko*
dmesg | grep -i igc
```

If the build fails with `NVM checksum block not found`, upstream changed the code around the check and `igc-patch.py` (embedded in the installer) needs updating. Please open an issue with your `uname -r`.

## Tests

```bash
pip install pytest && python -m pytest tests
```

The tests take the helper scripts the installer writes (`igc-patch.py`,
`igc-fetch-patch.sh`, `igc-prepare.sh`, `igc-build.sh`) straight out of
`install-igc-nvmfix-dkms.sh` and run them against the vendored sources in
`vendor/igc/`: the NVM bypass must apply to every vendored kernel, the xsk
compat fix only where needed, source lookup must prefer override → cache →
vendor → download → nearest same-series source, and a failed build must fall
back to the stock driver. Nothing is installed and no network is used.
