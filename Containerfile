# Bluefin live ISO installer image
#
# Build with:
#   just container bluefin
#
# Three-stage build:
#   1. bluefin-ref   — original Bluefin image (provides kernel modules)
#   2. initramfs-builder — Debian: builds a dmsquash-live initramfs against
#                          Bluefin's kernel modules in its native glibc environment
#   3. final        — Bluefin: receives the rebuilt initramfs + live-env setup
#
# Bluefin is Fedora/ostree-based using GRUB2 for the installed system.
# The live ISO uses systemd-boot for ESP boot (installed in the final stage).
# The installed system's bootloader is controlled by fisherman/bootc-installer
# via images.json (grub2).
#
# The initramfs is built in a separate Debian stage so no cross-distro binary
# grafting is needed; only the initramfs.img output crosses the stage boundary.

# Base image — override to build bluefin-lts or other variants.
# Example: podman build --build-arg BASE_IMAGE=ghcr.io/ublue-os/bluefin-lts:latest ...
ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin:stable

# ── Stage 1: Bluefin reference (kernel modules source) ───────────────────────
FROM ${BASE_IMAGE} AS bluefin-ref

# ── Stage 2: Debian — builds the dmsquash-live initramfs ─────────────────────
# Dracut runs natively in Debian against Bluefin's kernel modules.
# Only /tmp/initramfs.img crosses into the final stage.
FROM debian:sid AS initramfs-builder

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dracut \
        dmsetup \
    && rm -rf /var/lib/apt/lists/*

# Import Bluefin's kernel module tree so dracut targets the correct kernel
COPY --from=bluefin-ref /usr/lib/modules /usr/lib/modules

# Add Bluefin-specific initramfs support for Ventoy/file-backed ISO boot.
COPY src/dracut/95bluefin-isofile /usr/lib/dracut/modules.d/95bluefin-isofile

RUN set -ex; \
    kernel=$(ls /usr/lib/modules | sort -V | tail -1); \
    echo "Building dmsquash-live initramfs for kernel ${kernel}"; \
    # Check which optional drivers are available (el10 kernel may lack ntfs3).
    NTFS3=""; test -f "/usr/lib/modules/${kernel}/kernel/fs/ntfs3/ntfs3.ko" && NTFS3="ntfs3"; \
    DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
        --add "dmsquash-live bluefin-isofile" \
        --add-drivers "squashfs overlay loop iso9660 sr_mod cdrom sd_mod usb-storage xhci-pci exfat vfat fat ${NTFS3} ext4" \
        /tmp/initramfs.img "${kernel}"; \
    ls -lh /tmp/initramfs.img

# ── Stage 3: Final Bluefin live image ────────────────────────────────────────
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Set to "dev" to pull the tuna-installer dev build (continuous-dev release)
# instead of the stable continuous build.
ARG INSTALLER_CHANNEL=stable
ENV INSTALLER_CHANNEL=${INSTALLER_CHANNEL}

# DEBUG=1 builds a debug ISO (installer only, SSH enabled).
ARG DEBUG=0
ENV DEBUG=${DEBUG}

# Filesystem for the installed system: btrfs (Bluefin stable) or xfs (Bluefin LTS).
# Override via: --build-arg FILESYSTEM=xfs
ARG FILESYSTEM=btrfs

# Install systemd-boot for the live ISO ESP (Bluefin ships GRUB2 for the
# installed system, but the live ISO needs a UEFI bootloader on the ESP image).
# systemd-boot-unsigned is the Fedora package; use rpm-ostree to layer it.
RUN rpm-ostree install --apply-live --allow-inactive systemd-boot-unsigned \
    && rm -rf /var/cache/rpm-ostree

# Replace the OCI-mode initramfs with the dmsquash-live initramfs from stage 2
COPY --from=initramfs-builder /tmp/initramfs.img /tmp/initramfs.img
RUN kernel=$(ls /usr/lib/modules | sort -V | tail -1) && \
    mv /tmp/initramfs.img "/usr/lib/modules/${kernel}/initramfs.img" && \
    echo "Replaced initramfs for kernel ${kernel}"

# ── Flatpak install layer ─────────────────────────────────────────────────────
COPY src/flatpaks /tmp/flatpaks-list
RUN --mount=type=bind,source=src,target=/src \
    --mount=type=cache,target=/var/cache/flatpak-dl,id=bluefin-flatpak \
    /src/install-flatpaks.sh

# ── Live-environment configure layer ─────────────────────────────────────────
COPY src/ /tmp/src/
RUN chmod +x /tmp/src/configure-live.sh && /tmp/src/configure-live.sh

ARG BASE_IMAGE
ARG FILESYSTEM
# Patch installer configs to reference the actual base image + filesystem for this variant.
RUN sed -i "s|ghcr.io/ublue-os/bluefin:stable|${BASE_IMAGE}|g" \
        /etc/bootc-installer/images.json \
        /etc/bootc-installer/recipe.json && \
    sed -i 's|"filesystem": "btrfs"|"filesystem": "${FILESYSTEM}"|g' \
        /etc/bootc-installer/images.json
