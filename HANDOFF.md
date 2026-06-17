# Bluefin bootc-ISO — Handoff

This document captures the current state of the Bluefin bootc-ISO effort for
another agent or maintainer to pick up, including the architectural differences
from dakota-iso (which works) and the remaining blocker.

## What this branch does

PR #61 (`feat/bluefin-bootc-iso`) adds a full ISO builder for Bluefin and
Bluefin LTS using the bootc-installer Flatpak (fisherman) with an ostree
backend.  The ISO is live-bootable, supports LUKS-encrypted installation via
fisherman, and is built in CI via GitHub Actions.

Dakota-ISO exists as a working reference: same toolchain (fisherman,
bootc-installer), same VM-based LUKS E2E test, same QEMU/KVM harness.
The differences are the root cause of the remaining issues.

## Architectural comparison: bluefin-iso vs dakota-iso

### 1. Image backend (UNCHANGEABLE)

| Aspect | Dakota-ISO | Bluefin-ISO |
|--------|------------|-------------|
| Base image | `ghcr.io/projectbluefin/dakota:latest` | `ghcr.io/ublue-os/bluefin:stable` / `...bluefin:lts` |
| Backend | composefs-native | ostree |
| Installed bootloader | systemd-boot | GRUB2 |
| `images.json` `composefs` | `true` | absent |
| `images.json` `needs_user_creation` | `false` | `true` |
| Filesystem | btrfs | btrfs (bluefin), xfs (bluefin-lts) |

Bluefin IS ostree — this cannot change.  All the memory and deployment
differences flow from this.

### 2. Install flow (CURRENT / TRIED)

Dakota uses `"image": "containers-storage:..."` in the fisherman recipe with
`composeFsBackend: true`.  Fisherman's composefs path:
1. Exports the image to an OCI layout via skopeo
2. Runs `podman --root <target> --storage-driver overlay --tmpfs /var/tmp ... oci:<path> bootc install --composefs-backend ...`
3. Works reliably at 8 GB VM RAM

Bluefin has tried several approaches:

| Approach | Result | Why |
|----------|--------|-----|
| `containers-storage:` recipe + VFS (original) | OOM | VFS copies every layer |
| Registry pull + VFS (be4f757) | OOM | Same VFS issue |
| Registry + overlay redirect + OCI layout (1b70f55..266b4fb) | OOM at podman run | Podman container setup ate 14.9 GB virtual |
| Empty image → bootcDirect (58c8ed2) | `bootc install` fails | Needs `--source-imgref` |
| bootcDirect + `--source-imgref docker://` (625ab3b) | untested | Would require network pull (offline VM) |
| bootcDirect + `--source-imgref containers-storage:` (24d15db) | **PENDING CI** | Most promising — no podman, no network |

### 3. Justfile recipe differences (luks-install-qemu)

```json
// Dakota recipe (WORKS):
{"image": "containers-storage:ghcr.io/projectbluefin/dakota:latest",
 "composeFsBackend": true,
 "bootloader": "systemd"}

// Bluefin recipe (CURRENT — awaiting CI):
{"image": "",
 "targetImgref": "ghcr.io/ublue-os/bluefin:stable",
 "composeFsBackend": false,
 "bootloader": "grub2"}
```

### 4. QEMU VM RAM

| | Dakota | Bluefin (currently) |
|---|---|---|
| Live ISO QEMU | 8 GB | 8 GB (was bumped to 12 GB, reverted) |
| Installed disk QEMU | 8 GB | 8 GB |
| Second disk (cs-disk) | No | Removed |

Dakota passes at 8 GB.  Bluefin's ostree deployment needs more headroom.
12 GB has been tested but not with the `containers-storage:` transport +
bootcDirect approach.

### 5. Fisherman fork

Bluefin needs a forked fisherman
(`projectbluefin/fisherman#fix/overlay-driver-for-ostree-bootc-install`)
because the upstream tuna-os/fisherman doesn't support the `--source-imgref`
flag for the direct (bootcDirect) mode.  The fork adds:

1. `BuildBootcArgs` emits `--source-imgref containers-storage:<ref>` for
   direct-mode installs (when SourceImgref is empty, TargetImgref is set).
2. `bareImageRef()` is called on target-imgref to strip transport prefixes.
3. The `selectStorageDriver` composefs guard is removed (unused in direct
   mode but needed for the container-mode fallback).

If the `containers-storage:` transport + bootcDirect approach works, these
changes should be upstreamed to tuna-os/fisherman and the forked build step
removed from CI.

## Current status

**Last CI run:** `27685994836` (in progress at time of writing) with
sha=`417f61d` (ISO) + fisherman `24d15db` (containers-storage transport).

**Previous failure chain:**

| CI Run | ISO Commit | Fisherman Commit | Failure |
|--------|-----------|-----------------|---------|
| 27684346872 | e4a6039 | d5c3b3e | `Unknown transport 'ostree-unverified-registry'` |
| 27682666045 | 94e2473 | d5c3b3e | `Either --source-imgref must be defined...` |
| 27681019431 | ba3ec5f | d5c3b3e | Same as above |
| 27679316314 | 58c8ed2 | d5c3b3e | Same as above |
| 27677273567 | 50df7d8 | 266b4fb | OOM (12 GB, podman run) |
| 27674960446 | 136ae7d | 266b4fb | OOM (10 GB, podman run) |
| 27673343778 | a9e081b | 266b4fb | OOM (8 GB, podman run) |
| 27670315536 | 8dec7d5 | 266b4fb | OOM (8 GB, podman pull) |

## Files changed

### `projectbluefin/iso` (PR #61, branch `feat/bluefin-bootc-iso`)

| File | Change |
|------|--------|
| `justfile` | Added `fisher_repo` var, rebuilt `luks-install-qemu` for bootcDirect, removed second disk and cs-setup.sh |
| `.github/workflows/test-luks-install.yml` | Added Go setup, fisherman clone, FISHER_REPO env var |
| `bluefin/` | payload_ref, images.json, recipe.json (new variant files) |
| `bluefin-lts/` | Same (bluefin-lts variant) |
| `Containerfile` | 3-stage ISO build (Bluefin + Debian initramfs + final) |
| `src/` | configure-live.sh, build-iso.sh, dracut module, branding assets |

### `projectbluefin/fisherman` (branch `fix/overlay-driver-for-ostree-bootc-install`)

| File | Change |
|------|--------|
| `internal/install/bootc.go` | `BuildBootcArgs`: emits `--source-imgref containers-storage:` for direct mode; `bareImageRef` on target-imgref |
| `internal/install/storage_driver.go` | Removed composefs-only guard from `selectStorageDriver`; removed btrfs from unsafeFS list |
| `internal/install/bootc_test.go` | New tests for direct-mode args, OCI export guards |
| `internal/install/storage_driver_test.go` | Updated for new `selectStorageDriver` sig |
| `internal/install/storage_driver_loopback_test.go` | Same |

## Open questions

1. **Does `--source-imgref containers-storage:ghcr.io/ublue-os/bluefin:stable` work** with bootcDirect on the live ISO?  The image IS embedded in the ISO's `/usr/lib/containers/storage` (additionalimagestores), and the driver format is overlay (not VFS).  This is the current CI run.

2. **Is 8 GB enough for ostree bootcDirect?**  If bootcDirect avoids podman's overhead (no container runtime), 8 GB should be sufficient.  If not, bump to 12 GB.

3. **Should the container-mode overlay/OCI patches be dropped?**  If bootcDirect works, commits `1b70f55` through `fe42607` in the fisherman fork are dead code.  The branch should be rebased to only include the direct-mode changes + the test additions.

4. **bluefin-lts fails with a dracut build error** in the Containerfile (kernel module version mismatch on the LTS kernel).  Unrelated to the LUKS test changes.
