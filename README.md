# Bluefin ISO Builder

This repository builds Bluefin ISOs using Anaconda and [Titanoboa](https://github.com/ublue-os/titanoboa)

## Overview

Workflows and configuration files needed to build bootable Bluefin ISOs for installation.

- Pre-configured Anaconda installer
- System flatpaks
- Custom branding and configuration
- Secure boot key enrollment

![ISO go nomnom](https://github.com/user-attachments/assets/2feeb772-713f-40b3-81e8-3f93b157fa13)

## Workflow Structure

The ISO build system consists of independent, focused workflows that can be triggered individually or as a group:

```
┌──────────────────────────────────────────────────────────────┐
│                     Individual Workflows                      │
│                 (Can be triggered separately)                 │
└──────────────────────────────────────────────────────────────┘

┌─────────────────────┐  ┌─────────────────────┐
│  build-iso-lts      │  │  build-iso-lts-hwe  │
│                     │  │                     │
│ ✓ workflow_dispatch │  │ ✓ workflow_dispatch │
│ ✓ schedule (cron)   │  │ ✓ schedule (cron)   │
│ ✓ upload options    │  │ ✓ upload options    │
│                     │  │                     │
│ Builds: LTS ISOs    │  │ Builds: LTS-HWE ISOs│
│ - amd64 × main      │  │ - amd64 × main      │
│ - amd64 × gdx       │  │ - arm64 × main      │
│ - arm64 × main      │  │                     │
│ - arm64 × gdx       │  │                     │
└─────────┬───────────┘  └─────────┬───────────┘
          │                        │
          └────────┬───────────────┘
                   │
          ┌────────▼────────┐
          │  calls reusable │
          │    workflow     │
          └────────┬────────┘
                   │
┌─────────────────────┐  ┌─────────────────────┐
│  build-iso-gts      │  │  build-iso-stable   │
│                     │  │                     │
│ ✓ workflow_dispatch │  │ ✓ workflow_dispatch │
│ ✓ schedule (cron)   │  │ ✓ schedule (cron)   │
│ ✓ upload options    │  │ ✓ upload options    │
│                     │  │                     │
│ Builds: GTS ISOs    │  │ Builds: Stable ISOs │
│ - amd64 × main      │  │ - amd64 × main      │
│ - amd64 × nvidia-open│ │ - amd64 × nvidia-open│
└─────────┬───────────┘  └─────────┬───────────┘
          │                        │
          └────────┬───────────────┘
                   │
          ┌────────▼────────┐
          │  calls reusable │
          │    workflow     │
          └─────────────────┘

═══════════════════════════════════════════════════════════════

┌──────────────────────────────────────────────────────────────┐
│                   Orchestration Workflow                      │
│              (Calls all individual workflows)                 │
└──────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    build-iso-all                             │
│                   "Build All ISOs"                           │
│                                                              │
│ ✓ workflow_dispatch                                         │
│ ✓ schedule (cron)                                           │
│ ✓ upload options                                            │
│                                                              │
│ Orchestrates all 4 workflows in parallel:                   │
│ ├─► build-iso-lts                                           │
│ ├─► build-iso-lts-hwe                                       │
│ ├─► build-iso-gts                                           │
│ └─► build-iso-stable                                        │
└─────────────────────────────────────────────────────────────┘

Schedule: All workflows run at 2am UTC on the 1st of each month
```

### Key Features
- **Strict ISO Scoping:** Each workflow builds ONLY its designated ISOs - no cross-contamination
  - `build-iso-lts.yml` → **LTS ISOs only** (never builds GTS, Stable, or LTS-HWE)
  - `build-iso-lts-hwe.yml` → **LTS-HWE ISOs only** (never builds GTS, Stable, or LTS)
  - `build-iso-gts.yml` → **GTS ISOs only** (never builds LTS, LTS-HWE, or Stable)
  - `build-iso-stable.yml` → **Stable ISOs only** (never builds LTS, LTS-HWE, or GTS)
- **Independent Execution:** Each workflow can run independently without affecting others
- **Orchestration:** The "Build All ISOs" workflow calls all others in parallel
- **Flexible Upload:** Control artifact and R2 uploads per execution
- **Consistent Scheduling:** All workflows on same monthly schedule (cron: `0 2 1 * *`)

## ISO Variants

The following ISO variants are built:

### Standard Releases
- **GTS (Grand Touring Support)** - Stable release with extended support
- **Stable** - Current stable release
- **Latest** - Latest features and updates
- **Beta** - Pre-release testing builds

### LTS Releases
- **LTS** - Long-term support based on CentOS Stream
- **LTS-HWE** - LTS with hardware enablement kernel

Each variant supports multiple flavors:
- `main` - Standard Bluefin
- `nvidia-open` - With NVIDIA open drivers (GTS/Stable only)
- `gdx` - Bluefin DX for developers (LTS only)

## Building ISOs

ISOs are built automatically via GitHub Actions workflows. Each variant has its own dedicated workflow that builds **only its specific ISOs**.

### Workflow Separation (Important!)

Each workflow is **strictly scoped** to build only its designated ISO variant:

| Workflow File | Builds | Does NOT Build |
|---------------|--------|----------------|
| `build-iso-lts.yml` | **4 LTS ISOs only**<br/>- amd64 × main<br/>- amd64 × gdx<br/>- arm64 × main<br/>- arm64 × gdx | ❌ GTS<br/>❌ Stable<br/>❌ LTS-HWE |
| `build-iso-lts-hwe.yml` | **2 LTS-HWE ISOs only**<br/>- amd64 × main<br/>- arm64 × main | ❌ GTS<br/>❌ Stable<br/>❌ LTS |
| `build-iso-gts.yml` | **2 GTS ISOs only**<br/>- amd64 × main<br/>- amd64 × nvidia-open | ❌ LTS<br/>❌ LTS-HWE<br/>❌ Stable |
| `build-iso-stable.yml` | **2 Stable ISOs only**<br/>- amd64 × main<br/>- amd64 × nvidia-open | ❌ LTS<br/>❌ LTS-HWE<br/>❌ GTS |
| `build-iso-all.yml` | All 10 ISOs (calls all 4 workflows above) | N/A - orchestrator |

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
   - "Build GTS ISOs" - for GTS variant
   - "Build Stable ISOs" - for Stable variant
   - "Build All ISOs" - to build all variants
3. Click "Run workflow"
4. Choose upload options:
   - `upload_artifacts` - Upload ISOs as job artifacts (default: false)
   - `upload_r2` - Upload ISOs to CloudFlare R2 (default: true)

### Automatic Build
ISOs are built automatically:
- **Monthly schedule:** All workflows run at 2am UTC on the 1st of every month
- **On changes:** When ISO configuration files are modified (via pull requests)

## Repository Structure

```
.
├── .github/workflows/       # GitHub Actions workflows
│   ├── build-iso-lts.yml   # LTS ISO build workflow
│   ├── build-iso-lts-hwe.yml  # LTS-HWE ISO build workflow
│   ├── build-iso-gts.yml   # GTS ISO build workflow
│   ├── build-iso-stable.yml  # Stable ISO build workflow
│   ├── build-iso-all.yml   # Orchestrates all ISO builds
│   ├── reusable-build-iso-anaconda.yml  # Core reusable ISO build workflow
│   ├── validate-flatpaks.yml   # Validate Flatpak lists
│   └── validate-renovate.yml   # Validate Renovate config
├── iso_files/               # ISO configuration files
│   ├── configure_iso_anaconda.sh  # Standard ISO configuration
│   ├── configure_lts_iso_anaconda.sh  # LTS ISO configuration
│   └── bluefin.repo         # Generated COPR repository file
├── flatpaks/                # Flatpak application lists
│   ├── system-flatpaks.list  # Base system flatpaks
│   ├── system-flatpaks-dx.list  # Developer flatpaks
│   └── system-flatpaks-extra.list  # Extra flatpaks
├── just/                    # Just recipes for system management
│   ├── bluefin-apps.just   # Application management
│   └── bluefin-system.just # System management
├── Justfile                 # Main build recipes
└── AGENTS.md               # Copilot agent instructions

```

## Configuration Files

### ISO Configuration Scripts
- `iso_files/configure_iso_anaconda.sh` - Configures the live environment and Anaconda installer for standard releases
- `iso_files/configure_lts_iso_anaconda.sh` - Configures the live environment and Anaconda installer for LTS releases

### Flatpak Lists
Flatpaks to be pre-installed on the ISO:
- `flatpaks/system-flatpaks.list` - Core applications
- `flatpaks/system-flatpaks-dx.list` - Additional developer tools
- `flatpaks/system-flatpaks-extra.list` - Optional extra applications

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
just build-iso bluefin gts main

# Build using GHCR image
just build-iso-ghcr bluefin stable main
```

## Output

Built ISOs are uploaded to:
- CloudFlare R2 storage (for release builds)
- GitHub Actions artifacts (for testing/workflow dispatch builds)

ISO naming format: `{image-name}-{version}-{arch}.iso`

Example: `bluefin-gts-x86_64.iso`

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
