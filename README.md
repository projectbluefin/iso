# Bluefin Live ISO Builder

Builds bootable UEFI live ISOs for [Bluefin](https://github.com/ublue-os/bluefin) and [Bluefin LTS](https://github.com/ublue-os/bluefin-lts) using the [bootc-installer](https://github.com/projectbluefin/bootc-installer) Flatpak and the ostree backend.

## Overview

| Variant | Image | Download |
|---------|-------|----------|
| **Bluefin** | `ghcr.io/ublue-os/bluefin:stable` | [⬇ bluefin-live-latest.iso](https://projectbluefin.dev/bluefin-live-latest.iso) |
| **Bluefin LTS** | `ghcr.io/ublue-os/bluefin-lts:latest` | [⬇ bluefin-lts-live-latest.iso](https://projectbluefin.dev/bluefin-lts-live-latest.iso) |

The live environment boots to GDM with a full GNOME session and launches the Bluefin installer automatically. ISOs support offline installation via embedded OCI containers-storage.

## How it works

The build uses two Podman containers:

1. **`<target>-installer`** — a 3-stage container that pulls the Bluefin base image, builds a dmsquash-live initramfs (via Debian stage), installs Flatpaks, and configures the live environment.
2. **`<target>-iso-builder`** — a Debian-based toolchain container (xorriso, mksquashfs, dosfstools, mtools) that assembles the final ISO.

The ISO layout:
- **EFI/efi.img** — FAT32 ESP with systemd-boot, kernel, and initramfs
- **LiveOS/squashfs.img** — squashfs of the full live rootfs (with embedded OCI)
- **El Torito** UEFI entry pointing to the ESP image

At boot, `dmsquash-live` mounts the squashfs and creates an overlayfs so the live environment is fully writable.

## Requirements

| Tool | Notes |
|---|---|
| `podman` | Rootless works; needs `--cap-add sys_admin` for the live env build |
| `just` | Task runner |
| KVM + `qemu-system-x86_64` | For local boot testing |
| OVMF firmware | `edk2-ovmf` (Fedora) or `ovmf` (Debian/Ubuntu) |

## Building

```bash
# Clone the repo
git clone https://github.com/projectbluefin/iso
cd iso

# Build Bluefin ISO
just iso-sd-boot bluefin

# Build Bluefin LTS ISO
just iso-sd-boot bluefin-lts

# Override output directory
just output_dir=/var/data/iso-output iso-sd-boot bluefin
```

Output: `output/<target>-live.iso`

### Build stages

```bash
just container bluefin          # Build the live environment container
just iso-builder bluefin        # Build the ISO assembly toolchain container
just iso-sd-boot bluefin        # Full end-to-end build
```

### Debug builds (SSH enabled)

```bash
just debug=1 iso-sd-boot bluefin
# SSH: liveuser@<ip>  password: live
```

## Testing

```bash
# Boot ISO in QEMU serial console (headless)
just boot-iso-serial bluefin

# Boot in libvirt with SSH access
just debug=1 boot-libvirt-debug bluefin

# Full LUKS E2E test (build + install + reboot + unlock)
just debug=1 e2e bluefin
```

## Installer configuration

The installer is pre-configured for Bluefin. Configuration lives in `src/etc/bootc-installer/`:

| File | Purpose |
|---|---|
| `images.json` | Locks the image catalog to Bluefin (`grub2` bootloader, `btrfs` filesystem, ostree backend) |
| `recipe.json` | Sets distro branding, tour slides, and install steps |

## Repository structure

```
.
├── bluefin/                    # Bluefin variant (payload_ref)
├── bluefin-lts/                # Bluefin LTS variant (payload_ref)
├── Containerfile               # 3-stage live environment build
├── Containerfile.builder       # Debian ISO assembly toolchain
├── src/
│   ├── build-iso.sh            # ISO assembly script
│   ├── configure-live.sh       # Live environment setup
│   ├── install-flatpaks.sh     # Flatpak pre-installation
│   ├── flatpaks                # Flatpak app list
│   ├── luks-unlock.py          # LUKS passphrase automation
│   ├── show-screenshot.sh      # Terminal screenshot display
│   ├── dracut/                 # dmsquash-live initramfs modules
│   ├── etc/bootc-installer/    # Installer configs
│   ├── icons/                  # Bluefin icon theme
│   └── images/                 # Installer tour images
├── justfile                    # Build automation
└── .github/workflows/          # CI workflows
    ├── build-iso.yml           # Daily ISO builds
    └── test-luks-install.yml   # LUKS E2E validation
```

## Adding a new variant

Each variant is a directory containing a single file — `payload_ref` — with the OCI image reference:

```bash
mkdir my-variant
echo 'ghcr.io/ublue-os/my-image:latest' > my-variant/payload_ref
just iso-sd-boot my-variant
```

## CI

- **build-iso.yml**: Daily builds of Bluefin and Bluefin LTS ISOs at 03:00 UTC. Uploads to Cloudflare R2.
- **test-luks-install.yml**: Weekly LUKS encrypted install end-to-end test (Monday 04:00 UTC). Posts screenshots to PR comments.

## License

See main [Bluefin repository](https://github.com/ublue-os/bluefin) for license information.

## Related projects

- [Bluefin](https://github.com/ublue-os/bluefin) — Main Bluefin image repository
- [Bluefin LTS](https://github.com/ublue-os/bluefin-lts) — Long-term support variant
- [bootc-installer](https://github.com/projectbluefin/bootc-installer) — Installer Flatpak
