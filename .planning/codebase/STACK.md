# Technology Stack

**Analysis Date:** 2026-01-28

## Languages

**Primary:**
- Bash - Shell scripting for ISO configuration and build automation
  - Used in: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`, `hack/local-iso-build.sh`
  - All major build and configuration logic

**Secondary:**
- YAML - GitHub Actions workflow definitions
  - Used in: `.github/workflows/*.yml`
- Just - Build recipe DSL
  - Used in: `Justfile`, `just/*.just`

## Runtime

**Environment:**
- Linux (Ubuntu 24.04 for amd64, Ubuntu 24.04 ARM for arm64)
- GitHub Actions runners for CI/CD builds

**Container Runtime:**
- Podman (preferred) - `/usr/bin/podman`
- Docker (fallback) - `/usr/bin/docker`
- Auto-detection logic in `Justfile`

**Package Manager:**
- Just v1.x - Command runner for build automation
- DNF/RPM - Package installation within ISO configuration
- No traditional package.json/requirements.txt (shell-based project)

## Frameworks

**Core:**
- Titanoboa - ISO builder framework
  - Repository: `github.com/ublue-os/titanoboa`
  - Used via GitHub Action: `ublue-os/titanoboa@main`
  - Purpose: Converts container images to bootable ISOs
- Anaconda - Red Hat installer
  - Versions: `anaconda-live`, `anaconda-webui` (F42+)
  - Installed via DNF in ISO configuration scripts

**Testing:**
- Pre-commit v4.4.0 - Syntax validation hooks
  - Hooks: check-json, check-yaml, check-toml, end-of-file-fixer, trailing-whitespace

**Build/Dev:**
- Just - Build recipe runner (unstable features used: `--fmt`)
- Git - Version control and repository cloning
- Skopeo - Container image inspection
- Rclone - Cloud storage sync for ISO uploads

## Key Dependencies

**Critical:**
- Titanoboa - Core ISO building engine
  - Used in: `.github/workflows/reusable-build-iso-anaconda.yml`
- Just - Build automation and recipe execution
  - Config: `Justfile`, `just/*.just`
- Container images - Base OS images from `ghcr.io/ublue-os/bluefin*`
  - Variants: bluefin, bluefin-dx, bluefin-gdx

**Infrastructure:**
- GitHub Actions workflows - CI/CD orchestration
  - `actions/checkout@v5` - Repository checkout
  - `extractions/setup-just@v3` - Just installation
  - `actions/upload-artifact@v5` - Artifact uploads
  - `Homebrew/actions/setup-homebrew@master` - Homebrew setup
  - `ublue-os/remove-unwanted-software@v9` - Disk space optimization
  - `ublue-os/container-storage-action` - Container storage management
- Rclone - CloudFlare R2 uploads
  - Installed via: `brew install rclone`
- Git - Repository operations and branding clone
  - Clones: `github.com/projectbluefin/branding`, `github.com/projectbluefin/common`

**ISO Configuration:**
- DNF packages installed during build:
  - `anaconda-live` - Live installer
  - `anaconda-webui` - Web UI for installer (F42+, LTS via COPR)
  - `libblockdev-btrfs`, `libblockdev-lvm`, `libblockdev-dm` - Storage libraries
  - `firefox` - Browser for live environment
  - `openssh-server` - SSH server (LTS only)
- COPR repositories:
  - `jreilly/anaconda-webui` - Anaconda WebUI for LTS
  - `jreilly1821/anaconda-webui` - Alternative COPR for LTS

## Configuration

**Environment:**
- No .env files - uses GitHub Secrets for sensitive data
- Configuration via workflow inputs and Just variables
- Container registry: `ghcr.io/ublue-os` (configurable)

**Build:**
- `Justfile` - Main build configuration
  - Variables: `repo_organization`, `images`, `flavors`, `tags`
  - Container runtime detection (Podman/Docker)
  - ISO build recipes with validation
- `.pre-commit-config.yaml` - Pre-commit hooks for validation
- `.github/workflows/*.yml` - CI/CD pipeline definitions
  - Matrix-based builds for platform/flavor combinations
  - Conditional logic for LTS vs Stable variants

**ISO Variants:**
- `stable` - Fedora-based, BTRFS filesystem
- `lts` - CentOS-based, XFS filesystem
- `lts-hwe` - LTS with hardware enablement kernel

**Platforms:**
- `amd64` (x86_64) - Uses `ubuntu-24.04` runners
- `arm64` (aarch64) - Uses `ubuntu-24.04-arm` runners

## Platform Requirements

**Development:**
- Linux operating system
- Just command runner (for local builds)
- Podman or Docker container runtime
- 50GB+ free disk space (for ISO builds)
- Git for repository operations

**Production:**
- GitHub Actions runners (ubuntu-24.04, ubuntu-24.04-arm)
- CloudFlare R2 object storage (for ISO hosting)
- GitHub Container Registry (GHCR) access for base images

---

*Stack analysis: 2026-01-28*
