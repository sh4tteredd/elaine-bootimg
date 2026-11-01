# Headless elaine: SSH + preconfigured network

Goal: boot the Nest Hub (2nd gen) into a **lightweight** Ubuntu with SSH
enabled and the network preconfigured, so you never wait for the desktop.

## 1. Use the server image, not the desktop image

The desktop image is what makes boot painfully slow (GDM, GNOME, snap
seeding). The preinstalled **server** image is a drop-in replacement:

- https://cdimage.ubuntu.com/ubuntu/releases/22.04/release/
  `ubuntu-22.04.5-preinstalled-server-arm64+raspi.img.xz` (~1.0 GB)

On macOS:

```shell
xz -dc ubuntu-22.04.5-preinstalled-server-arm64+raspi.img.xz \
  | sudo dd of=/dev/rdiskN bs=1m
```

Use the raw device (`/dev/rdiskN`, not `/dev/diskN`). Verify the root
filesystem label is `writable` and the boot partition is `system-boot`:

```shell
diskutil list
blkid   # on Linux, or mount the stick on Linux once
```

The U-Boot environment boots with `root=LABEL=writable`, which both the
desktop and server raspi images use.

## 2. Copy the boot files to `system-boot`

The boot partition is FAT and mounts automatically on macOS at
`/Volumes/system-boot`.

```shell
cp boot.img u-boot-elaine.bin /Volumes/system-boot/
cp headless/u-boot-elaine.cmd /Volumes/system-boot/u-boot-elaine.cmd
cp headless/user-data headless/meta-data headless/network-config /Volumes/system-boot/
```

`u-boot-elaine.cmd` is the U-Boot environment (`env import -t`); the
version here only removes the slow debug options from the kernel command
line (`debug=1 ignore_loglevel=1 earlycon=... loglevel=7`). Those print
the whole boot over a 115200-baud UART and are a large part of the delay.

Edit `headless/network-config` (SSID/password) and `headless/user-data`
(SSH public key and/or password) **before** copying, or edit them in
place on `/Volumes/system-boot`.

## 3. First boot

Normal chipicopwn flow: Pico first, then swap in the USB stick. cloud-init
runs once, resizes the root filesystem, creates the `ubuntu` user, enables
SSH and applies `network-config`.

Wait for the `Cloud-init ... finished` line on the console, then:

```shell
ssh ubuntu@elaine.local      # avahi, if it is enabled
ssh ubuntu@<ip-from-router>
```

`cat /var/log/elaine-links.txt` on the device shows the interfaces that
came up.

## 3b. Console only (no network, no SSH)

The server image has **no setup wizard**. It boots straight to a text
console on `tty1` (and on the UART with `console=ttyS0`). The GNOME
initial-setup wizard only exists in the desktop image.

So you can skip SSH entirely:

- keep the `chpasswd` block in `user-data` so you have a password for the
  physical console (SSH keys alone cannot log you in on `tty1`);
- delete or ignore `network-config`;
- `systemd.mask=systemd-networkd-wait-online.service` in
  `u-boot-elaine.cmd` avoids the ~2 minute wait when no interface is up.

You still need a keyboard on the Nest Hub USB port (through the same
powered hub as the USB stick) or a UART adapter.

### Which device is the eMMC

From the device tree:

| node          | state    | result                       |
|---------------|----------|------------------------------|
| `emmc@ffe07000` (`sd_emmc_c`, non-removable) | okay | **`/dev/mmcblk0` = eMMC** |
| `sd@ffe05000` (`sd_emmc_b`) | disabled | no SD slot                   |
| `sdio@ffe03000` (`sd_emmc_a`) | okay | WiFi only, no block device   |
| USB stick (rootfs) | - | `/dev/sda` (`writable` = `/dev/sda2`) |

The kernel uses the Amlogic partition parser
(`drivers/amlogic/mmc/emmc_partitions.c`) with the 17 entries in the DTB,
so the layout is normally:

```
p1 fts   p2 factory   p3 misc   p4 tpl_a   p5 tpl_b
p6 vbmeta_a   p7 vbmeta_b   p8 reserved_a
p9 boot_a   p10 boot_b
p11 system_a   p12 system_b
p13 data   p14 reserved_b   p15 reserved_c
p16 cache   p17 buf
```

Do not trust the numbers blindly — confirm on the device:

```shell
lsblk -o NAME,SIZE,TYPE,LABEL,PARTLABEL,MOUNTPOINT
cat /proc/partitions
blkid
```

### Dump / restore

The USB rootfs grows to fill the stick, so there is plenty of free space
for a dump (an 8 GB eMMC fits easily on a 16/32 GB stick):

```shell
sudo -i
# whole eMMC, compressed
dd if=/dev/mmcblk0 bs=4M status=progress | gzip -1 > /root/emmc.img.gz
# or one partition
dd if=/dev/mmcblk0p11 bs=4M status=progress of=/root/system_a.img
sync

# write back
dd if=/root/system_a.img of=/dev/mmcblk0p11 bs=4M status=progress conv=fsync
```

Keep a copy of the partition table before writing anything:

```shell
dd if=/dev/mmcblk0 of=/root/emmc-first-1M.bin bs=1M count=1
```

Nothing on the eMMC is mounted (root is `/dev/sda2`), so raw reads and
writes are safe as long as you use the right device node. Do not touch
`/dev/sda`.

## 4. WiFi: important caveat

The stock `boot.img` does **not** provide WiFi. From the kernel config
used for this kernel (`elaine-bx_defconfig`):

```
CONFIG_BCMDHD=m
CONFIG_BCMDHD_FW_PATH="/system/lib/firmware/fw_bcmdhd.bin"
CONFIG_BCMDHD_NVRAM_PATH="/system/lib/firmware/nvram.txt"
```

The Broadcom `dhd` driver is a **loadable module** and is not in
`boot.img`, and the stock Ubuntu rootfs has no `/system/lib/firmware`.
So `wlan0` will not exist and the `wifis:` block in `network-config` is
inert. This is why the reliable headless path is a **USB Ethernet
adapter**: `CONFIG_USB_RTL8152`, `CONFIG_USB_NET_AX8817X`,
`CONFIG_USB_NET_CDCETHER` and `CONFIG_USB_NET_CDC_NCM` are built in
(an iPhone in USB-tethering mode also works, it uses CDC-NCM).

To actually get WiFi you have to add both pieces:

1. Build `dhd.ko` against the exact same kernel. `CONFIG_MODVERSIONS` is
   off, so the module must match `vermagic`
   `4.9.244-g08814840dba2 SMP preempt mod_unload aarch64`:

   ```shell
   git clone https://github.com/frederic/elaine-linux
   git clone -b android-tv-deadpool-4.9-android12 \
     https://android.googlesource.com/kernel/amlogic-tv-modules/dhd-driver
   cd elaine-linux
   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- elaine-bx_defconfig
   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=../dhd-driver modules
   ```

   This produces `dhd.ko`.

2. Copy the device-specific firmware from the Nest Hub's own (still
   intact) Android `system_a` partition, read-only:

   ```shell
   sudo mount -o ro /dev/mmcblk0pN /mnt
   sudo mkdir -p /system/lib/firmware
   sudo cp /mnt/lib/firmware/fw_bcmdhd.bin /mnt/lib/firmware/nvram.txt \
     /system/lib/firmware/
   ```

3. Install and load the module:

   ```shell
   sudo mkdir -p /lib/modules/$(uname -r)/extra
   sudo cp dhd.ko /lib/modules/$(uname -r)/extra/
   sudo depmod -a
   echo dhd | sudo tee /etc/modules-load.d/dhd.conf
   sudo modprobe dhd
   ip link        # wlan0 should now appear
   sudo netplan apply
   ```

If `wlan0` appears, the `wifis:` block in `network-config` (or
`/etc/netplan/50-cloud-init.yaml`) starts working.

## 5. Making later boots faster

- Server image + `systemctl set-default multi-user.target` (done by
  `user-data`).
- snapd seeding disabled (done by `user-data`).
- Remove the debug kernel arguments (done by `u-boot-elaine.cmd`).
- Optionally drop `console=ttyS0,115200n8` entirely if you do not need
  the UART log; serial output is slow on this SoC.
- `touch /etc/cloud/cloud-init.disabled` after the first boot (commented
  out in `user-data`). Bump `instance-id` in `meta-data` if you ever want
  cloud-init to re-apply a changed seed.

## 6. Changing credentials later

The `system-boot` partition is FAT, so you can edit `user-data` and
`network-config` from macOS. For cloud-init to re-run, change
`instance-id` in `meta-data`, or configure the network directly on the
device with `sudo netplan edit`.
