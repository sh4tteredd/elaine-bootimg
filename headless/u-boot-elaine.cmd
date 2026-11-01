usbbootargs=zswap.enabled=1 zswap.zpool=z3fold zswap.compressor=zstd dwc_otg.lpm_enable=0 root=LABEL=writable rootfstype=ext4 rootwait fixrtc net.ifnames=0 systemd.mask=systemd-networkd-wait-online.service quiet loglevel=3 console=tty1 console=ttyS0,115200n8 no_console_suspend
bootimg_loadaddr=0x03080000

pwnboot=echo Loading boot.img from USB!; fatload usb 0 ${bootimg_loadaddr} boot.img; setenv bootargs ${bootargs} ${usbbootargs}; bootm ${bootimg_loadaddr};
