# External Integrations

**Analysis Date:** 2026-01-28

## APIs & External Services

**Container Registries:**
- GitHub Container Registry (GHCR) - Base container image storage
  - SDK/Client: podman, docker, skopeo
  - Auth: GitHub Actions automatic authentication
  - Images pulled: `ghcr.io/ublue-os/bluefin*`, `ghcr.io/projectbluefin/bluefin*`
  - Used in: `.github/workflows/reusable-build-iso-anaconda.yml`, `Justfile`

**GitHub Services:**
- GitHub Actions - CI/CD platform
  - Workflow files: `.github/workflows/*.yml`
  - Runners: ubuntu-24.04 (amd64), ubuntu-24.04-arm (arm64)
  - Triggers: workflow_dispatch, schedule (cron), pull_request
- GitHub API - Repository operations
  - Used via: `actions/checkout@v5`, `actions/upload-artifact@v5`
  - Permissions: contents:read, packages:read, id-token:write

**Package Repositories:**
- COPR (Community Projects) - Fedora/CentOS package hosting
  - Repositories: `jreilly/anaconda-webui`, `jreilly1821/anaconda-webui`
  - Used in: `iso_files/configure_iso_anaconda.sh`, `iso_files/configure_lts_iso_anaconda.sh`
  - Enables via: `dnf copr enable -y <repo>`
- DNF/YUM repositories - System package installation
  - Fedora repos (Stable variant)
  - CentOS repos (LTS variant)
  - `centos-release-kmods-kernel` - Kernel modules for LTS

**Git Repositories:**
- `github.com/projectbluefin/branding` - ISO branding assets
  - Cloned in: `iso_files/configure_iso_anaconda.sh:137`, `iso_files/configure_lts_iso_anaconda.sh:134`
  - Usage: Anaconda installer artwork
- `github.com/projectbluefin/common` - Common flatpak lists
  - Cloned in: `.github/workflows/reusable-build-iso-anaconda.yml:177`
  - Usage: System flatpak Brewfile parsing
- `github.com/ublue-os/akmods` - Secure boot keys
  - URL: `https://github.com/ublue-os/akmods/raw/main/certs/public_key.der`
  - Used in: `iso_files/configure_iso_anaconda.sh:9` (Stable only)
  - Downloaded via: `curl --retry 15`
- `github.com/hanthor/titanoboa` - ISO builder (local builds)
  - Cloned in: `hack/local-iso-build.sh:81`
  - Usage: Local ISO building via Just recipes

## Data Storage

**Databases:**
- None - Stateless ISO build system

**File Storage:**
- CloudFlare R2 - ISO file hosting
  - Buckets: `testing` (staging), `prodtest` (production)
  - Client: rclone
  - Configured via: S3-compatible API
  - Used in: `.github/workflows/reusable-build-iso-anaconda.yml:222-234`
- GitHub Artifacts - Temporary ISO storage
  - Upload action: `actions/upload-artifact@v5`
  - Used in: `.github/workflows/reusable-build-iso-anaconda.yml:206-212`
  - Retention: GitHub's default artifact retention

**Caching:**
- Container storage - `/var/lib/containers/storage`
  - Managed by: `ublue-os/container-storage-action`
  - Compression: zstd:2
  - Free space target: 90%
- GitHub Actions cache - Not explicitly configured
  - Implicit caching via runner image layers

## Authentication & Identity

**Auth Provider:**
- GitHub Actions built-in authentication
  - Implementation: Automatic token injection
  - Permissions managed via workflow `permissions:` block
  - OIDC token for container registry authentication

**Secrets Management:**
- GitHub Secrets - CloudFlare R2 credentials
  - `R2_ACCESS_KEY_ID_2025` - Testing bucket access key
  - `R2_SECRET_ACCESS_KEY_2025` - Testing bucket secret
  - `R2_ENDPOINT_2025` - Testing bucket endpoint
  - `R2_ACCESS_KEY_ID_PRODTEST` - Production bucket access key
  - `R2_SECRET_ACCESS_KEY_PRODTEST` - Production bucket secret
  - `R2_ENDPOINT_PRODTEST` - Production bucket endpoint
  - Inherited via: `secrets: inherit` in caller workflows

## Monitoring & Observability

**Error Tracking:**
- None - Relies on GitHub Actions logs

**Logs:**
- GitHub Actions native logging
  - Visible in: Actions tab of repository
  - Retention: GitHub's default log retention
  - Bash debug mode: `set -eoux pipefail` in scripts

**Metrics:**
- None - No custom metrics collection

## CI/CD & Deployment

**Hosting:**
- CloudFlare R2 - ISO file distribution
  - Testing: `R2:testing` bucket
  - Production: `R2_PROD:prodtest` bucket
  - Access: S3-compatible API via rclone

**CI Pipeline:**
- GitHub Actions workflows
  - Build workflows: `build-iso-stable.yml`, `build-iso-lts.yml`, `build-iso-lts-hwe.yml`
  - Orchestration: `build-iso-all.yml`
  - Promotion: `promote-iso.yml`
  - Validation: `validate-renovate.yml`, `pull-request.yml`
  - Schedule: Monthly cron (`0 2 1 * *`)
  - Manual: workflow_dispatch triggers

**Deployment Strategy:**
- Build → Testing bucket → Manual promotion → Production bucket
- Promotion workflow: `promote-iso.yml`
  - Dry-run mode supported
  - Sync via rclone with variant filtering

## Environment Configuration

**Required env vars (GitHub Secrets):**
- `R2_ACCESS_KEY_ID_2025` - CloudFlare R2 testing access key
- `R2_SECRET_ACCESS_KEY_2025` - CloudFlare R2 testing secret
- `R2_ENDPOINT_2025` - CloudFlare R2 testing endpoint
- `R2_ACCESS_KEY_ID_PRODTEST` - CloudFlare R2 production access key
- `R2_SECRET_ACCESS_KEY_PRODTEST` - CloudFlare R2 production secret
- `R2_ENDPOINT_PRODTEST` - CloudFlare R2 production endpoint

**Build-time env vars:**
- `IMAGE_REGISTRY` - Container registry URL (default: `ghcr.io/ublue-os`)
- `IMAGE_NAME` - Base image name (default: `bluefin`)
- `GITHUB_REPOSITORY_OWNER` - Organization name (default: `ublue-os`)
- `PODMAN` - Container runtime command (auto-detected)
- `PULL_POLICY` - Container pull policy (`newer` for Podman, `missing` for Docker)

**Secrets location:**
- GitHub repository secrets (Settings → Secrets and variables → Actions)
- Not stored in code or configuration files

## Webhooks & Callbacks

**Incoming:**
- None - ISO builder has no webhook endpoints

**Outgoing:**
- None - No webhooks sent to external services

**Event-driven triggers:**
- GitHub Actions events: `workflow_dispatch`, `schedule`, `pull_request`, `workflow_call`
- Cron schedule: `0 2 1 * *` (monthly builds)

---

*Integration audit: 2026-01-28*
