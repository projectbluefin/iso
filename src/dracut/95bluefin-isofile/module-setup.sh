#!/bin/bash
# Dracut module: support booting Bluefin ISO as a file from Ventoy-style media.

check() {
    return 0
}

depends() {
    echo dmsquash-live
    return 0
}

installkernel() {
    instmods loop iso9660 squashfs overlay
    instmods usb-storage xhci-pci xhci_hcd ehci-pci ehci_hcd uhci-hcd ohci-hcd
    instmods sd_mod sr_mod virtio_blk virtio_pci virtio_scsi
    instmods exfat vfat fat ntfs3 ext4 nls_cp437 nls_iso8859_1 nls_utf8
}

install() {
    inst_multiple mount umount blkid losetup find grep sed mkdir ln readlink basename cat sleep udevadm
    inst_hook initqueue 20 "$moddir/bluefin-isofile.sh"
}
