# Chiavetta WiFi Sitecom RTL8188S (USB `0df6:005b`) su Linux moderno

Guida testata su **CachyOS** (kernel `7.2.x`, Arch-based) per far funzionare le
vecchie chiavette WiFi Sitecom con chip **Realtek RTL8188SU / RTL8188S**,
che i kernel Linux moderni non supportano più in-tree.

> 🔒 **Privacy**: MAC address, SSID, password (PSK) e IP presenti nei log
> originali sono stati redatti con placeholder (`<MAC>`, `<SSID>`, `<PSK>`,
> `<IP>`). Gli ID USB del dispositivo (`0df6:005b`) non sono dati sensibili.

---

## 1. Sintomo

La chiavetta viene enumerata sul bus USB ma non appare alcuna interfaccia di
rete WiFi aggiuntiva:

```console
$ lsusb
Bus 002 Device 006: ID 0df6:005b Sitecom Europe B.V. RTL8188S WLAN Adapter

$ ip link show
1: lo: ...
2: eno0: ...          # ethernet
3: wlan0: ...         # scheda interna (es. Intel AX210)
# nessuna wlan1!
```

Verifica che nessun driver in-tree la claims:

```console
$ grep -i "p005B" /lib/modules/$(uname -r)/modules.alias
# nessun risultato per il vendor 0df6 -> nessun driver disponibile
```

## 2. Causa

L'unico driver che ha mai supportato questo chip è `r8712u`
(`CONFIG_R8712U`, staging `drivers/staging/rtl8712`), **rimosso dal kernel
mainline a partire dalla 6.13**. Nessun driver moderno (rtl8xxxu, rtlwifi,
rtw88/89, mt76...) supporta il chip RTL8188S: è un'architettura vecchia,
diversa dagli RTL8188EU/CU/FU.

## 3. Soluzione

Usare il fork out-of-tree mantenuto
**[RattanCandy/rtl8712u-linux-driver](https://github.com/RattanCandy/rtl8712u-linux-driver)**
(adattato dallo staging della v6.12, build verificati fino a kernel 7.0), la cui
tabella ID include `0x0DF6:0x005B`. Compilarlo contro il kernel in uso.

### Prerequisiti

```bash
sudo pacman -S --needed git base-devel linux-cachyos-headers clang lld \
    wireless_tools dhcpcd wpa_supplicant
# firmware rtlwifi/rtl8712u.bin (pacchetto linux-firmware-realtek)
```

> Su kernel compilati con **LLVM/LTO** (come CachyOS) la build deve usare
> `CC=clang LD=ld.lld`, altrimenti il link finale fallisce con
> `ld: unrecognised emulation mode: llvm`.

### Build e installazione

```bash
K=$(uname -r)
git clone --depth 1 https://github.com/RattanCandy/rtl8712u-linux-driver.git /tmp/rtl8712u-build
cd /tmp/rtl8712u-build/driver
make -C /lib/modules/$K/build M="$PWD" CC=clang LD=ld.lld CONFIG_R8712U=m modules
modinfo -F vermagic ./r8712u.ko   # deve coincidere con `uname -r`

sudo install -D -m 644 r8712u.ko /lib/modules/$K/updates/r8712u.ko
sudo depmod -a $K
echo "r8712u" | sudo tee /etc/modules-load.d/r8712u.conf   # load all'avvio
sudo modprobe r8712u
```

### Verifica

```console
$ lsmod | grep r8712u
r8712u                307200  0

$ ip link show wlan1
6: wlan1: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    link/ether <MAC_CHIAVETTA>

$ iwlist wlan1 scan | grep ESSID
                    ESSID:"<SSID_RETE_1>"
                    ESSID:"<SSID_RETE_2>"
```

Il driver carica il firmware `rtlwifi/rtl8712u.bin` e crea `wlan1`.

## 4. Connessione a una rete (WPA2-PSK, 2.4 GHz)

Il driver è **wext-only**: NetworkManager (nl80211) **non gestisce** `wlan1`.
Si usa `wpa_supplicant` con il driver `wext`:

```bash
sudo ip link set wlan1 up
sudo wpa_supplicant -Dwext -i wlan1 -c /etc/wpa_supplicant/wlan1.conf -B
sudo dhcpcd wlan1
```

`wpa_supplicant.conf` (vedi `wpa_supplicant.conf.example`):

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

## 5. Limitazioni del chip RTL8188S

- Solo banda **2.4 GHz** (no 5 GHz).
- Solo **WPA/WPA2-PSK** (no WPA3/SAE, no PMF obbligatorio).
- Throughput reale ~30-50 Mbit/s.
- La porta USB può dare errori `error -71` / re-enumerazioni se la chiavetta
  assorbe troppo (bus-powered, 500 mA): usare una porta diretta, non un hub
  non alimentato.

## 6. File inclusi

- `scripts/install-r8712u.sh` — script di build+install+load automatico.
- `wpa_supplicant.conf.example` — template di configurazione (placeholder).

## 7. Note di sicurezza

- Il modulo è out-of-tree e non firmato: carica solo se il Secure Boot non è
  in modalità "enforce" (`cat /sys/kernel/security/lockdown` → `[none]`).
- Dopo ogni aggiornamento del kernel **ricompilare** il modulo (o usare DKMS
  con il `dkms.conf` del fork).
