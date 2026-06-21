# ISO assembly builder image (Debian-based)
#
# Used by: just iso-sd-boot <target>
#
# This container has all the tools needed to assemble a UEFI live ISO:
#   xorriso      — ISO-9660 creation with El Torito EFI boot entry
#   mksquashfs   — compress the live rootfs into a squashfs image
#   mkfs.fat     — create the FAT ESP image for systemd-boot
#   mtools       — populate the FAT image without requiring a loop mount
#   implantisomd5 — embed MD5 checksum for ISO integrity verification
#
# All tools run in their native Debian environment; no cross-distro binary
# grafting required.
FROM debian:sid@sha256:d4b76cd3c767e81dbbeb88e1c252c85275c3fba518ad7d17a42c9eb0b6b5b9bb

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xorriso \
        isomd5sum \
        squashfs-tools \
        dosfstools \
        mtools \
    && rm -rf /var/lib/apt/lists/*

COPY src/build-iso.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]
