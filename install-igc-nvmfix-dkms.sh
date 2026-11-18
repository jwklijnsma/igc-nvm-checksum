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
#   sudo ./install-igc-nvmfix-dkms.sh                  install / reinstall (online)
#   sudo ./install-igc-nvmfix-dkms.sh --status         show DKMS + module status
#   sudo ./install-igc-nvmfix-dkms.sh --uninstall      remove, back to stock driver
#   sudo ./install-igc-nvmfix-dkms.sh --no-mac         don't pin a MAC address
#
# Offline:
#   sudo ./install-igc-nvmfix-dkms.sh --make-bundle [DIR] [--kernels "K1 K2"] [--with-kernel-images]
#       (on a machine WITH internet, same Debian/Proxmox release as the target)
#       downloads dkms + build tools + headers (+ kernel images) as .deb files
#       and the igc source for each kernel into DIR (default ./bundle).
#   sudo ./install-igc-nvmfix-dkms.sh --offline [DIR]
#       installs from that bundle without ANY network access.
#
# Bundled igc sources (vendor/igc/<tag>/) are used whenever downloading the
# source fails, so a kernel whose headers are present can always be built.
# An exact source for one kernel can be put in /etc/igc-nvmfix/src/<uname -r>/.
#
set -euo pipefail

PKG="igc-nvmfix"
PKGVER="2.7"
SRCDIR="/usr/src/${PKG}-${PKGVER}"
KVER="$(uname -r)"

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (sudo $0)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE="/usr/share/igc-nvmfix"           # persisted vendor sources + header debs
CACHE="/var/cache/igc-nvmfix"
OFFLINE_FLAG="/etc/igc-nvmfix/offline"
SUB="drivers/net/ethernet/intel/igc"
BASE_DEPS=(dkms git python3 build-essential bc flex bison libssl-dev libelf-dev
           dwarves kmod zstd xz-utils)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
NO_MAC=0; ACTION="install"; OFFLINE=0; BUNDLE=""; KERNELS=""; WITH_IMAGES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-mac)             NO_MAC=1 ;;
        --status)             ACTION="status" ;;
        --uninstall)          ACTION="uninstall" ;;
        --offline)            OFFLINE=1
                              if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then BUNDLE="$2"; shift; fi ;;
        --make-bundle)        ACTION="bundle"
                              if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then BUNDLE="$2"; shift; fi ;;
        --kernels)            KERNELS="${2:?--kernels needs a list}"; shift ;;
        --with-kernel-images) WITH_IMAGES=1 ;;
        *) die "Unknown option: $1 (see the header of this script for usage)" ;;
    esac
    shift
done

# Sparse-fetch only the igc driver dir for one tag into DEST (network).
fetch_igc_tag() {   # fetch_igc_tag <tag> <dest>
    local tag="$1" dest="$2" tmp repo
    for repo in https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
                https://github.com/gregkh/linux.git https://github.com/torvalds/linux.git; do
        tmp="$(mktemp -d)"
        if timeout 300 git clone -q --depth 1 --filter=blob:none --sparse --branch "$tag" \
                "$repo" "${tmp}/src" 2>/dev/null \
           && timeout 300 git -C "${tmp}/src" sparse-checkout set "$SUB" 2>/dev/null \
           && [[ -f "${tmp}/src/${SUB}/igc_main.c" ]]; then
            rm -rf "$dest"; mkdir -p "$dest"
            cp -a "${tmp}/src/${SUB}/." "$dest/"; touch "${dest}/.complete"
            rm -rf "$tmp"; return 0
        fi
        rm -rf "$tmp"
    done
    return 1
}

kernel_tags() {     # 7.3.5-1-pve -> "v7.3.5 v7.3"
    local base mm sub
    base="$(grep -oP '^\d+\.\d+(\.\d+)?' <<<"$1")"; mm="$(grep -oP '^\d+\.\d+' <<<"$base")"
    sub="${base#"$mm"}"; sub="${sub#.}"
    [[ -n "$sub" && "$sub" != "0" ]] && echo -n "v${mm}.${sub} "
    echo "v${mm}"
}

hdr_pkg_for() {     # first headers package name apt knows for a kernel
    local p
    for p in "proxmox-headers-$1" "pve-headers-$1" "linux-headers-$1"; do
        apt-cache show "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# --make-bundle: download everything needed for an offline install
# ---------------------------------------------------------------------------
if [[ "$ACTION" == "bundle" ]]; then
    BUNDLE="$(realpath -m "${BUNDLE:-${SCRIPT_DIR}/bundle}")"
    mkdir -p "${BUNDLE}/debs" "${BUNDLE}/src"
    if [[ -z "$KERNELS" ]]; then
        KERNELS="$(ls /lib/modules | sort -V | tr '\n' ' ')"
        # also the newest kernel apt offers for each installed series
        for meta in proxmox-default-kernel proxmox-kernel-7.3 proxmox-kernel-7.0; do
            dep="$(apt-cache depends "$meta" 2>/dev/null | grep -oP 'Depends: proxmox-kernel-\K[0-9][^ ]*-pve(?=-signed)?' | head -1 || true)"
            [[ -n "$dep" ]] && KERNELS+=" ${dep%-signed}"
        done
        KERNELS="$(tr ' ' '\n' <<<"$KERNELS" | sed '/^$/d' | sort -uV | tr '\n' ' ')"
    fi
    log "Building offline bundle in ${BUNDLE} for kernels: ${KERNELS}"
    apt-get update -qq || warn "apt-get update failed; using cached package lists"

    PKGS=("${BASE_DEPS[@]}")
    for k in $KERNELS; do
        if p="$(hdr_pkg_for "$k")"; then PKGS+=("$p"); else warn "No headers package found for ${k}"; fi
        if [[ $WITH_IMAGES -eq 1 ]]; then
            for p in "proxmox-kernel-${k}-signed" "proxmox-kernel-${k}" "linux-image-${k}"; do
                apt-cache show "$p" >/dev/null 2>&1 && { PKGS+=("$p"); break; }
            done
        fi
    done

    log "Resolving dependencies of: ${PKGS[*]}"
    mapfile -t ALL < <(apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances "${PKGS[@]}" 2>/dev/null \
        | grep -E '^[a-zA-Z0-9]' | sed 's/:any$//' | sort -u)
    log "Downloading ${#ALL[@]} packages..."
    ( cd "${BUNDLE}/debs" && for p in "${ALL[@]}"; do apt-get download -q "$p" >/dev/null 2>&1 || true; done )
    log "$(ls "${BUNDLE}/debs" | wc -l) .deb files, $(du -sh "${BUNDLE}/debs" | cut -f1)"

    for k in $KERNELS; do
        for t in $(kernel_tags "$k"); do
            [[ -f "${BUNDLE}/src/${t}/.complete" ]] && break
            if [[ -f "${SCRIPT_DIR}/vendor/igc/${t}/.complete" ]]; then
                cp -a "${SCRIPT_DIR}/vendor/igc/${t}" "${BUNDLE}/src/"; break
            fi
            log "Fetching igc source ${t}..."
            fetch_igc_tag "$t" "${BUNDLE}/src/${t}" && break
        done
    done

    # Make the bundle self-contained
    if [[ "$BUNDLE" != "$SCRIPT_DIR"/* ]]; then
        cp -f "${BASH_SOURCE[0]}" "${BUNDLE}/"
        [[ -f "${SCRIPT_DIR}/README.md" ]] && cp -f "${SCRIPT_DIR}/README.md" "${BUNDLE}/"
        [[ -d "${SCRIPT_DIR}/vendor" ]] && cp -a "${SCRIPT_DIR}/vendor" "${BUNDLE}/"
    fi
    {
        echo "created: $(date -Is) on $(hostname)"
        echo "os: $(. /etc/os-release; echo "$PRETTY_NAME")"
        command -v pveversion >/dev/null && echo "pve: $(pveversion)"
        echo "kernels: ${KERNELS}"
    } > "${BUNDLE}/BUNDLE_INFO"
    log "Bundle ready: ${BUNDLE} ($(du -sh "$BUNDLE" | cut -f1))"
    log "On the offline machine: sudo ./install-igc-nvmfix-dkms.sh --offline ${BUNDLE}"
    exit 0
fi

# Install every .deb from a bundle whose package isn't installed yet (or the
# given packages only). Never downgrades.
install_bundle_debs() {   # install_bundle_debs <debs dir> [package-name-regex]
    local dir="$1" filter="${2:-.}" deb name ver cur todo=()
    for deb in "$dir"/*.deb; do
        [[ -f "$deb" ]] || continue
        name="$(dpkg-deb -f "$deb" Package)"; ver="$(dpkg-deb -f "$deb" Version)"
        [[ "$name" =~ $filter ]] || continue
        cur="$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$name" 2>/dev/null || true)"
        if [[ "$cur" == ii* ]]; then
            dpkg --compare-versions "${cur##* }" ge "$ver" && continue
        fi
        todo+=("$deb")
    done
    [[ ${#todo[@]} -gt 0 ]] || return 0
    log "Installing ${#todo[@]} package(s) from the offline bundle..."
    apt-get install -y --no-download --no-install-recommends "${todo[@]}" \
        || dpkg -i "${todo[@]}" \
        || return 1
}

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

case "$ACTION" in
    status)
        dkms status "$PKG" 2>/dev/null || echo "dkms not installed"
        echo "Module used for ${KVER}: $(modinfo -n igc 2>/dev/null || echo 'none')"
        fb="$(grep -l "FALLBACK" /var/lib/dkms/${PKG}/*/*/*/log/make.log 2>/dev/null || true)"
        if [[ -n "$fb" ]]; then
            echo "Kernels where the patch FAILED and the stock driver was installed instead:"
            echo "$fb" | awk -F/ '{print "  - " $(NF-3)}'
        fi
        [[ -f "$OFFLINE_FLAG" ]] && echo "Mode: OFFLINE (no network fetches; delete ${OFFLINE_FLAG} to allow them)"
        echo "Bundled igc sources: $(ls "${SHARE}/vendor/igc" 2>/dev/null | tr '\n' ' ')"
        echo "Cached igc sources:  $(ls "$CACHE" 2>/dev/null | tr '\n' ' ')"
        for kdir in /lib/modules/*/; do
            k="$(basename "$kdir")"; [[ -d "${kdir}kernel" ]] || continue
            [[ -e "${kdir}build" ]] || echo "  ! no headers for ${k} (can't build there)"
        done
        dmesg | grep -i igc | tail -10 || true
        exit 0
        ;;
    uninstall)
        log "Removing all ${PKG} DKMS versions..."
        for v in $(dkms status "$PKG" 2>/dev/null | grep -oP "^${PKG}[/, ]+\K[0-9.]+" | sort -u); do
            dkms remove -m "$PKG" -v "$v" --all || true
            rm -rf "/usr/src/${PKG}-${v}"
        done
        rm -rf "$CACHE" "$SHARE" "$OFFLINE_FLAG"
        rm -f "/usr/share/dkms/modules_to_force_install/${PKG}"
        systemctl disable igc-nvmfix-ensure.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/igc-nvmfix-ensure.service /usr/sbin/igc-nvmfix-ensure \
              /etc/apt/apt.conf.d/99igc-nvmfix
        systemctl daemon-reload 2>/dev/null || true
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
esac

if [[ $OFFLINE -eq 1 ]]; then
    # Default bundle location: ./bundle next to the script, or the script dir
    # itself when the script was started from inside a bundle.
    if [[ -z "$BUNDLE" ]]; then
        if [[ -d "${SCRIPT_DIR}/bundle/debs" ]]; then BUNDLE="${SCRIPT_DIR}/bundle"; else BUNDLE="$SCRIPT_DIR"; fi
    fi
    BUNDLE="$(realpath -m "$BUNDLE")"
    [[ -d "${BUNDLE}/debs" ]] || die "No offline bundle at ${BUNDLE} (expected ${BUNDLE}/debs). Create one with --make-bundle on a machine with internet."
    log "OFFLINE mode, bundle: ${BUNDLE}"
    [[ -f "${BUNDLE}/BUNDLE_INFO" ]] && sed 's/^/    /' "${BUNDLE}/BUNDLE_INFO"
fi

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
# Persist bundled sources so future kernel builds work without network
mkdir -p "${SHARE}/vendor/igc" "$CACHE" /etc/igc-nvmfix/src
[[ -d "${SCRIPT_DIR}/vendor/igc" ]] && cp -a "${SCRIPT_DIR}/vendor/igc/." "${SHARE}/vendor/igc/"
if [[ $OFFLINE -eq 1 ]]; then
    [[ -d "${BUNDLE}/vendor/igc" ]] && cp -a "${BUNDLE}/vendor/igc/." "${SHARE}/vendor/igc/"
    [[ -d "${BUNDLE}/src" ]] && cp -a "${BUNDLE}/src/." "${CACHE}/"
fi

if [[ $OFFLINE -eq 1 ]]; then
    touch "$OFFLINE_FLAG"
    # Keep the header (+ kernel image) debs locally, so igc-nvmfix-ensure can
    # use them later without network.
    mkdir -p "${SHARE}/debs"
    cp -f "${BUNDLE}"/debs/{proxmox-headers,pve-headers,linux-headers,proxmox-kernel,linux-image}-*.deb \
        "${SHARE}/debs/" 2>/dev/null || true

    install_bundle_debs "${BUNDLE}/debs" \
        || die "Installing packages from the bundle failed. Was it made on the same OS release?"
    for d in "${BASE_DEPS[@]}"; do
        dpkg -s "$d" >/dev/null 2>&1 || die "Required package '${d}' missing and not in the bundle."
    done
    [[ -e "/lib/modules/${KVER}/build" ]] \
        || die "No headers for the running kernel ${KVER} in the bundle. Re-make it with: --make-bundle --kernels \"${KVER}\""
fi

if [[ $OFFLINE -eq 0 ]]; then
rm -f "$OFFLINE_FLAG"
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

apt-get install -y "${BASE_DEPS[@]}" "$CUR_HDR" \
    || die "Failed to install dependencies (is ${CUR_HDR} available? 'apt list *headers*')"

if [[ -n "$HDR_META" ]]; then
    apt-get install -y "$HDR_META" \
        || warn "Could not install ${HDR_META}; make sure headers get installed with new kernels or DKMS can't rebuild!"
else
    warn "No headers metapackage found for this kernel flavour."
    warn "Make sure linux-headers for each NEW kernel get installed, or DKMS can't rebuild."
fi
fi  # online

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
    if [[ -n "$owner" && $OFFLINE -eq 1 ]]; then
        deb="$(ls "${BUNDLE}/debs/${owner}_"*.deb 2>/dev/null | head -1 || true)"
        if [[ -n "$deb" ]]; then
            warn "Stock igc.ko missing for ${k} - reinstalling ${owner} from the bundle..."
            dpkg -i "$deb" || warn "Reinstall of ${owner} failed."
        else
            warn "Stock igc.ko missing for ${k}; ${owner} is not in the bundle (use --with-kernel-images)."
        fi
    elif [[ -n "$owner" ]]; then
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
VENDOR="/usr/share/igc-nvmfix/vendor/igc"
OFFLINE_FLAG="/etc/igc-nvmfix/offline"
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
        if timeout 300 git clone -q --depth 1 --filter=blob:none --sparse --branch "$tag" \
                "$repo" "${tmp}/src" 2>/dev/null \
           && timeout 300 git -C "${tmp}/src" sparse-checkout set "$SUB" 2>/dev/null \
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

# Highest local source (cache or bundled vendor) of the same major.minor
nearest_local() {
    local d best
    best="$(for d in "$CACHE"/v"${mm}"* "$VENDOR"/v"${mm}"*; do
                [[ -f "${d}/.complete" ]] || continue
                [[ "$(basename "$d")" =~ ^v${mm//./\\.}(\.[0-9]+)?$ ]] || continue
                echo "$(basename "$d") ${d}"
            done | sort -V | tail -1 | cut -d' ' -f2-)"
    [[ -n "$best" ]] && echo "$best"
}

SRC=""
if [[ -f "/etc/igc-nvmfix/src/${KVER}/igc_main.c" ]]; then
    SRC="/etc/igc-nvmfix/src/${KVER}"
    log "Using local override source ${SRC}"
fi
# 1. exact tag already available locally (cache, then bundled vendor)
if [[ -z "$SRC" ]]; then
    for t in "${TAGS[@]}"; do
        for d in "${CACHE}/${t}" "${VENDOR}/${t}"; do
            [[ -f "${d}/.complete" ]] && { SRC="$d"; log "Using local source ${d}"; break 2; }
        done
    done
fi
# 2. download (unless offline mode)
if [[ -z "$SRC" && ! -f "$OFFLINE_FLAG" ]]; then
    for t in "${TAGS[@]}"; do
        if SRC="$(fetch_tag "$t")"; then log "Using upstream source ${t}"; break; fi
        SRC=""
    done
fi
# 3. offline / no network: nearest local source of the same series
if [[ -z "$SRC" ]] && SRC="$(nearest_local)"; then
    log "No exact source for ${KVER}; using nearest local source ${SRC} (same ${mm} series)"
fi
[[ -n "$SRC" ]] || { log "No igc source for ${KVER} (tried: ${TAGS[*]}, no local v${mm}.x). Offline? Add one with --make-bundle."; exit 1; }

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

# ---------------------------------------------------------------------------
# 4b. Self-healing for ALL kernels: headers + build, after apt and at boot
# ---------------------------------------------------------------------------
# DKMS silently skips kernels without headers. Headers metapackages only
# track the DEFAULT kernel series (e.g. proxmox-default-headers), so opt-in
# kernels (Proxmox 7.3 on a 7.0 default, HWE, ...) end up with the stock,
# failing igc. igc-nvmfix-ensure installs missing headers and builds for
# every installed kernel; it runs after every apt run and at boot.
cat > /usr/sbin/igc-nvmfix-ensure <<'ENSURE'
#!/usr/bin/env bash
# igc-nvmfix-ensure [--reload]
# Make sure every installed kernel has headers and the patched igc module.
# --reload: if the running kernel just got the module, load it + re-apply network.
set -u
PKG="igc-nvmfix"
log() { echo "[igc-nvmfix-ensure] $*"; }
VER="$(ls -d /usr/src/${PKG}-* 2>/dev/null | sed "s#.*/${PKG}-##" | sort -V | tail -1)"
[[ -n "$VER" ]] || { log "no ${PKG} source in /usr/src; nothing to do"; exit 0; }

hdr_pkg() {
    local p
    for p in "proxmox-headers-$1" "pve-headers-$1" "linux-headers-$1"; do
        apt-cache show "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    return 1
}

RUNNING="$(uname -r)"
CHANGED_RUNNING=0
for kdir in /lib/modules/*/; do
    k="$(basename "$kdir")"
    [[ -d "${kdir}kernel" ]] || continue
    if [[ ! -e "${kdir}build" ]]; then
        deb="$(ls /usr/share/igc-nvmfix/debs/{proxmox,pve,linux}-headers-"${k}"_*.deb 2>/dev/null | head -1)"
        if [[ -n "$deb" ]]; then
            log "Installing missing headers for ${k} from local bundle: ${deb##*/}"
            dpkg -i "$deb" || log "could not install ${deb}"
        elif [[ -f /etc/igc-nvmfix/offline ]]; then
            log "OFFLINE: no headers for ${k}. Make a bundle with: --make-bundle --kernels \"${k}\""
        elif p="$(hdr_pkg "$k")"; then
            log "Installing missing headers for ${k}: ${p}"
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y "$p" \
                || log "could not install ${p}"
        else
            log "No headers package found for ${k}; skipping"
        fi
    fi
    [[ -e "${kdir}build" ]] || continue
    if dkms status -m "$PKG" -v "$VER" -k "$k" 2>/dev/null | grep -q installed; then
        continue
    fi
    log "Building ${PKG}/${VER} for ${k}..."
    if dkms install -m "$PKG" -v "$VER" -k "$k" --force; then
        command -v update-initramfs >/dev/null && update-initramfs -u -k "$k"
        [[ "$k" == "$RUNNING" ]] && CHANGED_RUNNING=1
    else
        log "build/install for ${k} failed"
    fi
done

if [[ "${1:-}" == "--reload" ]]; then
    if [[ "$(modinfo -n igc 2>/dev/null)" == *updates* ]] && \
       { [[ $CHANGED_RUNNING -eq 1 ]] || ! ls /sys/bus/pci/drivers/igc/0000:* >/dev/null 2>&1; }; then
        log "Loading patched igc for ${RUNNING}..."
        rmmod igc 2>/dev/null
        modprobe igc && sleep 3
        command -v ifreload >/dev/null && ifreload -a
    fi
fi
exit 0
ENSURE
chmod 755 /usr/sbin/igc-nvmfix-ensure

cat > /etc/systemd/system/igc-nvmfix-ensure.service <<'UNIT'
[Unit]
Description=Ensure the patched igc driver (igc-nvmfix) is built for all kernels
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/igc-nvmfix-ensure --reload
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
UNIT

# After every apt/dpkg run: schedule an ensure run (detached, waits for the
# apt lock), so headers for newly installed kernels get installed too.
cat > /etc/apt/apt.conf.d/99igc-nvmfix <<'APT'
DPkg::Post-Invoke { "if [ -x /usr/sbin/igc-nvmfix-ensure ] && command -v systemd-run >/dev/null; then systemd-run --quiet --no-block --collect --unit=igc-nvmfix-ensure-apt --on-active=30 /usr/sbin/igc-nvmfix-ensure >/dev/null 2>&1 || true; fi"; };
APT

systemctl daemon-reload 2>/dev/null || true
systemctl enable igc-nvmfix-ensure.service >/dev/null 2>&1 || warn "could not enable igc-nvmfix-ensure.service"

log "Installing headers + building for all other installed kernels..."
/usr/sbin/igc-nvmfix-ensure || true

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
if [[ $OFFLINE -eq 1 ]]; then
    warn "OFFLINE mode: new kernels build from bundled/cached sources only, and need their"
    warn "headers installed (or in a bundle). Back online? Re-run without --offline."
else
    warn "Sources are cached in ${CACHE}; bundled sources in ${SHARE}/vendor are used when offline."
fi
warn "If a future build fails, the stock (unpatched) igc is installed for that kernel instead,"
warn "so apt never breaks. '$0 --status' lists such kernels."
