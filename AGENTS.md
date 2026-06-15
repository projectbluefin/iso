# Bluefin ISO Builder — Agent Instructions

This repo builds bootable Bluefin and Bluefin LTS live ISOs using the
[bootc-installer](https://github.com/projectbluefin/bootc-installer) Flatpak
and the ostree backend.

**Working model**: maintainers commit directly to `projectbluefin/iso`.

---

## Quick reference

```bash
just iso-sd-boot bluefin                              # full build
just debug=1 installer_channel=dev iso-sd-boot bluefin  # debug build with SSH
just boot-iso-serial bluefin                          # boot + validate via QEMU serial
just e2e bluefin                                      # build ISO + LUKS end-to-end test
```

---

## Repository structure

```
bluefin/payload_ref              → ghcr.io/ublue-os/bluefin:stable
bluefin-lts/payload_ref          → ghcr.io/ublue-os/bluefin-lts:latest
Containerfile                    → 3-stage build (bluefin-ref, initramfs-builder, final)
Containerfile.builder            → Debian ISO toolchain (xorriso, mksquashfs, etc.)
src/
  build-iso.sh                   → ISO assembly (BLUEFIN_LIVE label, El Torito EFI)
  configure-live.sh              → Live env setup (user, GDM, installer autostart, polkit)
  install-flatpaks.sh            → Flatpak pre-installation from Flathub
  flatpaks                       → List of Flatpak apps to pre-install
  luks-unlock.py                 → Automated LUKS passphrase injection via PTY
  show-screenshot.sh             → Terminal screenshot display (Kitty/iTerm2)
  dracut/95bluefin-isofile/      → Ventoy/file-backed ISO boot support
  etc/bootc-installer/
    images.json                  → Catalog lock: Bluefin, grub2, btrfs, ostree
    recipe.json                  → Branding, tour slides, install steps
  icons/hicolor/*/apps/          → Bluefin icon (PNG, all sizes)
  images/bluefin.png             → Installer tour image
justfile                         → Build + test automation
.github/workflows/
  build-iso.yml                  → Daily ISO builds (bluefin + bluefin-lts matrix)
  test-luks-install.yml          → Weekly LUKS E2E test
```

---

## Architecture

### Two-container build pipeline

1. **`<target>-installer`** — built by `Containerfile` (3 stages):
   - Stage 1 `bluefin-ref`: original Bluefin image (kernel modules)
   - Stage 2 `initramfs-builder`: Debian; builds dmsquash-live initramfs against Bluefin's kernel
   - Stage 3 (final): Bluefin + systemd-boot + rebuilt initramfs + Flatpaks + live-env config

2. **`<target>-iso-builder`** — built by `Containerfile.builder` (Debian with xorriso,
   mksquashfs, dosfstools, mtools). Runs `build-iso.sh`.

### ISO layout

```
EFI/efi.img              — FAT32 ESP: systemd-boot + kernel + initramfs
EFI/BOOT/BOOTX64.EFI    — EFI fallback path
LiveOS/squashfs.img      — squashfs of the full live rootfs (+ embedded OCI)
boot/grub/loopback.cfg   — Ventoy/GRUB loopback metadata
images/pxeboot/*         — kernel/initramfs copies for loopback ISO boot
```

### Live boot flow

```
UEFI → El Torito → FAT ESP → systemd-boot → kernel (initramfs: dmsquash-live)
dmsquash-live: scans for CDLABEL=BLUEFIN_LIVE → mounts ISO → squashfs → overlayfs
```

### Key differences from dakota-iso

| Aspect | dakota-iso | bluefin-bootc-iso |
|--------|-----------|-------------------|
| Base image | `ghcr.io/projectbluefin/dakota:latest` | `ghcr.io/ublue-os/bluefin:stable` |
| Filesystem backend | composefs | ostree |
| Installed bootloader | systemd-boot | grub2 |
| Live ISO bootloader | systemd-boot (from image) | systemd-boot (installed via rpm-ostree) |
| User creation | skipped (GNOME Initial Setup) | required (`needs_user_creation: true`) |
| Containerfile path | `dakota/Containerfile` | `Containerfile` (repo root) |
| src path | `dakota/src/` | `src/` |
| ISO label | `DAKOTA_LIVE` | `BLUEFIN_LIVE` |
| Live ready marker | `DAKOTA_LIVE_READY` | `BLUEFIN_LIVE_READY` |
| Build targets | `dakota`, `dakota-nvidia` | `bluefin`, `bluefin-lts` |
| VM name | `dakota-debug` | `bluefin-debug` |

### Installer configuration

- **`images.json`**: `bootloader: "grub2"`, `filesystem: "btrfs"`, no `composefs` key, `needs_user_creation: true`
- **`recipe.json`**: `composeFsBackend: false`, `bootloader: "grub2"`, `distro_name: "Bluefin"`, includes user creation step
- **LUKS recipe** (in justfile): `"composeFsBackend": false, "bootloader": "grub2"`

### VFS containers-storage

The squashfs embeds the Bluefin OCI image as VFS containers-storage for offline installation.
`/etc/containers/storage.conf` is set to `driver = "vfs"` by `configure-live.sh`.

---

## CI workflows

### `build-iso.yml`

- **Trigger**: push to main (matching paths), daily 03:00 UTC, workflow_dispatch
- **Matrix**: `[bluefin, bluefin-lts]` (fail-fast: false)
- **Build path**: `/var/iso-build`
- **Upload**: ISOs to Cloudflare R2 `testing` bucket as `<target>-live-latest.iso` + dated
- **Smoke test**: boots ISO in QEMU, waits for `BLUEFIN_LIVE_READY` on serial

### `test-luks-install.yml`

- **Trigger**: PRs to main, weekly Monday 04:00 UTC, workflow_dispatch
- **Matrix**: `installer_channel: [dev, stable]`
- **Flow**: build debug ISO → boot live QEMU → SSH fisherman LUKS install → reboot → unlock → verify boot
- **Screenshots**: saved to `ci-screenshots` branch, posted to PR comments

---

## LUKS E2E test

```bash
# Libvirt (interactive):
just debug=1 installer_channel=dev iso-sd-boot bluefin
just debug=1 boot-libvirt-debug bluefin
just luks-install bluefin
just luks-unlock bluefin

# QEMU (automated, CI-equivalent):
just debug=1 installer_channel=dev e2e bluefin
```

---

## Variants

| Variant | `payload_ref` | ISO output |
|---|---|---|
| `bluefin` | `ghcr.io/ublue-os/bluefin:stable` | `bluefin-live.iso` |
| `bluefin-lts` | `ghcr.io/ublue-os/bluefin-lts:latest` | `bluefin-lts-live.iso` |

To add a new variant:

```bash
mkdir my-variant
echo 'ghcr.io/ublue-os/my-image:latest' > my-variant/payload_ref
just iso-sd-boot my-variant
```
