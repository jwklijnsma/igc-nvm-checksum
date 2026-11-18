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
PKGVER="2.0"
SRCDIR="/usr/src/${PKG}-${PKGVER}"
KVER="$(uname -r)"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (sudo $0)"

# ---------------------------------------------------------------------------
# --status / --uninstall
# ---------------------------------------------------------------------------
case "${1:-}" in
    --status)
        dkms status "$PKG" 2>/dev/null || echo "dkms not installed"
        echo "Module used for ${KVER}: $(modinfo -n igc 2>/dev/null || echo 'none')"
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
    *) die "Unknown option: $1 (use --status or --uninstall)" ;;
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
# 1. Dependencies (+ headers metapackage so FUTURE kernels get headers too)
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
    libssl-dev libelf-dev dwarves kmod "$CUR_HDR" \
    || die "Failed to install dependencies (is ${CUR_HDR} available? 'apt list *headers*')"

if [[ -n "$HDR_META" ]]; then
    apt-get install -y "$HDR_META" \
        || warn "Could not install ${HDR_META}; make sure headers get installed with new kernels or DKMS can't rebuild!"
else
    warn "No headers metapackage found for this kernel flavour."
    warn "Make sure linux-headers for each NEW kernel get installed, or DKMS can't rebuild."
fi

[[ -d "/lib/modules/${KVER}/build" ]] || die "/lib/modules/${KVER}/build missing after header install."

# ---------------------------------------------------------------------------
# 2. Write the DKMS source tree
# ---------------------------------------------------------------------------
log "Writing DKMS package to ${SRCDIR}..."

# Remove any older/same version already registered
for v in $(dkms status "$PKG" 2>/dev/null | grep -oP "^${PKG}[/, ]+\K[0-9.]+" | sort -u); do
    dkms remove -m "$PKG" -v "$v" --all >/dev/null 2>&1 || true
    [[ "$v" != "$PKGVER" ]] && rm -rf "/usr/src/${PKG}-${v}"
done
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR" /etc/igc-nvmfix/src

cat > "${SRCDIR}/dkms.conf" <<EOF
PACKAGE_NAME="${PKG}"
PACKAGE_VERSION="${PKGVER}"
BUILT_MODULE_NAME[0]="igc"
DEST_MODULE_LOCATION[0]="/updates/dkms"
PRE_BUILD="igc-prepare.sh \${kernelver}"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="true"
AUTOINSTALL="yes"
EOF

# Placeholder; replaced by the upstream igc Makefile during PRE_BUILD
echo "# replaced by igc-prepare.sh" > "${SRCDIR}/Makefile"

# ---- PRE_BUILD: fetch source for the target kernel and patch it -----------
cat > "${SRCDIR}/igc-prepare.sh" <<'PREP'
#!/usr/bin/env bash
# DKMS PRE_BUILD hook: igc-prepare.sh <kernelver>   (cwd = DKMS build dir)
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

chmod 755 "${SRCDIR}/igc-prepare.sh" "${SRCDIR}/igc-patch.py"

# ---------------------------------------------------------------------------
# 3. Register, build and install for the running kernel (+ other installed ones)
# ---------------------------------------------------------------------------
log "Registering with DKMS..."
dkms add -m "$PKG" -v "$PKGVER"

log "Building for running kernel ${KVER}..."
if ! dkms build -m "$PKG" -v "$PKGVER" -k "$KVER"; then
    LOGF="/var/lib/dkms/${PKG}/${PKGVER}/build/make.log"
    die "DKMS build failed for ${KVER}. See ${LOGF}"
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
# 4. initramfs + reload
# ---------------------------------------------------------------------------
if command -v update-initramfs >/dev/null 2>&1; then
    log "Updating initramfs..."
    update-initramfs -u -k all || warn "update-initramfs reported an error"
fi

MODPATH="$(modinfo -n igc 2>/dev/null || true)"
[[ "$MODPATH" == *updates* ]] || warn "modinfo resolves igc to '${MODPATH}', not the DKMS copy - check 'depmod -a'."

log "Reloading igc module..."
rmmod igc 2>/dev/null || warn "igc was not loaded or rmmod failed (continuing)"
modprobe igc || die "modprobe igc failed - check 'dmesg | tail'"

# Secure Boot hint
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot is enabled: the DKMS module must be signed with an enrolled MOK."
    warn "If modprobe complains about 'Key was rejected', run: mokutil --import /var/lib/dkms/mok.pub"
    warn "and reboot to enroll the key."
fi

echo
log "Done. Module in use: ${MODPATH}"
dmesg | grep -i igc | tail -10 || true
echo
dkms status "$PKG"
echo
log "From now on every new kernel gets the patched igc automatically (DKMS autoinstall)."
log "Check anytime with: sudo $0 --status"
warn "Building on a new kernel needs network access (source is cached in /var/cache/igc-nvmfix)."
warn "If a future build fails, the stock (unpatched) igc is used for that kernel - check 'dkms status'."
