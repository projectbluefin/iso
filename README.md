# Bluefin ISO Builder

This repository builds Bluefin ISOs using Anaconda and [Titanoboa](https://github.com/ublue-os/titanoboa)

## Overview

Workflows and configuration files needed to build bootable Bluefin ISOs for installation.

- Pre-configured Anaconda installer
- System flatpaks
- Custom branding and configuration
- Secure boot key enrollment

![ISO go nomnom](https://github.com/user-attachments/assets/2feeb772-713f-40b3-81e8-3f93b157fa13)

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

ISOs are built automatically via GitHub Actions workflows:

### Manual Build
Trigger a workflow dispatch with your desired image version:
1. Go to Actions → "Build ISOs (Live Anaconda)"
2. Click "Run workflow"
3. Select the image version to build (lts, lts-hwe, gts, stable, or all)
4. Choose upload options

### Automatic Build
ISOs are built automatically when:
- Changes are made to ISO configuration files
- Triggered by the LTS workflow

## Repository Structure

```
.
├── .github/workflows/       # GitHub Actions workflows
│   ├── build-iso-lts.yml   # LTS ISO build workflow
│   ├── reusable-build-iso-anaconda.yml  # Main ISO build workflow
│   ├── validate-brewfiles.yml  # Validate Homebrew files
│   └── validate-flatpaks.yml   # Validate Flatpak lists
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
