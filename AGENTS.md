# Bluefin ISO Builder - Copilot Instructions

This document provides essential information for coding agents working with the Bluefin ISO repository to minimize exploration time and avoid common build failures.

## Repository Overview

**Bluefin ISO** is a dedicated repository for building bootable Bluefin installation ISOs using the Titanoboa ISO builder and Anaconda installer.

**Repository History**: This repository was created by extracting ISO-specific functionality from [ublue-os/bluefin](https://github.com/ublue-os/bluefin). It focuses exclusively on ISO generation, while the main repository handles base image building.

- **Type**: ISO build system for Bluefin operating system
- **Base**: Uses pre-built Bluefin container images from `ghcr.io/ublue-os` or `ghcr.io/projectbluefin`
- **Languages**: Bash scripts, YAML workflows, Just recipes
- **Build System**: Just (command runner), GitHub Actions, Titanoboa ISO builder
- **Output**: Bootable ISO images for Bluefin installation

## Repository Structure

### Root Directory Files
- `Justfile` - Build automation recipes for ISO generation (copied from main Bluefin repo)
- `.pre-commit-config.yaml` - Pre-commit hooks for validation
- `README.md` - Repository documentation and usage instructions
- `CONTRIBUTING.md` - Contribution guidelines
- `AGENTS.md` - This file - agent instructions
- `LICENSE` - Apache 2.0 license

### Key Directories
- `.github/workflows/` - GitHub Actions CI/CD pipelines for ISO builds
  - `build-iso-lts.yml` - Builds LTS ISOs (calls reusable workflow)
  - `reusable-build-iso-anaconda.yml` - Main ISO build workflow with matrix strategy
  - `validate-flatpaks.yml` - Validates flatpak list files
- `iso_files/` - ISO configuration and customization scripts
  - `configure_iso_anaconda.sh` - Configures standard ISOs (GTS, Stable, Latest, Beta)
  - `configure_lts_iso_anaconda.sh` - Configures LTS ISOs
  - `bluefin.repo` - Generated COPR repository file (not committed)
  - `README.md` - Notes about ISO files
- `flatpaks/` - Flatpak application lists to pre-install on ISOs
  - `system-flatpaks.list` - Core system applications
  - `system-flatpaks-dx.list` - Additional developer tools
  - `system-flatpaks-extra.list` - Extra optional applications
- `just/` - Additional Just recipes (copied from main Bluefin repo)
  - `bluefin-apps.just` - User-facing application management
  - `bluefin-system.just` - System management recipes

### ISO Variants and Architecture
- **ISO Variants**:
  - `gts` - Grand Touring Support (stable with extended support)
  - `stable` - Current stable release
  - `latest` - Latest features (may be beta/unstable)
  - `beta` - Pre-release testing builds
  - `lts` - Long-term support based on CentOS Stream
  - `lts-hwe` - LTS with hardware enablement kernel
- **Image Flavors**:
  - `main` - Standard Bluefin (all variants)
  - `nvidia-open` - With NVIDIA open drivers (GTS/Stable only)
  - `gdx` - Bluefin DX for developers (LTS only)
- **Platforms**: `amd64` (x86_64) and `arm64` (aarch64)
- **Base Container Images**: Pulled from `ghcr.io/ublue-os/bluefin*` or `ghcr.io/projectbluefin/bluefin*`

## Build Instructions

### Prerequisites
**Required tools for ISO builds:**

```bash
# Install Just command runner (REQUIRED for local ISO builds)
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

# Verify container runtime (REQUIRED for local ISO builds)
podman --version || docker --version

# Install pre-commit for validation
pip install pre-commit
```

**Note**: Local ISO builds are resource-intensive. Most development work can be tested via GitHub Actions workflows.

### Essential Commands

**Validation (ALWAYS run before committing changes):**
```bash
# 1. Validate syntax and formatting
pre-commit run --all-files

# 2. Check Just syntax (if Just is installed)
just check

# 3. Fix formatting issues automatically
just fix
```

**Local ISO builds (requires significant resources):**
```bash
# Build ISO from local container image
just build-iso bluefin gts main

# Build ISO from GHCR (recommended for testing)
just build-iso-ghcr bluefin stable main

# Run ISO in VM for testing
just run-iso bluefin gts main
```

**Utility commands:**
```bash
# Clean build artifacts
just clean

# List all available recipes
just --list

# Validate image/tag/flavor combinations
just validate bluefin gts main
```

### Critical ISO Build Notes

1. **ISO builds are EXTREMELY resource-intensive**:
   - Requires 50GB+ free disk space
   - Takes 30-60 minutes per ISO
   - Requires privileged container access
   - Better to test via GitHub Actions workflows

2. **Validation is mandatory**:
   - Always run `pre-commit run --all-files` before committing
   - Check Just syntax with `just check`
   - Validate flatpak lists via workflow

3. **Testing workflow changes**:
   - Use workflow dispatch for manual testing
   - Test in your fork first before opening PR
   - Monitor runner time and storage usage

4. **Flatpak validation**:
   - GitHub Actions automatically validates flatpak IDs
   - Ensure flatpaks exist on Flathub before adding

### Common Build Failures & Workarounds

**Pre-commit failures:**
```bash
# Fix end-of-file and trailing whitespace automatically
pre-commit run --all-files
```

**Just syntax errors:**
```bash
# Auto-fix formatting
just fix

# Manual validation
just check
```

**ISO build failures:**
- Ensure adequate disk space (50GB+ free)
- Clean previous builds: `just clean`
- Check container runtime: `podman system info`
- Verify base image exists and is pullable
- Check hook scripts for syntax errors

## Validation Pipeline

### Pre-commit Hooks (REQUIRED)
The repository uses mandatory pre-commit validation:
- `check-json` - Validates JSON syntax
- `check-toml` - Validates TOML syntax
- `check-yaml` - Validates YAML syntax (includes workflow files)
- `end-of-file-fixer` - Ensures files end with newline
- `trailing-whitespace` - Removes trailing whitespace

**Always run:** `pre-commit run --all-files` before committing changes.

### GitHub Actions Workflows
- `build-iso-lts.yml` - Builds LTS ISO images (calls reusable workflow)
- `reusable-build-iso-anaconda.yml` - Core ISO build logic with matrix strategy
  - Builds multiple platform/flavor/version combinations
  - Uses Titanoboa for ISO generation
  - Uploads to CloudFlare R2 or GitHub artifacts
- `validate-flatpaks.yml` - Validates flatpak list files against Flathub

**Workflow Architecture:**
- LTS workflow calls reusable workflow with specific variants
- Reusable workflow uses matrix strategy for parallel builds
- Supports workflow dispatch for manual builds
- Automatically builds on ISO configuration changes

### Manual Validation Steps
1. `pre-commit run --all-files` - Runs validation hooks
2. `just check` - Validates Just syntax (if Just is installed)
3. `just fix` - Auto-fixes formatting issues (if Just is installed)
4. Test via workflow dispatch rather than local builds when possible

## ISO Configuration

### ISO Configuration Scripts
Located in `iso_files/`, these scripts customize the live environment and Anaconda installer:

**`configure_iso_anaconda.sh`** (for GTS, Stable, Latest, Beta):
- Removes unnecessary packages from live CD
- Configures GNOME dock with installer shortcuts
- Disables sleep/suspend during installation
- Installs Anaconda and WebUI (for F42+)
- Creates Anaconda profile for Bluefin
- Configures automatic Flatpak installation
- Sets up secure boot key enrollment
- Customizes branding and artwork

**`configure_lts_iso_anaconda.sh`** (for LTS variants):
- Similar to standard configuration
- Uses CentOS-specific settings
- Different filesystem defaults (XFS instead of BTRFS)
- Modified partitioning scheme
- Different bootloader configuration

Key configuration differences:
- **Standard**: BTRFS filesystem, Fedora repos, secure boot enrollment
- **LTS**: XFS filesystem, CentOS repos, no secure boot (commented out)

### Flatpak Management
Flatpaks are pre-installed on the ISO for offline installation:

**`system-flatpaks.list`** - Core applications:
- Firefox, GNOME apps, utilities
- Included on all ISOs

**`system-flatpaks-dx.list`** - Developer tools:
- IDEs, development utilities
- Only included on DX variant ISOs

**`system-flatpaks-extra.list`** - Optional applications:
- Additional software
- Currently not used in ISO builds

**Adding Flatpaks:**
1. Add flatpak ID to appropriate list file (one per line)
2. Add comments with `#` for documentation
3. Run validation: GitHub Actions will check against Flathub
4. For LTS ISOs, Bazaar is automatically added by workflow

### Justfile ISO Recipes
The `Justfile` contains recipes for building ISOs (copied from main Bluefin repo):

**Key ISO recipes:**
- `build-iso [image] [tag] [flavor] [ghcr] [pipeline]` - Main ISO build command
- `build-iso-ghcr [image] [tag] [flavor]` - Build ISO from GHCR image
- `run-iso [image] [tag] [flavor]` - Test ISO in VM
- `validate [image] [tag] [flavor]` - Validate image/tag/flavor combination
- `image_name [image] [tag] [flavor]` - Get full image name
- `fedora_version [image] [tag] [flavor]` - Get Fedora version for image

**Note**: Most ISO recipes are for local development. GitHub Actions handles production builds.

## Configuration Files

### Key Configuration Locations
- `iso_files/` - ISO configuration and hook scripts
- `flatpaks/` - Flatpak application lists
- `.github/workflows/` - CI/CD pipeline definitions
- `just/` - Additional Just recipes (from main Bluefin repo)
- `Justfile` - Main build recipes (from main Bluefin repo)

### Linting/Build Configurations
- `.pre-commit-config.yaml` - Pre-commit hook configuration
- `Justfile` - ISO build recipe definitions
- `.gitignore` - Git ignore patterns for build artifacts

## Workflow Deep Dive

### Reusable ISO Build Workflow
The `reusable-build-iso-anaconda.yml` is the core workflow:

**Trigger conditions:**
- Workflow dispatch (manual) - choose variant to build
- Pull requests - on ISO configuration changes
- Workflow call - from other workflows (e.g., LTS)

**Build matrix:**
Dynamically generates matrix based on input:
- **Platforms**: amd64 (x86_64), arm64 (aarch64)
- **Flavors**: main, nvidia-open, gdx
- **Variants**: gts, stable, latest, beta, lts, lts-hwe

**Build process:**
1. Determine matrix based on variant selection
2. Setup build environment (maximize disk space)
3. Checkout repository and setup Just
4. Format image reference and determine kernel args
5. Add Bazaar to LTS flatpaks (if LTS variant)
6. Build ISO using Titanoboa action
7. Rename and checksum ISO
8. Upload to CloudFlare R2 or GitHub artifacts

**Key workflow features:**
- Parallel builds across matrix
- Separate runners for arm64 vs amd64
- Conditional Bazaar addition for LTS
- Different builder distro for LTS (centos) vs others (fedora)
- Conditional uploads based on event type

### LTS Workflow
The `build-iso-lts.yml` is a simple caller:
- Triggers on workflow dispatch or workflow call
- Calls reusable workflow with LTS-specific parameters
- Builds both main and gdx flavors for LTS

## Justfile Structure
The `Justfile` contains build automation (copied from main Bluefin):

**Key variables:**
- `repo_organization` - GitHub organization
- `images` - Image name mappings
- `flavors` - Flavor mappings (main, nvidia-open, gdx)
- `tags` - Tag/variant mappings (gts, stable, latest, beta, lts, lts-hwe)

**ISO-related recipes:**
- `build-iso` - Build ISO from local or GHCR image
- `build-iso-ghcr` - Wrapper for GHCR builds
- `run-iso` - Test ISO in VM
- Helper recipes for image name formatting and validation

**Note**: The Justfile is comprehensive and includes recipes from the main Bluefin repository. Not all recipes are relevant for ISO-only builds.

## Development Guidelines

### Making Changes
1. **ALWAYS validate first:** `pre-commit run --all-files && just check`
2. **Make minimal modifications** - focus on ISO configuration
3. **Test via workflow dispatch** rather than local builds when possible
4. **Focus on ISO configuration files** - `iso_files/` and `flatpaks/`
5. **Update documentation** if changing build process

### File Editing Best Practices
- **YAML workflow files**: Validate syntax with `pre-commit run check-yaml`
- **Flatpak lists**: Run validation via GitHub Actions workflow
- **Justfile**: Always run `just check` after modifications (if Just installed)
- **Shell scripts**: Follow existing patterns in `iso_files/`
- **Bash scripts**: Validate syntax with `bash -n script.sh`

### Common Modification Patterns
- **Adding flatpaks**: Edit `flatpaks/system-flatpaks*.list`, add one per line with comments
- **ISO configuration**: Modify scripts in `iso_files/` - test via workflow dispatch
- **Workflow changes**: Test in your fork first, use workflow dispatch
- **Build logic**: Edit `Justfile` carefully - ensure Just syntax is valid

### Testing ISO Changes
1. **Flatpak changes**: Automatic validation in PR via workflow
2. **ISO configuration**: Trigger workflow dispatch to build test ISO
3. **Workflow changes**: Test in fork before opening PR
4. **Local testing**: Use `just build-iso-ghcr` to avoid building base image

## Trust These Instructions

**The information in this document has been specifically tailored for the ISO repository.** Only search for additional information if:
- Instructions are incomplete for your specific task
- You encounter errors not covered in the workarounds section
- Need information about base Bluefin images (see main Bluefin repository)

This is a focused repository for ISO building. The main complexity is in the workflow orchestration and ISO configuration scripts.

## Key Differences: Standard vs LTS

Understanding the differences between Standard and LTS configurations is critical:

| Aspect | Standard (GTS/Stable/Latest/Beta) | LTS (lts/lts-hwe) |
|--------|-----------------------------------|-------------------|
| **Base OS** | Fedora Linux | CentOS Stream |
| **Filesystem** | BTRFS with compression | XFS |
| **Builder Distro** | Fedora | CentOS |
| **Secure Boot** | Enabled with key enrollment | Disabled (commented out) |
| **Bootloader** | `efi_dir = fedora` | `efi_dir = centos` |
| **Partitioning** | Standard Fedora scheme | Modified for CentOS |
| **Repositories** | Fedora repos | CentOS repos |
| **Special Flatpaks** | None | Bazaar (auto-added by workflow) |

## Best Practices for AI Agents

### DO:
- ✅ Make minimal, surgical changes
- ✅ Focus on ISO configuration and workflows
- ✅ Use conventional commits
- ✅ Run validation before committing
- ✅ Test via workflow dispatch when possible
- ✅ Use existing patterns and conventions
- ✅ Include AI attribution in commits

### DON'T:
- ❌ Modify base image building (wrong repo)
- ❌ Remove or edit working code unnecessarily
- ❌ Fix unrelated bugs or broken tests
- ❌ Build ISOs locally unless necessary
- ❌ Skip validation steps
- ❌ Use non-conventional commit messages
- ❌ Add new tools without justification

### Common Pitfalls:
- **Large builds:** ISOs are resource-intensive, prefer GitHub Actions
- **Pre-commit failures:** Run `pre-commit run --all-files` before commit
- **Just syntax errors:** Run `just check` and `just fix`
- **Workflow testing:** Test in fork first with workflow dispatch
- **Flatpak validation:** IDs are checked against Flathub automatically

## Quick Reference

### File Locations
- Workflows: `.github/workflows/`
- ISO configs: `iso_files/configure_*_anaconda.sh`
- Flatpaks: `flatpaks/*.list`
- Build recipes: `Justfile`, `just/*.just`
- Documentation: `README.md`, `AGENTS.md`, `CONTRIBUTING.md`

### Common Commands
```bash
# Validation
pre-commit run --all-files
just check
just fix

# Local ISO build (from GHCR)
just build-iso-ghcr bluefin stable main

# Test ISO in VM
just run-iso bluefin stable main

# Clean build artifacts
just clean
```

### Matrix Variants
- **lts:** amd64/arm64 × main/gdx
- **lts-hwe:** amd64/arm64 × main
- **gts:** amd64 × main/nvidia-open
- **stable:** amd64 × main/nvidia-open
- **all:** All combinations

## Related Resources

- **Main Bluefin repo:** https://github.com/ublue-os/bluefin
- **Bluefin LTS repo:** https://github.com/ublue-os/bluefin-lts
- **Bluefin docs:** https://github.com/ublue-os/bluefin-docs
- **Titanoboa:** https://github.com/ublue-os/titanoboa

## Other Rules Important to Maintainers

- Ensure [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/#specification) are used for every commit and PR title
- Always be surgical with minimal code changes
- Main Bluefin documentation exists at: https://github.com/ublue-os/bluefin-docs
- Main Bluefin repository: https://github.com/ublue-os/bluefin
- Bluefin LTS repository: https://github.com/ublue-os/bluefin-lts
- This repository focuses solely on ISO generation

## Commit Conventions (MANDATORY)

This repository uses [Conventional Commits](https://www.conventionalcommits.org/):

**Format:** `<type>(<scope>): <description>`

**Types:**
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `ci:` - CI/CD changes
- `chore:` - Maintenance tasks
- `refactor:` - Code refactoring

**Examples:**
- `feat(iso): add ARM64 support`
- `fix(flatpaks): correct invalid flatpak ID`
- `docs(readme): update build instructions`
- `ci(workflow): optimize matrix strategy`

**AI Attribution:**
AI agents must disclose what tool and model they are using in the "Assisted-by" commit footer:

```text
Assisted-by: [Model Name] via [Tool Name]
```

Example:

```text
feat(iso): add ARM64 support

Add ARM64 platform to build matrix

Assisted-by: Claude 3.5 Sonnet via GitHub Copilot
```

## Summary

This repository is focused exclusively on ISO generation for Bluefin. It uses pre-built container images and configures them for bootable installation media using Anaconda and Titanoboa. Development should focus on ISO configuration, workflows, and flatpak management. Always validate changes, use conventional commits, and prefer GitHub Actions for testing over local builds.
