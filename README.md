# Bluefin ISO Builder

This repository builds Bluefin ISOs using Anaconda and [Titanoboa](https://github.com/ublue-os/titanoboa)

## Overview

Workflows and configuration files needed to build bootable Bluefin ISOs for installation.

- Pre-configured Anaconda installer
- System flatpaks
- Custom branding and configuration
- Secure boot key enrollment

![ISO go nomnom](https://github.com/user-attachments/assets/2feeb772-713f-40b3-81e8-3f93b157fa13)

## ⚠️ LTS ISO Status: DISABLED

**LTS (non-HWE) ISOs are currently broken.** Anaconda does not work correctly on
the LTS base image. The `build-iso-lts.yml` workflow has no schedule and will not
fire automatically. Working LTS ISOs remain in the production bucket from before
this breakage and must not be overwritten.

**Do not** run `promote-iso.yml` with `variant: lts` or `variant: all` — both
patterns match `*-lts-*.iso*` filenames and would overwrite production ISOs.

Only `variant: stable` promotion is safe until LTS is fixed.

## Workflow Structure

The ISO build system consists of independent, focused workflows:

```
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│  build-iso-lts      │  │  build-iso-lts-hwe  │  │  build-iso-stable   │
│  (DISABLED)         │  │                     │  │                     │
│ ✓ workflow_dispatch │  │ ✓ workflow_dispatch │  │ ✓ workflow_dispatch │
│ ✗ no schedule       │  │ ✓ schedule (cron)   │  │ ✓ schedule (cron)   │
│                     │  │                     │  │                     │
│ Builds: LTS ISOs    │  │ Builds: LTS-HWE ISOs│  │ Builds: Stable ISOs │
│ - amd64 × main      │  │ - amd64 × main      │  │ - amd64 × main      │
│ - amd64 × gdx       │  │ - arm64 × main      │  │ - amd64 × nvidia-open│
│ - arm64 × main      │  │                     │  │                     │
│ - arm64 × gdx       │  │                     │  │                     │
└─────────┬───────────┘  └─────────┬───────────┘  └─────────┬───────────┘
          │                        │                        │
          └────────────────────────┼────────────────────────┘
                                   │
                          ┌────────▼────────┐
                          │  calls reusable │
                          │    workflow     │
                          └─────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              build-iso-lts-hwe-testing                       │
│           "Build LTS-HWE Testing ISOs"                       │
│                                                              │
│ ✓ workflow_dispatch                                          │
│ ✓ schedule (weekly — every Monday)                          │
│                                                              │
│ ONLY authorized workflow for lts-hwe-testing tags           │
│ Builds: 2 testing ISOs                                       │
│ ├─► amd64 × main (image_tag: lts-hwe-testing)              │
│ └─► arm64 × main (image_tag: lts-hwe-testing)              │
└─────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────┐
│                    build-iso-all                             │
│                   "Build All ISOs"                           │
│                                                              │
│ ✓ workflow_dispatch + schedule (monthly cron)               │
│                                                              │
│ Calls reusable workflow directly for each variant:          │
│ ├─► stable  (image_tag: stable)                             │
│ ├─► lts     (image_tag: lts)                                │
│ └─► lts-hwe (image_tag: lts-hwe)                           │
└─────────────────────────────────────────────────────────────┘
```

### Key Features
- **Strict ISO Scoping:** Each workflow builds ONLY its designated ISOs — no cross-contamination
  - `build-iso-lts.yml` → **LTS ISOs only** — currently DISABLED (Anaconda broken on LTS)
  - `build-iso-lts-hwe.yml` → **LTS-HWE ISOs only**
  - `build-iso-stable.yml` → **Stable ISOs only**
- **Independent Execution:** Each workflow can run independently
- **Flexible Upload:** Control artifact and R2 uploads per execution
- **Testing tags:** LTS and LTS-HWE callers accept `image_tag` input to select `-testing` variants
- **Monthly schedule:** Stable and LTS-HWE run at 2am UTC on the 1st of every month

## ISO Variants

The following ISO variants are built:

### Standard Releases
- **Stable** - Current stable release

### LTS Releases
- **LTS** - Long-term support based on CentOS Stream
- **LTS-HWE** - LTS with hardware enablement kernel

Each variant supports multiple flavors:
- `main` - Standard Bluefin
- `nvidia-open` - With NVIDIA open drivers (Stable only)
- `gdx` - Bluefin DX for developers (LTS only)

## Building ISOs

ISOs are built automatically via GitHub Actions workflows. Each variant has its own dedicated workflow that builds **only its specific ISOs**.

### Workflow Separation (Important!)

Each workflow is **strictly scoped** to build only its designated ISO variant:

| Workflow File | Builds | Does NOT Build |
|---------------|--------|----------------|
| `build-iso-lts.yml` | **4 LTS ISOs only** (DISABLED — no schedule)<br/>- amd64 × main<br/>- amd64 × gdx<br/>- arm64 × main<br/>- arm64 × gdx | ❌ Stable<br/>❌ LTS-HWE |
| `build-iso-lts-hwe.yml` | **2 LTS-HWE ISOs only** (production tags)<br/>- amd64 × main<br/>- arm64 × main | ❌ Stable<br/>❌ LTS<br/>❌ Testing tags |
| `build-iso-lts-hwe-testing.yml` | **2 LTS-HWE testing ISOs only** (weekly schedule)<br/>- amd64 × main (lts-hwe-testing)<br/>- arm64 × main (lts-hwe-testing) | ❌ Stable<br/>❌ Production tags |
| `build-iso-stable.yml` | **2 Stable ISOs only**<br/>- amd64 × main<br/>- amd64 × nvidia-open | ❌ LTS<br/>❌ LTS-HWE |
| `build-iso-all.yml` | All 8 production ISOs (calls reusable workflow directly) | ❌ Testing tags |

This strict separation ensures:
- ✅ Predictable builds: You know exactly which ISOs each workflow produces
- ✅ Faster iterations: Build only the variants you need
- ✅ Easier debugging: Issues are isolated to specific variants
- ✅ Resource efficiency: No unnecessary builds

### Manual Build
Trigger individual workflow dispatches for specific variants:
1. Go to Actions
2. Select a workflow:
   - "Build LTS ISOs" - for LTS variant
   - "Build LTS-HWE ISOs" - for LTS-HWE variant
   - "Build Stable ISOs" - for Stable variant
   - "Build All ISOs" - to build all variants
3. Click "Run workflow"
4. Choose upload options:
   - `upload_artifacts` - Upload ISOs as job artifacts (default: false)
   - `upload_r2` - Upload ISOs to CloudFlare R2 (default: true)

### Automatic Build
ISOs are built automatically:
- **Monthly schedule:** Stable and LTS-HWE run at 2am UTC on the 1st of every month
- **LTS:** No automatic schedule — see LTS disabled warning above
- **On changes:** When ISO configuration files are modified (via pull requests)

## Repository Structure

```
.
├── .github/workflows/
│   ├── build-iso-stable.yml             # Caller: Stable ISOs
│   ├── build-iso-lts.yml                # Caller: LTS ISOs (DISABLED)
│   ├── build-iso-lts-hwe.yml            # Caller: LTS-HWE ISOs
│   ├── build-iso-all.yml                # Orchestrator (workflow_dispatch only)
│   ├── reusable-build-iso-anaconda.yml  # Core build logic
│   ├── promote-iso.yml                  # Promote testing → production
│   ├── pull-request.yml                 # PR check builds (no upload)
│   └── validate-renovate.yml            # Validate Renovate config
├── iso_files/
│   ├── configure_iso_anaconda.sh        # Hook script for Stable ISOs
│   └── configure_lts_iso_anaconda.sh    # Hook script for LTS/LTS-HWE ISOs
├── hack/
│   └── local-iso-build.sh               # Local development build script
├── just/
│   ├── bluefin-apps.just                # Application management recipes
│   └── bluefin-system.just              # System management recipes
├── Justfile                             # Build automation
└── AGENTS.md                            # Agent instructions
```

## Configuration Files

### ISO Configuration Scripts
- `iso_files/configure_iso_anaconda.sh` - Configures the live environment and Anaconda installer for Stable releases
- `iso_files/configure_lts_iso_anaconda.sh` - Configures the live environment and Anaconda installer for LTS/LTS-HWE releases

### Flatpak Lists
Flatpaks are **not stored in this repo**. The build workflow clones
[projectbluefin/common](https://github.com/projectbluefin/common) at build time
and parses all `*system-flatpaks.Brewfile` files to generate the installer list.

For downstream forks, update the git clone URL in the "Generate titanoboa-compatible
file list" step of `reusable-build-iso-anaconda.yml`.

## Development

### Prerequisites
- Just command runner
- Podman or Docker
- Pre-commit

### Validation
```bash
# Validate all files
pre-commit run --all-files

# Check Just syntax
just check

# Fix formatting
just fix
```

### Local ISO Build
```bash
# Build an ISO locally
just build-iso bluefin stable main

# Build using GHCR image
just build-iso-ghcr bluefin stable main
```

## Output

Built ISOs are uploaded to:
- CloudFlare R2 `testing` bucket (for automatic builds)
- GitHub Actions artifacts (when `upload_artifacts: true`)
- GitHub prereleases — torrent files are generated for each ISO and attached
  to a prerelease (`YY.MM[.N]`) automatically after every successful build

ISO naming format: `{image-name}-{version}-{arch}.iso`

Example: `bluefin-stable-x86_64.iso`

## ISO Release Pipeline

The repository uses a two-stage release pipeline with testing and production buckets:

```
┌─────────────────────────────────────────────────────────────┐
│                    ISO Build Workflows                       │
│              (build-iso-lts, stable, lts-hwe)                │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │    Testing    │
                    │    Bucket     │  ← Automatic builds
                    │   (testing)   │
                    └───────┬───────┘
                            │
                            │  Manual promotion
                            │  with variant selection
                            ▼
                ┌───────────────────────┐
                │   Promote ISOs to     │
                │   Production Workflow │
                └───────────┬───────────┘
                            │
                            ▼
                     ┌───────────────┐
                     │  Production   │
                     │    Bucket     │  ← Controlled release
                     │   (bluefin)   │
                     └───────────────┘
```

### Promoting ISOs to Production

The `promote-iso.yml` workflow allows controlled promotion of ISOs from testing to production.

#### When to Promote

- After verifying ISOs in the testing bucket
- When ready to release specific variants to users
- Before announcing new ISO availability

#### Promotion Workflow Steps

**Step 1: Preview Changes (Dry Run)**

1. Navigate to **Actions → Promote ISOs to Production**
2. Click **"Run workflow"**
3. Configure inputs:
   - **variant**: Select which ISOs to promote:
      - `stable` - Promotes Stable ISOs only
      - `lts` - Promotes LTS, LTS-HWE, and GDX ISOs only (currently unsafe — see LTS warning)
      - `lts-hwe` - Promotes LTS-HWE ISOs only (excludes testing ISOs)
   - **dry_run**: ✅ Keep checked (default: `true`)
4. Click **"Run workflow"**
5. Review the workflow output to see what files would be promoted

**Step 2: Execute Promotion**

1. After verifying the dry run output looks correct
2. Run the workflow again with same settings
3. Configure inputs:
   - **variant**: Same selection as dry run
   - **dry_run**: ❌ Uncheck (set to `false`)
4. Click **"Run workflow"**
5. ISOs will be copied from `testing` to `prodtest` bucket
6. Verify the promotion in the workflow output

#### Variant Selection Details

> ⚠️ **LTS is currently broken.** Do NOT promote with `variant: lts` or `variant: all`
> — both patterns match `*-lts-*.iso*` files and will overwrite working production
> LTS ISOs with broken builds. Only `variant: stable` is safe.

| Variant | ISOs Promoted | Use Case |
|---------|--------------|----------|
| **stable** | • Stable ISOs (`*-stable-*.iso*`) | Regular stable release cycle |
| **lts** | • LTS ISOs (`*-lts-*.iso*`)<br/>• LTS-HWE ISOs (`*-lts-hwe-*.iso*`)<br/>• GDX ISOs (`*-dx-lts-*.iso*`) | LTS release cycle (currently unsafe — see above) |
| **lts-hwe** | • LTS-HWE ISOs (`*-lts-hwe-*.iso*`, excludes testing) | LTS-HWE-only release |

#### Important Notes

- **Dry run is enabled by default** - Always preview before promoting
- **rclone sync is used** - Files in testing will mirror to production:
  - New files are copied
  - Updated files are replaced
  - Files not in testing (matching the filter) are removed from production
- **Selective promotion** - Promote stable and LTS independently
- **Checksums included** - `.iso-CHECKSUM` files are automatically included

#### Example Workflow

```bash
# Scenario: Releasing new Stable ISOs

# 1. Verify ISOs built successfully in testing bucket
# 2. Run promotion workflow:
#    - variant: stable
#    - dry_run: true
# 3. Review output - confirm Stable ISOs will be promoted
# 4. Run again:
#    - variant: stable
#    - dry_run: false
# 5. ISOs are now in production bucket
# 6. Announce availability to users
```

## Contributing

Contributions are welcome! Please ensure:
1. Pre-commit checks pass
2. Just syntax is valid
3. Flatpak lists are properly validated
4. Follow conventional commits

## License

See main [Bluefin repository](https://github.com/ublue-os/bluefin) for license information.

## Related Projects

- [Bluefin](https://github.com/ublue-os/bluefin) - Main Bluefin image repository
- [Bluefin LTS](https://github.com/ublue-os/bluefin-lts) - Long-term support variant
- [Bluefin Documentation](https://github.com/ublue-os/bluefin-docs) - User documentation
- [Titanoboa](https://github.com/ublue-os/titanoboa) - ISO builder tool
