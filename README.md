# Sitecom RTL8188S USB WiFi dongle (`0df6:005b`) on modern Linux

Guide to making old Sitecom WiFi dongles with the **Realtek RTL8188SU / RTL8188S**
chip work on modern Linux kernels via the out-of-tree `r8712u` driver.

> 🔒 **Privacy**: MAC addresses, SSIDs, PSKs and IPs from the original logs are
> redacted with placeholders (`<MAC>`, `<SSID>`, `<PSK>`, `<IP>`).
> The USB IDs (`0df6:005b`) are not sensitive.

## Tested setups

| System | Kernel | Driver source |
|---|---|---|
| CachyOS (Arch-based, LLVM/LTO) | 7.2.x | fork [RattanCandy/rtl8712u-linux-driver](https://github.com/RattanCandy/rtl8712u-linux-driver) (from the 6.12 staging driver) |
| Ubuntu 24.04 ARM64 (rockchip SoC) | `6.1.0-1025-rockchip` | in-tree staging source of the same kernel: `drivers/staging/rtl8712` @ `v6.1` (torvalds/linux), built out-of-tree |

## 1. Symptom

The dongle is enumerated on the USB bus but no extra WiFi interface appears:

```console
$ lsusb
Bus 003 Device 002: ID 0df6:005b Sitecom Europe B.V. RTL8188S WLAN Adapter

$ lsusb -t
    |__ Port 001: Dev 002, If 0, Class=Vendor Specific Class, Driver=[none], 480M

$ ip link show
... # no wlan interface for the dongle
```

Check that no in-tree driver claims it:

```console
$ grep -i "p005B" /lib/modules/$(uname -r)/modules.alias
# no result for vendor 0df6 -> no driver available
```

## 2. Cause

The only driver that ever supported this chip is `r8712u` (`CONFIG_R8712U`,
`drivers/staging/rtl8712`), **removed from the mainline kernel in 6.13** — and
often disabled in vendor configs anyway (e.g. `# CONFIG_R8712U is not set` on
the Ubuntu rockchip kernel). No modern driver (rtl8xxxu, rtlwifi, rtw88/89,
mt76...) supports the RTL8188S: it is an old architecture, different from the
RTL8188EU/CU/FU.

## 3. Solution

Build `r8712u` out-of-tree against the running kernel:

- **kernel <= 6.12**: use the matching in-tree staging source
  `drivers/staging/rtl8712` from `torvalds/linux` tag `v<major>.<minor>`
  (its ID table includes `0x0DF6:0x005B`). This is the most reliable option:
  the source matches the kernel ABI exactly.
- **kernel >= 6.13**: the staging driver no longer exists in mainline; use the
  maintained fork
  [RattanCandy/rtl8712u-linux-driver](https://github.com/RattanCandy/rtl8712u-linux-driver)
  (adapted from the 6.12 staging driver, build-tested up to kernel 7.x), whose
  ID table also includes `0x0DF6:0x005B`.

`scripts/install-r8712u.sh` automates source selection, build, install and
load; with `--dkms` it also registers the source with DKMS so the module is
rebuilt automatically on every kernel update.

### Prerequisites

```bash
# Debian/Ubuntu
sudo apt install git build-essential "linux-headers-$(uname -r)" dkms \
    linux-firmware iw wireless-tools wpa_supplicant dhcpcd
# Arch/CachyOS
sudo pacman -S --needed git base-devel linux-cachyos-headers clang lld \
    wireless_tools dhcpcd wpa_supplicant linux-firmware-realtek
```

The firmware `rtlwifi/rtl8712u.bin` (package `linux-firmware`) is required.

> On kernels compiled with **LLVM/LTO** (e.g. CachyOS) the build must use
> `CC=clang LD=ld.lld`, otherwise the final link fails with
> `ld: unrecognised emulation mode: llvm`. Pass `EXTRA_MAKE="CC=clang LD=ld.lld"`
> to the install script.

### Build and install

```bash
sudo bash scripts/install-r8712u.sh --dkms
```

Manual equivalent:

```bash
K=$(uname -r)
# ... fetch the right source into $SRC (see above) ...
make -C /lib/modules/$K/build M="$SRC" CONFIG_R8712U=m modules
modinfo -F vermagic "$SRC/r8712u.ko"        # must match `uname -r`

sudo install -D -m 644 "$SRC/r8712u.ko" /lib/modules/$K/updates/r8712u.ko
sudo depmod -a "$K"
echo "r8712u" | sudo tee /etc/modules-load.d/r8712u.conf   # load at boot
sudo modprobe r8712u
```

With DKMS (recommended; the module lands in `/lib/modules/$K/updates/dkms/`):

```bash
# source tree in /usr/src/r8712u-<kver> with dkms.conf from this repo
sudo dkms add -m r8712u -v 6.1
sudo dkms build -m r8712u -v 6.1 -k "$(uname -r)"
sudo dkms install -m r8712u -v 6.1 -k "$(uname -r)"
sudo depmod -a "$(uname -r)"
```

### Installing without a sudo password (privileged container)

On hosts where `sudo` requires a password but `docker` is `NOPASSWD`, the whole
install can run from a privileged container chrooted on the host root (the
container shares the host kernel and has `CAP_SYS_MODULE`):

```bash
sudo -n docker run --rm --privileged --network host -v /:/host alpine:3.20 \
    chroot /host /bin/bash /path/to/install-r8712u.sh --dkms
```

### Verification

```console
$ lsusb -t | grep -A1 'Bus 003'
    |__ Port 001: Dev 002, If 0, Class=Vendor Specific Class, Driver=r8712u, 480M

$ dmesg | grep r8712u
r8712u: Loading firmware from "rtlwifi/rtl8712u.bin"
r8712u 3-1:1.0 wlx000cf6d26ec2: renamed from wlan0

$ ip link show
...: wlx000cf6d26ec2: <BROADCAST,MULTICAST> ... link/ether <MAC_DONGLE>

$ iwlist wlx000cf6d26ec2 scan | grep ESSID
                    ESSID:"<SSID_1>"
                    ESSID:"<SSID_2>"
```

The driver loads the firmware `rtlwifi/rtl8712u.bin` and creates the interface
(`wlan0`, or a predictable name like `wlx<MAC>`). Persistence across reboots
comes from the module on disk plus `/etc/modules-load.d/r8712u.conf`
(systemd-modules-load); DKMS covers kernel updates.

## 4. Connecting to a network (WPA2-PSK, 2.4 GHz)

The driver is **wext-only**: NetworkManager (nl80211) does **not** manage this
interface. Use `wpa_supplicant` with the `wext` driver:

```bash
sudo ip link set wlx000cf6d26ec2 up
sudo wpa_supplicant -Dwext -i wlx000cf6d26ec2 -c /etc/wpa_supplicant/wlx.conf -B
sudo dhcpcd wlx000cf6d26ec2
```

`wpa_supplicant.conf` (see `wpa_supplicant.conf.example`):

```
ctrl_interface=/run/wpa_supplicant
network={
    ssid="<SSID>"
    psk="<PSK>"
    key_mgmt=WPA-PSK
    proto=WPA RSN
    pairwise=CCMP TKIP
    group=CCMP TKIP
}
```

## 5. RTL8188S chip limitations

- **2.4 GHz only** (no 5 GHz).
- **WPA/WPA2-PSK only** (no WPA3/SAE, no mandatory PMF).
- Real throughput ~30-50 Mbit/s.
- The USB port may log `error -71` / re-enumerations if the dongle draws too
  much power (bus-powered, 500 mA): use a direct port, not an unpowered hub.

## 6. Files

- `scripts/install-r8712u.sh` — automatic source selection + build + install + load (`--dkms` for DKMS).
- `dkms.conf` — DKMS configuration template.
- `wpa_supplicant.conf.example` — wpa_supplicant configuration template (placeholders).

## 7. Security notes

- The module is out-of-tree and unsigned: it only loads if Secure Boot is not
  in "enforce" mode (`cat /sys/kernel/security/lockdown` → `[none]`).
- After every kernel update **rebuild** the module (or rely on DKMS with
  `AUTOINSTALL="yes"`).
