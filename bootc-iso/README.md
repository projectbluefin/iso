# bootc-iso: experimental bootc-installer ISO builder

This directory resurrects the bootc-installer ISO builder originally merged in
[PR #61](https://github.com/projectbluefin/iso/pull/61) (by @hanthor) and
reverted in [PR #66](https://github.com/projectbluefin/iso/pull/66). It is
fully self-contained: nothing here touches the Anaconda/titanoboa build system
at the repository root, and its CI workflows run on `workflow_dispatch` only:

- `.github/workflows/test-luks-install-bootc.yml` — LUKS install E2E in QEMU.
- `.github/workflows/build-iso-bootc-experimental.yml` — builds the
  experimental ISOs and uploads them as workflow artifacts named with an
  explicit `-experimental-bootc` suffix
  (e.g. `bluefin-lts-experimental-bootc-x86_64.iso`). These are deliberately
  NOT wired into the scheduled/production publish workflows or releases —
  artifacts only, clearly labeled, so the fisherman/bootcDirect path can be
  compared against the Anaconda ISOs for a while.

## What this is

A live-ISO builder where the installer is **fisherman** (the bootc-installer
Flatpak) performing `bootcDirect` installs from an embedded
containers-storage store:

- `justfile` — `iso-sd-boot <target>` builds the ISO; `luks-test-qemu <target>`
  runs the LUKS-encrypted install end-to-end in QEMU (also the CI entry point).
- `Containerfile` — 3-stage build of the live environment (base image +
  live-session configuration + fisherman installer).
- `Containerfile.builder` — Debian-based ISO assembly container
  (systemd-boot + dmsquash-live, via `src/build-iso.sh`).
- `bluefin/`, `bluefin-lts/` — per-variant config (`payload_ref` with the base
  image reference).
- `src/` — live-session configuration (`configure-live.sh`), ISO assembly
  (`build-iso.sh`), dracut module (`95bluefin-isofile`), branding, LUKS test
  helpers.
- `scripts/configure_podman_storage.sh` — CI helper choosing a podman storage
  driver for the runner (was `.github/scripts/` in #61).
- `HANDOFF.md` — detailed engineering handoff notes from the original effort.

## Why it was reverted (maintainer-confirmed)

1. **ISO size blowup — no dedupe between live rootfs and embedded container
   image.** The ISO carries the OS twice: once as the live squashfs rootfs and
   once as the payload image inside containers-storage. With the `vfs` storage
   driver the store is flat copies (no layer sharing at all). Switching the
   embedded store to the `overlay` driver fought with `ostree`-based
   `bootc install`; that was originally patched in the fisherman fork branch
   `projectbluefin/fisherman` @ `fix/overlay-driver-for-ostree-bootc-install`.
   **Update:** upstream fisherman `main` now natively supports direct-mode
   `bootc install --source-imgref containers-storage:...` (the same mechanism
   bootc-image-builder uses), so the CI workflow builds fisherman from `main`
   and no longer depends on the fork branch. The size/dedupe problem itself
   remains unsolved.
2. **bluefin-lts never built** due to a dracut failure — see
   [iso issue #63](https://github.com/projectbluefin/iso/issues/63).

## Intended fix direction

Move to a **single-copy design**: mount the live rootfs directly out of the
embedded container store (composefs/erofs), so the installer payload and the
live environment share one copy of the OS content instead of duplicating it in
a separate squashfs. That eliminates the dedupe problem structurally rather
than fighting the storage driver.

## Usage

```bash
cd bootc-iso
just iso-sd-boot bluefin        # build output/bluefin-live.iso
just luks-test-qemu bluefin     # LUKS install E2E in QEMU
```
