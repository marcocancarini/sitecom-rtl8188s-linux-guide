#!/bin/bash
# Build, install e load del driver r8712u per chiavette Realtek RTL8188SU
# (es. Sitecom USB 0df6:005b) su kernel moderni (testato su 7.2, fork 6.12-compat).
#
# Uso: sudo bash install-r8712u.sh [percorso-sorgenti-fork]
#   (default: clona il fork in /tmp/rtl8712u-build)
set -euo pipefail

SRC="${1:-/tmp/rtl8712u-build}"
K="$(uname -r)"

if [ ! -d "$SRC/driver" ]; then
    git clone --depth 1 https://github.com/RattanCandy/rtl8712u-linux-driver.git "$SRC"
fi

echo "== build r8712u per kernel $K =="
# Kernel LLVM/LTO (es. CachyOS): servono clang e ld.lld
make -C "/lib/modules/$K/build" M="$SRC/driver" CC=clang LD=ld.lld CONFIG_R8712U=m modules

echo "== install =="
install -D -m 644 "$SRC/driver/r8712u.ko" "/lib/modules/$K/updates/r8712u.ko"
depmod -a "$K"
echo "r8712u" > /etc/modules-load.d/r8712u.conf

echo "== load =="
modprobe r8712u
sleep 2
ip link show
echo "== se la chiavetta e' collegata, verifica wlan1 e scan =="
journalctl -k --no-pager | grep -i r8712u | tail -10
