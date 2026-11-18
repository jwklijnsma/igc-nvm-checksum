#!/usr/bin/env bash
#
# install-igc-nvmfix-dkms.sh
#
# Installs a DKMS package ("igc-nvmfix") that rebuilds a patched Intel
# i225/i226 "igc" driver automatically for EVERY kernel you install, so the
# "The NVM Checksum Is Not Valid" (-5 / EIO) probe bypass survives upgrades.
#
# How it works:
#   * /usr/src/igc-nvmfix-<ver>/ holds a dkms.conf plus a PRE_BUILD script.
#   * When DKMS builds for a kernel (now, and automatically from the kernel
#     postinst hook on every upgrade), the PRE_BUILD script:
#       1. fetches the igc source matching THAT kernel version (sparse git
#          checkout of only drivers/net/ethernet/intel/igc, cached per tag),
#       2. applies the NVM checksum bypass,
#       3. applies the xsk_tx_metadata_request() compat fix if the kernel's
#          headers expose the pool-based API (vendor backports, e.g. -pve).
#   * The resulting igc.ko is installed under /lib/modules/<kver>/updates/dkms,
#     which takes precedence over the in-tree driver. The stock driver is never
#     overwritten or deleted.
#   * A headers metapackage is installed so headers for future kernels arrive
#     automatically (without them DKMS can't build on upgrade).
#
# WARNING: This disables a hardware sanity check. It does NOT fix the
# underlying NVM issue. A BIOS update / proper NVM reflash is the real fix.
#
# Usage:
#   sudo ./install-igc-nvmfix-dkms.sh             install / reinstall
#   sudo ./install-igc-nvmfix-dkms.sh --status    show DKMS + module status
#   sudo ./install-igc-nvmfix-dkms.sh --uninstall remove, back to stock driver
#
# Offline / exact vendor source (optional):
#   Put the igc driver directory for a given kernel in
#     /etc/igc-nvmfix/src/<uname -r>/   (must contain igc_main.c, Makefile, ...)
#   and it will be used instead of fetching from kernel.org/GitHub.
#
set -euo pipefail

PKG="igc-nvmfix"
PKGVER="2.5"
SRCDIR="/usr/src/${PKG}-${PKGVER}"
KVER="$(uname -r)"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (sudo $0)"

# ---------------------------------------------------------------------------
# --status / --uninstall
# ---------------------------------------------------------------------------
NO_MAC=0
[[ "${1:-}" == "--no-mac" ]] && { NO_MAC=1; shift; }

# systemctl/reboot fail with "Transport endpoint is not connected" when PID 1
# lost its control socket (typically after a systemd upgrade inside an apt run
# that was interrupted). Re-exec systemd to restore it.
ensure_systemd() {
    [[ -d /run/systemd/system ]] || return 0
    systemctl show -p Version >/dev/null 2>&1 && return 0
    warn "systemd (PID 1) is not reachable ('Transport endpoint is not connected')."
    warn "Re-executing systemd (same as 'systemctl daemon-reexec')..."
    kill -TERM 1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        systemctl show -p Version >/dev/null 2>&1 && { log "systemd reachable again."; return 0; }
    done
    warn "systemd still not reachable. For a clean reboot use: kill -INT 1"
}

case "${1:-}" in
    --status)
        dkms status "$PKG" 2>/dev/null || echo "dkms not installed"
        echo "Module used for ${KVER}: $(modinfo -n igc 2>/dev/null || echo 'none')"
        fb="$(grep -l "FALLBACK" /var/lib/dkms/${PKG}/*/*/*/log/make.log 2>/dev/null || true)"
        if [[ -n "$fb" ]]; then
            echo "Kernels where the patch FAILED and the stock driver was installed instead:"
            echo "$fb" | awk -F/ '{print "  - " $(NF-3)}'
        fi
        dmesg | grep -i igc | tail -10 || true
        exit 0
        ;;
    --uninstall)
        log "Removing all ${PKG} DKMS versions..."
        for v in $(dkms status "$PKG" 2>/dev/null | grep -oP "^${PKG}[/, ]+\K[0-9.]+" | sort -u); do
            dkms remove -m "$PKG" -v "$v" --all || true
            rm -rf "/usr/src/${PKG}-${v}"
        done
        rm -rf /var/cache/igc-nvmfix
        rm -f "/usr/share/dkms/modules_to_force_install/${PKG}"
        if grep -l "^# managed by igc-nvmfix" /etc/systemd/network/*.link >/dev/null 2>&1; then
            warn "Keeping the MAC address .link files created by igc-nvmfix:"
            grep -l "^# managed by igc-nvmfix" /etc/systemd/network/*.link | sed 's/^/    /'
            warn "Delete them yourself if you no longer want the fixed MAC."
        fi
        depmod -a "$KVER"
        command -v update-initramfs >/dev/null && update-initramfs -u -k "$KVER" || true
        log "Removed. Module now resolves to: $(modinfo -n igc 2>/dev/null || echo 'none')"
        warn "If you previously used the OLD script (which overwrote the in-tree igc.ko),"
        warn "restore the stock module with: apt install --reinstall <your kernel image package>"
        warn "or copy back the file from /root/igc-backup-*."
        warn "Reboot (or 'rmmod igc; modprobe igc') to load the stock driver."
        exit 0
        ;;
    "") ;;
    *) die "Unknown option: $1 (use --status, --uninstall or --no-mac)" ;;
esac

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
if ! dmesg | grep -qi "igc.*NVM Checksum Is Not Valid"; then
    warn "dmesg does not currently show the igc NVM checksum error."
    warn "Continuing anyway - double check this is the right fix."
fi

KCONFIG="/boot/config-${KVER}"
[[ -f "$KCONFIG" ]] || KCONFIG="/lib/modules/${KVER}/build/.config"
if [[ -f "$KCONFIG" ]]; then
    if grep -q '^CONFIG_IGC=y' "$KCONFIG"; then
        die "igc is built INTO this kernel (CONFIG_IGC=y); a module can't replace it."
    elif ! grep -q '^CONFIG_IGC=m' "$KCONFIG"; then
        warn "CONFIG_IGC not set as module in ${KCONFIG}; build may not be usable."
    fi
fi

# ---------------------------------------------------------------------------
# 1. Remove older igc-nvmfix versions FIRST and repair dpkg.
#    A broken older version makes kernel postinst (and thus apt) fail, which
#    would also make our own apt-get calls below fail.
# ---------------------------------------------------------------------------
if command -v dkms >/dev/null 2>&1; then
    for v in $(dkms status "$PKG" 2>/dev/null | grep -oP "^${PKG}[/, ]+\K[0-9.]+" | sort -u); do
        log "Removing existing ${PKG}/${v} from DKMS..."
        dkms remove -m "$PKG" -v "$v" --all >/dev/null 2>&1 || true
        rm -rf "/usr/src/${PKG}-${v}"
    done
fi

# Also remove OTHER DKMS packages that build an "igc" module (earlier
# attempts such as igc-patched/1.0). They conflict with this one, and if their
# build fails on a new kernel they break apt the same way.
for conf in /usr/src/*/dkms.conf; do
    [[ -f "$conf" ]] || continue
    grep -qE '^[[:space:]]*BUILT_MODULE_NAME(\[0\])?=["'\'']?igc["'\'']?[[:space:]]*$' "$conf" || continue
    name="$(grep -oP '^\s*PACKAGE_NAME=["'\'']?\K[^"'\''[:space:]]+' "$conf" | head -1)"
    ver="$(grep -oP '^\s*PACKAGE_VERSION=["'\'']?\K[^"'\''[:space:]]+' "$conf" | head -1)"
    [[ -n "$name" && -n "$ver" && "$name" != "$PKG" ]] || continue
    warn "Removing conflicting DKMS package ${name}/${ver} (also builds igc): $(dirname "$conf")"
    command -v dkms >/dev/null 2>&1 && dkms remove -m "$name" -v "$ver" --all >/dev/null 2>&1 || true
    rm -rf "/var/lib/dkms/${name}"
    rm -rf "$(dirname "$conf")"
done
# Leftover registrations whose /usr/src dir is already gone
if command -v dkms >/dev/null 2>&1; then
    for d in /var/lib/dkms/*/; do
        name="$(basename "$d")"; [[ "$name" == "$PKG" ]] && continue
        if find "$d" -name 'igc.ko*' -print -quit 2>/dev/null | grep -q .; then
            warn "Removing stale DKMS registration ${name} (built igc.ko)"
            for v in $(ls "$d" 2>/dev/null | grep -E '^[0-9]'); do
                dkms remove -m "$name" -v "$v" --all >/dev/null 2>&1 || true
            done
            rm -rf "$d"
        fi
    done
fi
log "Finishing any interrupted package configuration (dpkg --configure -a)..."
dpkg --configure -a || warn "dpkg --configure -a reported errors; continuing"
ensure_systemd

# ---------------------------------------------------------------------------
# 2. Dependencies (+ headers metapackage so FUTURE kernels get headers too)
# ---------------------------------------------------------------------------
log "Installing DKMS and build dependencies..."
apt-get update -qq

HDR_META=""
if command -v pveversion >/dev/null 2>&1 || [[ "$KVER" == *-pve ]]; then
    # PVE 8+: proxmox-default-headers, PVE 7: pve-headers
    if apt-cache show proxmox-default-headers >/dev/null 2>&1; then
        HDR_META="proxmox-default-headers"
    else
        HDR_META="pve-headers"
    fi
    CUR_HDR="proxmox-headers-${KVER}"
    apt-cache show "$CUR_HDR" >/dev/null 2>&1 || CUR_HDR="pve-headers-${KVER}"
else
    FLAVOUR="${KVER##*-}"      # generic, amd64, cloud-amd64 -> amd64, ...
    CUR_HDR="linux-headers-${KVER}"
    if apt-cache show "linux-headers-${FLAVOUR}" >/dev/null 2>&1; then
        HDR_META="linux-headers-${FLAVOUR}"
    fi
fi

apt-get install -y dkms git python3 build-essential bc flex bison \
    libssl-dev libelf-dev dwarves kmod zstd xz-utils "$CUR_HDR" \
    || die "Failed to install dependencies (is ${CUR_HDR} available? 'apt list *headers*')"

if [[ -n "$HDR_META" ]]; then
    apt-get install -y "$HDR_META" \
        || warn "Could not install ${HDR_META}; make sure headers get installed with new kernels or DKMS can't rebuild!"
else
    warn "No headers metapackage found for this kernel flavour."
    warn "Make sure linux-headers for each NEW kernel get installed, or DKMS can't rebuild."
fi

[[ -d "/lib/modules/${KVER}/build" ]] || die "/lib/modules/${KVER}/build missing after header install."

# Earlier scripts (the original non-DKMS one, igc-patched, ...) deleted or
# overwrote the in-tree igc.ko. Without it there is no driver at all once the
# old package is removed, and our stock fallback has nothing to fall back to.
# Reinstall the kernel package that owns it, for every installed kernel.
log "Checking that every installed kernel still has its stock igc driver..."
for kdir in /lib/modules/*/; do
    k="$(basename "$kdir")"
    [[ -d "${kdir}kernel/drivers/net" ]] || continue
    ls "${kdir}kernel/drivers/net/ethernet/intel/igc/"igc.ko* >/dev/null 2>&1 && continue
    owner="$(dpkg -S "/boot/vmlinuz-${k}" 2>/dev/null | head -1 | cut -d: -f1 | cut -d, -f1)"
    if [[ -n "$owner" ]]; then
        warn "Stock igc.ko missing for ${k} - reinstalling ${owner} to restore it..."
        apt-get install -y --reinstall "$owner" \
            || warn "Reinstall of ${owner} failed; ${k} has no stock igc driver."
    else
        warn "Stock igc.ko missing for ${k} and no owning package found."
    fi
done
ls "/lib/modules/${KVER}/kernel/drivers/net/ethernet/intel/igc/"igc.ko* >/dev/null 2>&1 \
    || warn "Running kernel ${KVER} still has no stock igc.ko; continuing with the patched build."

# ---------------------------------------------------------------------------
# 3. Write the DKMS source tree
# ---------------------------------------------------------------------------
log "Writing DKMS package to ${SRCDIR}..."
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR" /etc/igc-nvmfix/src

cat > "${SRCDIR}/dkms.conf" <<EOF
PACKAGE_NAME="${PKG}"
PACKAGE_VERSION="${PKGVER}"
BUILT_MODULE_NAME[0]="igc"
DEST_MODULE_LOCATION[0]="/updates/dkms"
PRE_BUILD="igc-prepare.sh \${kernelver}"
MAKE[0]="bash ./igc-build.sh \${kernelver} \${kernel_source_dir}"
CLEAN="true"
AUTOINSTALL="yes"
EOF

# Placeholder; replaced by the upstream igc Makefile during PRE_BUILD
echo "# replaced by igc-prepare.sh" > "${SRCDIR}/Makefile"

# ---- PRE_BUILD wrapper: never fails, records failure for igc-build.sh -----
cat > "${SRCDIR}/igc-prepare.sh" <<'WRAP'
#!/usr/bin/env bash
# DKMS PRE_BUILD hook: igc-prepare.sh <kernelver>   (cwd = DKMS build dir)
# Must never fail: a failing DKMS build makes the kernel package's postinst
# fail and leaves apt/dpkg broken. On error, igc-build.sh installs the stock
# driver instead.
rm -f .igc-prepare-failed
if ! bash ./igc-fetch-patch.sh "$1"; then
    touch .igc-prepare-failed
    echo "[igc-nvmfix] prepare failed for $1 - will fall back to stock igc" >&2
fi
exit 0
WRAP

# ---- MAKE: build patched module, or fall back to the stock module ---------
cat > "${SRCDIR}/igc-build.sh" <<'BUILD'
#!/usr/bin/env bash
# DKMS MAKE: igc-build.sh <kernelver> <kernel_source_dir>   (cwd = build dir)
KVER="$1"; KSRC="$2"; B="$(pwd)"
log() { echo "[igc-nvmfix] $*"; }

fallback() {
    log "FALLBACK: $1"
    log "FALLBACK: installing the STOCK igc driver for ${KVER} so the kernel install doesn't break."
    log "FALLBACK: the NVM checksum bypass is NOT active on ${KVER}!"
    local stock
    stock="$(ls /lib/modules/"${KVER}"/kernel/drivers/net/ethernet/intel/igc/igc.ko* 2>/dev/null | head -1)"
    [[ -n "$stock" ]] || { log "No stock igc module found for ${KVER}"; exit 1; }
    case "$stock" in
        *.zst) zstd -dqf "$stock" -o "${B}/igc.ko" ;;
        *.xz)  xz -dc "$stock" > "${B}/igc.ko" ;;
        *.gz)  gzip -dc "$stock" > "${B}/igc.ko" ;;
        *)     cp -f "$stock" "${B}/igc.ko" ;;
    esac
    exit 0
}

[[ -f .igc-prepare-failed ]] && fallback "fetching or patching the igc source failed"
make -C "$KSRC" M="$B" modules || fallback "compiling the patched igc failed"
BUILD

# ---- Fetch source for the target kernel and patch it ----------------------
cat > "${SRCDIR}/igc-fetch-patch.sh" <<'PREP'
#!/usr/bin/env bash
# igc-fetch-patch.sh <kernelver>   (cwd = DKMS build dir)
set -euo pipefail

KVER="${1:?kernel version required}"
BUILD_DIR="$(pwd)"
CACHE="/var/cache/igc-nvmfix"
HDR="/lib/modules/${KVER}/build"
SUB="drivers/net/ethernet/intel/igc"
REPOS=(
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
    https://github.com/gregkh/linux.git
    https://github.com/torvalds/linux.git
)

log() { echo "[igc-nvmfix] $*" >&2; }

[[ -d "$HDR" ]] || { log "Headers for ${KVER} missing (${HDR}). Install them and run: dkms autoinstall"; exit 1; }

# Candidate upstream tags: exact stable (6.8.12) first, then mainline (6.8)
base="$(grep -oP '^\d+\.\d+(\.\d+)?' <<<"$KVER")"
mm="$(grep -oP '^\d+\.\d+' <<<"$base")"
sub="${base#"$mm"}"; sub="${sub#.}"
TAGS=()
[[ -n "$sub" && "$sub" != "0" ]] && TAGS+=("v${mm}.${sub}")
TAGS+=("v${mm}")

fetch_tag() {   # prints cache dir on success
    local tag="$1" dest="${CACHE}/$1" tmp repo
    if [[ -f "${dest}/.complete" ]]; then echo "$dest"; return 0; fi
    for repo in "${REPOS[@]}"; do
        log "Fetching ${SUB} @ ${tag} from ${repo} ..."
        tmp="$(mktemp -d)"
        if git clone -q --depth 1 --filter=blob:none --sparse --branch "$tag" \
                "$repo" "${tmp}/src" 2>/dev/null \
           && git -C "${tmp}/src" sparse-checkout set "$SUB" 2>/dev/null \
           && [[ -f "${tmp}/src/${SUB}/igc_main.c" ]]; then
            rm -rf "$dest"; mkdir -p "$dest"
            cp -a "${tmp}/src/${SUB}/." "$dest/"
            touch "${dest}/.complete"
            rm -rf "$tmp"
            echo "$dest"; return 0
        fi
        rm -rf "$tmp"
    done
    return 1
}

SRC=""
if [[ -f "/etc/igc-nvmfix/src/${KVER}/igc_main.c" ]]; then
    SRC="/etc/igc-nvmfix/src/${KVER}"
    log "Using local override source ${SRC}"
else
    for t in "${TAGS[@]}"; do
        if SRC="$(fetch_tag "$t")"; then log "Using upstream source ${t}"; break; fi
        SRC=""
    done
fi
[[ -n "$SRC" ]] || { log "Could not obtain igc source for ${KVER} (tried: ${TAGS[*]}). Network down?"; exit 1; }

# Copy driver source into the build dir (keep our own helper files)
find "$SRC" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile' \) \
    -exec cp -f {} "$BUILD_DIR/" \;

# Use the upstream Makefile (exact object list for this version) as obj-m
sed -i 's/obj-\$(CONFIG_IGC)/obj-m/' "${BUILD_DIR}/Makefile"
grep -q '^obj-m' "${BUILD_DIR}/Makefile" || { log "Unexpected upstream Makefile format"; exit 1; }

python3 "${BUILD_DIR}/igc-patch.py" "${BUILD_DIR}/igc_main.c" "${HDR}/include/net/xdp_sock_drv.h"
PREP

# ---- Patcher (NVM bypass + xsk API compat) --------------------------------
cat > "${SRCDIR}/igc-patch.py" <<'PYEOF'
#!/usr/bin/env python3
"""Patch igc_main.c: NVM checksum bypass (mandatory) + xsk API compat (optional)."""
import re, sys

main_c, xsk_hdr = sys.argv[1], sys.argv[2]
src = open(main_c).read()

# --- 1. NVM checksum bypass (whitespace-tolerant) ---------------------------
MARK = "ignoring, patched driver"
nvm_re = re.compile(
    r'(?P<ind>[ \t]*)if\s*\(\s*hw->nvm\.ops\.validate\(\s*hw\s*\)\s*<\s*0\s*\)\s*\{\s*'
    r'dev_err\(\s*&pdev->dev\s*,\s*"The NVM Checksum Is Not Valid\\n"\s*\)\s*;\s*'
    r'err\s*=\s*-EIO\s*;\s*'
    r'goto\s+\w+\s*;\s*'
    r'\}'
)
if MARK in src:
    print("[igc-nvmfix] NVM bypass already present.")
else:
    m = nvm_re.search(src)
    if not m:
        sys.exit("[igc-nvmfix] ERROR: NVM checksum block not found in igc_main.c "
                 "- upstream code changed; patcher needs updating.")
    ind = m.group("ind")
    repl = (f'{ind}if (hw->nvm.ops.validate(hw) < 0)\n'
            f'{ind}\tdev_warn(&pdev->dev, "The NVM Checksum Is Not Valid ({MARK})\\n");')
    src = src[:m.start()] + repl + src[m.end():]
    print("[igc-nvmfix] NVM checksum bypass applied.")

# --- 2. xsk_tx_metadata_request() compat ------------------------------------
try:
    hdr = open(xsk_hdr).read()
    uses_new_api = re.search(
        r"xsk_tx_metadata_request\s*\(\s*const\s+struct\s+xsk_buff_pool\s*\*", hdr) is not None
    old_call = re.compile(
        r"xsk_tx_metadata_request\(\s*meta\s*,\s*&igc_xsk_tx_metadata_ops\s*,\s*&meta_req\s*\)\s*;")
    if uses_new_api and old_call.search(src):
        src = old_call.sub(
            "xsk_tx_metadata_request(pool, &meta, &igc_xsk_tx_metadata_ops, &meta_req);",
            src, count=1)
        print("[igc-nvmfix] xsk_tx_metadata_request() adapted to pool-based API.")
except FileNotFoundError:
    print(f"[igc-nvmfix] {xsk_hdr} not found; skipping xsk compat check.")

open(main_c, "w").write(src)
PYEOF

chmod 755 "${SRCDIR}"/*.sh "${SRCDIR}/igc-patch.py"

# Skip DKMS's "module already installed / not newer" check for this package.
# Without it, the stock-driver fallback (identical to the in-tree module)
# would be refused during autoinstall and break the kernel install again.
mkdir -p /usr/share/dkms/modules_to_force_install
echo "${PKG}_version-override" > "/usr/share/dkms/modules_to_force_install/${PKG}"

# ---------------------------------------------------------------------------
# 4. Register, build and install for the running kernel (+ other installed ones)
# ---------------------------------------------------------------------------
log "Registering with DKMS..."
dkms add -m "$PKG" -v "$PKGVER"

log "Building for running kernel ${KVER}..."
if ! dkms build -m "$PKG" -v "$PKGVER" -k "$KVER"; then
    LOGF="/var/lib/dkms/${PKG}/${PKGVER}/build/make.log"
    die "DKMS build failed for ${KVER}. See ${LOGF}"
fi
if grep -q FALLBACK "/var/lib/dkms/${PKG}/${PKGVER}/build/make.log" 2>/dev/null; then
    grep FALLBACK "/var/lib/dkms/${PKG}/${PKGVER}/build/make.log" >&2
    die "Patched build failed for the running kernel ${KVER} (see /var/lib/dkms/${PKG}/${PKGVER}/build/make.log). Not installing."
fi
dkms install -m "$PKG" -v "$PKGVER" -k "$KVER" --force

# Kernels already installed but not booted yet (e.g. pending upgrade)
for kdir in /lib/modules/*/; do
    k="$(basename "$kdir")"
    [[ "$k" == "$KVER" || ! -d "${kdir}build" ]] && continue
    log "Also building for installed kernel ${k}..."
    { dkms build -m "$PKG" -v "$PKGVER" -k "$k" && \
      dkms install -m "$PKG" -v "$PKGVER" -k "$k" --force; } \
        || warn "Build for ${k} failed (stock igc will be used there)."
done

# ---------------------------------------------------------------------------
# 5. Unique MAC for ports whose NVM has no valid MAC
# ---------------------------------------------------------------------------
# A corrupt NVM often yields a placeholder MAC (e.g. 00:a0:c9:00:00:00, Intel
# OUI + zeros). Every affected card then has the SAME MAC -> ARP/switch/DHCP
# conflicts between nodes. Pin a stable, unique, locally administered MAC via
# a systemd .link file (derived from machine-id + PCI address, so re-runs give
# the same value). Applied by udev on the reload below and on every boot.
fix_placeholder_macs() {
    local dev pci ifname mac newmac linkf hash
    mkdir -p /etc/systemd/network
    for dev in /sys/bus/pci/drivers/igc/0000:*; do
        [[ -e "$dev" ]] || continue
        pci="$(basename "$dev")"
        linkf="/etc/systemd/network/10-igc-nvmfix-${pci//:/-}.link"
        [[ -f "$linkf" ]] && { log "MAC for ${pci} already pinned (${linkf})."; continue; }
        ifname="$(ls "${dev}/net" 2>/dev/null | head -1)"
        [[ -n "$ifname" ]] || continue
        mac="$(cat "/sys/class/net/${ifname}/address")"
        case "$mac" in
            00:a0:c9:00:00:00|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) ;;
            *) continue ;;
        esac
        if grep -lsE "Path=pci-${pci}|Name=${ifname}$|MACAddress=${mac}" /etc/systemd/network/*.link >/dev/null; then
            warn "${ifname} has placeholder MAC ${mac}, but an existing .link file already matches it:"
            grep -lsE "Path=pci-${pci}|Name=${ifname}$|MACAddress=${mac}" /etc/systemd/network/*.link | sed 's/^/    /'
            warn "Not touching it - add a unique 'MACAddress=02:..' under [Link] there yourself."
            continue
        fi
        hash="$(printf '%s-%s' "$(cat /etc/machine-id 2>/dev/null || hostname)" "$pci" | md5sum)"
        newmac="02:${hash:0:2}:${hash:2:2}:${hash:4:2}:${hash:6:2}:${hash:8:2}"
        cat > "$linkf" <<EOF
# managed by igc-nvmfix: the NVM of this i225/i226 has no valid MAC (${mac}).
# Pins a unique, locally administered MAC. Delete this file to undo.
[Match]
Path=pci-${pci}

[Link]
Name=${ifname}
MACAddress=${newmac}
EOF
        log "${ifname} (${pci}): placeholder MAC ${mac} -> ${newmac} (${linkf})"
        MAC_CHANGED=1
    done
}

MAC_CHANGED=0
if [[ $NO_MAC -eq 0 ]]; then
    fix_placeholder_macs
else
    log "--no-mac given: not touching MAC addresses."
fi

# ---------------------------------------------------------------------------
# 6. initramfs + reload
# ---------------------------------------------------------------------------
if command -v update-initramfs >/dev/null 2>&1; then
    log "Updating initramfs..."
    update-initramfs -u -k all || warn "update-initramfs reported an error"
fi

MODPATH="$(modinfo -n igc 2>/dev/null || true)"
[[ "$MODPATH" == *updates* ]] || warn "modinfo resolves igc to '${MODPATH}', not the DKMS copy - check 'depmod -a'."

log "Reloading igc module (network on igc ports drops for a few seconds)..."
# Run reload + network re-apply detached, so it completes even if this SSH
# session runs over an igc port and gets cut off.
nohup bash -c '
    rmmod igc 2>/dev/null
    modprobe igc || exit 1
    sleep 3
    # Re-attach igc ports to bridges/bonds (Proxmox vmbr*): rmmod removes
    # them and they are NOT re-added automatically.
    if command -v ifreload >/dev/null 2>&1; then
        ifreload -a
    elif command -v netplan >/dev/null 2>&1; then
        netplan apply
    elif systemctl is-active -q networking; then
        systemctl restart networking
    fi
' > /var/log/igc-nvmfix-reload.log 2>&1 &
wait $! || die "Reloading igc failed - see /var/log/igc-nvmfix-reload.log and 'dmesg | tail'"
MODPATH="$(modinfo -n igc 2>/dev/null || true)"

# Secure Boot hint
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot is enabled: the DKMS module must be signed with an enrolled MOK."
    warn "If modprobe complains about 'Key was rejected', run: mokutil --import /var/lib/dkms/mok.pub"
    warn "and reboot to enroll the key."
fi

ensure_systemd

if [[ $MAC_CHANGED -eq 1 ]]; then
    warn "MAC address changed: a DHCP lease or static ARP/switch entries may need updating."
fi

echo
log "Done. Module in use: ${MODPATH}"
for n in /sys/bus/pci/drivers/igc/0000:*/net/*; do
    [[ -e "$n" ]] && ip -br link show "$(basename "$n")"
done
dmesg | grep -i igc | tail -10 || true
echo
dkms status "$PKG"
echo
log "From now on every new kernel gets the patched igc automatically (DKMS autoinstall)."
log "Check anytime with: sudo $0 --status"
warn "Building on a new kernel needs network access (source is cached in /var/cache/igc-nvmfix)."
warn "If a future build fails, the stock (unpatched) igc is installed for that kernel instead,"
warn "so apt never breaks. '$0 --status' lists such kernels."
