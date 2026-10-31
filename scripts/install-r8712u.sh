#!/bin/bash
# Build, install and load the r8712u driver for Realtek RTL8188SU/S USB WiFi
# dongles (e.g. Sitecom USB 0df6:005b) as an out-of-tree kernel module.
#
# Usage: sudo bash install-r8712u.sh [--dkms] [source-dir]
#
#   --dkms        also register the source with DKMS (/usr/src/r8712u-<kver>)
#                 so the module is rebuilt automatically on kernel updates
#   source-dir    use an existing driver source tree instead of fetching one
#
# Driver source selection (when source-dir is not given):
#   - kernel <= 6.12 : in-tree staging source drivers/staging/rtl8712 from
#                      torvalds/linux tag v<major>.<minor> (sparse checkout)
#   - kernel >= 6.13 : the staging driver was removed from mainline; use the
#                      maintained fork
#                      https://github.com/RattanCandy/rtl8712u-linux-driver
#
# Environment:
#   EXTRA_MAKE    extra make variables, e.g. EXTRA_MAKE="CC=clang LD=ld.lld"
#                 for kernels built with LLVM/LTO (otherwise the link fails
#                 with "ld: unrecognised emulation mode: llvm")
set -euo pipefail

DKMS=0
SRC=""
for a in "$@"; do
    case "$a" in
        --dkms) DKMS=1 ;;
        *)      SRC="$a" ;;
    esac
done

K="$(uname -r)"
KVER="${K%%-*}"                       # e.g. 6.1.0
IFS='.' read -r MAJOR MINOR _ <<< "$KVER"

if [ -z "$SRC" ]; then
    if [ "$MAJOR" -gt 6 ] || { [ "$MAJOR" -eq 6 ] && [ "$MINOR" -ge 13 ]; }; then
        SRC="/tmp/rtl8712u-fork"
        [ -d "$SRC/driver" ] || git clone --depth 1 \
            https://github.com/RattanCandy/rtl8712u-linux-driver.git "$SRC"
        SRC="$SRC/driver"
    else
        SRC="/tmp/rtl8712u-v$KVER"
        if [ ! -f "$SRC/Makefile" ]; then
            rm -rf "${SRC}-git"
            git clone --depth 1 --branch "v$KVER" --filter=blob:none --sparse \
                https://github.com/torvalds/linux.git "${SRC}-git"
            git -C "${SRC}-git" sparse-checkout set "drivers/staging/rtl8712"
            mkdir -p "$SRC"
            cp -a "${SRC}-git/drivers/staging/rtl8712/." "$SRC/"
        fi
    fi
fi

EXTRA_MAKE="${EXTRA_MAKE:-}"

echo "== building r8712u for kernel $K from $SRC =="
# shellcheck disable=SC2086
make -C "/lib/modules/$K/build" M="$SRC" CONFIG_R8712U=m $EXTRA_MAKE modules
modinfo -F vermagic "$SRC/r8712u.ko"   # must match `uname -r`

if [ "$DKMS" -eq 1 ]; then
    echo "== registering with DKMS =="
    DSRC="/usr/src/r8712u-$KVER"
    rm -rf "$DSRC"
    mkdir -p "$DSRC"
    cp -a "$SRC/." "$DSRC/"
    cat > "$DSRC/dkms.conf" <<EOF
PACKAGE_NAME="r8712u"
PACKAGE_VERSION="$KVER"
BUILT_MODULE_NAME[0]="r8712u"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build CONFIG_R8712U=m modules"
AUTOINSTALL="yes"
EOF
    dkms add -m r8712u -v "$KVER" 2>/dev/null || true
    dkms build -m r8712u -v "$KVER" -k "$K"
    dkms install -m r8712u -v "$KVER" -k "$K"
else
    echo "== installing module =="
    install -D -m 644 "$SRC/r8712u.ko" "/lib/modules/$K/updates/r8712u.ko"
fi

depmod -a "$K"
echo "r8712u" > /etc/modules-load.d/r8712u.conf   # load at boot

echo "== loading =="
modprobe r8712u
sleep 2
ip link show
echo "== if the dongle is plugged in, check the wlan interface and scan =="
iwlist wlan* scan 2>/dev/null | grep ESSID || true
dmesg | grep -i r8712u | tail -10
