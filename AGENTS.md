# Bluefin ISO Builder — Agent Instructions

This repo builds bootable Bluefin installation ISOs using
[Titanoboa](https://github.com/ublue-os/titanoboa) and the Anaconda installer.
It pulls pre-built container images from `ghcr.io/ublue-os`, wraps them in ISOs,
generates torrents, and manages a testing → production release pipeline via
CloudFlare R2.

**Working model**: maintainers commit directly to `projectbluefin/iso` — no fork
workflow. This repo is designed to be forked by other projects; see
"Adapting for Downstream Forks" below.

---

## ⚠️ LTS ISO Status: DISABLED — DO NOT TOUCH PRODUCTION

**LTS (non-HWE) ISOs are currently broken.** Anaconda does not work correctly on
the LTS base image. The `build-iso-lts.yml` workflow is intentionally left without
a schedule so it does not fire automatically.

**Production impact**: There are working LTS ISOs in the production R2 bucket from
before this breakage. They must not be overwritten.

### What agents and maintainers MUST NOT do:
- Do NOT re-enable the `build-iso-lts.yml` schedule
- Do NOT run `promote-iso.yml` with `variant: lts` or `variant: all` — both match
  `*-lts-*.iso*` files and would overwrite production with broken builds
- Do NOT trigger `build-iso-all.yml` expecting it to promote LTS to production
- Do NOT remove or alter the inline warning comments in `build-iso-lts.yml`

### What is safe:
- Building LTS ISOs with `upload_r2: false` (artifacts only) to test if the
  breakage has been resolved
- Running `promote-iso.yml` with `variant: stable` only

### When LTS is fixed:
1. Verify the build succeeds end-to-end with `upload_r2: false`
2. Inspect the ISO manually before any promotion
3. Add back the `schedule:` block to `build-iso-lts.yml`
4. Remove this warning from AGENTS.md and README.md

---

## Repository Structure

```
.github/workflows/
  build-iso-stable.yml             # Caller: 2 Stable ISOs (amd64 × main, nvidia-open)
  build-iso-lts.yml                # Caller: 4 LTS ISOs — DISABLED (see above)
  build-iso-lts-hwe.yml            # Caller: 2 LTS-HWE ISOs (amd64/arm64 × main)
  build-iso-all.yml                # Orchestrator: calls stable + lts-hwe in parallel
  reusable-build-iso-anaconda.yml  # Core build logic (matrix, build, prerelease)
  promote-iso.yml                  # Promotes testing → production R2 + GitHub release
  pull-request.yml                 # PR check: builds LTS + Stable, no upload
  validate-renovate.yml            # Validates Renovate config on PRs/pushes
iso_files/
  configure_iso_anaconda.sh        # Hook for Stable ISOs
  configure_lts_iso_anaconda.sh    # Hook for LTS and LTS-HWE ISOs
hack/
  local-iso-build.sh               # Local development ISO build script
just/
  bluefin-apps.just                # Application management recipes
  bluefin-system.just              # System management recipes
Justfile                           # Build automation (local-iso-bluefin, local-iso-lts, check, fix)
```

---

## Build Pipeline

```
Caller workflows (stable, lts-hwe)
        │
        ▼
reusable-build-iso-anaconda.yml
  ├─ determine-matrix job
  ├─ build job (parallel matrix)
  │    ├─ Fetch flatpaks from projectbluefin/common
  │    ├─ Run Titanoboa
  │    ├─ Generate torrent files
  │    └─ Upload to R2:testing
  └─ create-prerelease job
       └─ Creates GitHub prerelease with torrent files
        │
        ▼  (manual: promote-iso.yml)
R2_PROD:bluefin  +  GitHub Release (full, marked latest)
```

Promotion is always manual and always has a dry-run mode (enabled by default).

---

## Workflow Architecture

### Caller Workflows

All callers share the same structure:
- Triggers: `workflow_dispatch` + optional `schedule`
- Calls `reusable-build-iso-anaconda.yml` via `uses:`
- `secrets: inherit` — no `permissions:` block in caller
- Inputs: `image_version`, `image_tag`, `upload_artifacts`, `upload_r2`

**LTS and LTS-HWE** callers have an `image_tag` choice input for selecting
production vs testing image tags:
- `build-iso-lts.yml`: `lts` or `lts-testing`
- `build-iso-lts-hwe.yml`: `lts-hwe` or `lts-hwe-testing`

**Stable** hardcodes `image_tag: stable`. No testing tag variant exists for Stable.

**`build-iso-all.yml`** calls the reusable workflow directly (not the caller
workflows), hardcoding the correct tag for each variant. Known issues:
- Cron `"0 3 1 1"` is 4 fields; valid cron requires 5. Scheduled trigger does not
  fire — only `workflow_dispatch` works.
- The LTS job references `inputs.image_tag` which is not a defined input; it always
  resolves to `'lts'` (correct behavior, but latent bug).

### Reusable Workflow

Three jobs:

**1. `determine-matrix`** — sets the build matrix from `image_version`:

| `image_version` | ISOs | Platforms     | Flavors           |
|-----------------|------|---------------|-------------------|
| `stable`        | 2    | amd64         | main, nvidia-open |
| `lts`           | 4    | amd64, arm64  | main, gdx         |
| `lts-hwe`       | 2    | amd64, arm64  | main              |
| `all`           | 8    | all above     | all above         |

**2. `build`** — parallel matrix. Runner, hook script, and builder distro by variant:

| Variant       | Runner              | `builder-distro` | Hook script                      |
|---------------|---------------------|------------------|----------------------------------|
| stable        | ubuntu-24.04        | fedora           | configure_iso_anaconda.sh        |
| lts, lts-hwe  | ubuntu-24.04[-arm]  | centos           | configure_lts_iso_anaconda.sh    |

**3. `create-prerelease`** — runs after all build jobs succeed. Downloads torrent
files from R2:testing and creates a versioned GitHub prerelease (`YY.MM[.N]`).

### Image Reference

```yaml
env:
  IMAGE_REGISTRY: "ghcr.io/ublue-os"
  IMAGE_NAME: "bluefin"
```

Image names are resolved by the `just image_name` recipe. Full ref at build time:
`${IMAGE_REGISTRY}/${image_name}:${image_tag}`.

### Flatpak Sourcing

Flatpaks are **not stored in this repo**. The build job clones
`projectbluefin/common` at runtime and parses all `*system-flatpaks.Brewfile` files:

```bash
git clone https://github.com/projectbluefin/common.git common
find common -iname "*system-flatpaks.Brewfile" -exec cat '{}' ';' \
  | grep -v '#' | grep -F -e "flatpak" | sed 's/flatpak //' | tr -d '"'
```

---

## Promote Workflow

`promote-iso.yml` is manual-only (`workflow_dispatch`). Uses `rclone sync` to copy
from the testing bucket to the production bucket (`R2_PROD:bluefin`), then converts
the GitHub prerelease to a full release.

Inputs:
- `variant`: `stable`, `lts`, or `all`
- `release_tag`: specific tag to promote, or auto-detects latest prerelease
- `dry_run`: default `true` — always preview before running live

Filter patterns per variant:

| Variant  | Files matched                                                              |
|----------|----------------------------------------------------------------------------|
| `stable` | `*-stable-*.iso*`                                                         |
| `lts`    | `*-lts-*.iso*`, `*-lts-hwe-*.iso*`, `*-dx-lts-*.iso*`                   |
| `all`    | `*.iso`, `*.iso-CHECKSUM`, `*.iso.torrent`, `*.iso.torrent-CHECKSUM`      |

> ⚠️ Do NOT run with `variant: lts` or `variant: all` while LTS builds are broken.
> Both patterns match LTS filenames and will overwrite production ISOs.

---

## Required Secrets

| Secret                      | Used by                              |
|-----------------------------|--------------------------------------|
| `R2_ACCESS_KEY_ID_2025`     | Build workflows (testing bucket)     |
| `R2_SECRET_ACCESS_KEY_2025` | Build workflows (testing bucket)     |
| `R2_ENDPOINT_2025`          | Build workflows (testing bucket)     |
| `R2_ACCESS_KEY_PRODUCTION`  | promote-iso.yml (production bucket)  |
| `R2_SECRET_PRODUCTION`      | promote-iso.yml (production bucket)  |
| `R2_ENDPOINT_PRODUCTION`    | promote-iso.yml (production bucket)  |

R2 secrets are declared `required: false` in the reusable workflow — builds succeed
without them; only R2 upload fails.

---

## Local Development

```bash
# Local ISO build (wraps hack/local-iso-build.sh)
just local-iso-bluefin       # Fedora-based Stable ISO
just local-iso-lts           # LTS ISO (requires centos builder)

# Validation (always run before committing)
pre-commit run --all-files
just check

# Fix formatting
just fix

# Shell script syntax check
bash -n iso_files/configure_iso_anaconda.sh
```

---

## Standard vs LTS Differences

| Aspect         | Stable                       | LTS / LTS-HWE                           |
|----------------|------------------------------|-----------------------------------------|
| Base OS        | Fedora                       | CentOS Stream                           |
| Builder distro | `fedora`                     | `centos`                                |
| Hook script    | `configure_iso_anaconda.sh`  | `configure_lts_iso_anaconda.sh`         |
| Filesystem     | BTRFS                        | XFS                                     |
| Secure boot    | Enabled                      | Disabled (commented out in hook)        |
| EFI dir        | `fedora`                     | `centos`                                |
| Testing tag    | None                         | `-testing` suffix (`lts-testing`, etc.) |

---

## Adapting for Downstream Forks

To build ISOs for a different image (e.g., `ghcr.io/myorg/myimage`):

### 1. Image registry and name

In `reusable-build-iso-anaconda.yml`, update the top-level env:

```yaml
env:
  IMAGE_REGISTRY: "ghcr.io/myorg"
  IMAGE_NAME: "myimage"
```

### 2. Flatpak source

In the "Generate titanoboa-compatible file list" step, change the git clone URL to
your own config repo, or replace the step entirely with a local file read.

### 3. Variants and matrix

Edit the `determine-matrix` case statement. Each case outputs a JSON array of
`{platform, flavor, image_version}` objects. Add, remove, or rename variants to
match what your image actually builds and publishes.

### 4. Hook scripts

Copy and modify `iso_files/configure_iso_anaconda.sh` for your image. Update the
`hook-post-rootfs` value in the `Build ISO` step of the reusable workflow.

### 5. Storage buckets

The bucket names `testing` (build upload) and `bluefin` (production) are hardcoded
in the workflows. Update both `reusable-build-iso-anaconda.yml` and
`promote-iso.yml` to match your bucket names.

### 6. Promotion filters

Update the `determine filter pattern` step in `promote-iso.yml` so the `stable` and
`lts` patterns match your ISO naming scheme.

---

## Commit Conventions

Format: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `ci`, `chore`, `refactor`

Examples:
- `ci(workflow): fix LTS-HWE default image tag`
- `fix(iso): correct secure boot enrollment path`
- `docs(agents): update flatpak sourcing documentation`

AI attribution footer required on every commit:

```
Assisted-by: <Model> via <Tool>
```
