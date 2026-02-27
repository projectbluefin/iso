# Torrent Generation for Bluefin ISOs - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generate `.torrent` files for every ISO build, upload them to R2 alongside ISOs, and publish them as GitHub Releases.

**Architecture:** Add a torrent generation step to the existing reusable build workflow. Torrents use web seeds pointing to both testing (`projectbluefin.dev`) and production (`download.projectbluefin.io`) R2 buckets, plus public BitTorrent trackers. A separate `workflow_run`-triggered workflow creates GitHub Releases with torrent files after successful builds. Zero changes to existing caller workflows.

**Tech Stack:** mktorrent (apt package), GitHub Actions `workflow_run`, rclone (existing), gh CLI (existing)

---

## Context

### File naming pattern

The reusable workflow produces ISOs named via `artifact_format`:
- `bluefin-stable-x86_64` (stable/main)
- `bluefin-nvidia-open-stable-x86_64` (stable/nvidia-open)
- `bluefin-lts-x86_64` / `bluefin-lts-aarch64` (lts/main)
- `bluefin-gdx-lts-x86_64` / `bluefin-gdx-lts-aarch64` (lts/gdx)
- `bluefin-lts-hwe-x86_64` / `bluefin-lts-hwe-aarch64` (lts-hwe/main)

Final files in output directory: `{artifact_format}.iso` and `{artifact_format}.iso-CHECKSUM`

### R2 bucket structure

- **Testing bucket:** `R2:testing` -- public at `https://projectbluefin.dev/{filename}`
- **Production bucket:** `R2_PROD:bluefin` -- public at `https://download.projectbluefin.io/{filename}`
- Upload uses `rclone copy` of the entire output directory -- any file placed there gets uploaded automatically.

### Existing workflow architecture

- `build-iso-stable.yml`, `build-iso-lts.yml`, `build-iso-lts-hwe.yml` -- thin callers
- `build-iso-all.yml` -- calls reusable workflow directly (not callers)
- `reusable-build-iso-anaconda.yml` -- does the actual build + upload
- `promote-iso.yml` -- copies from testing to production bucket

### Tracker list

```
# UDP (traditional BitTorrent)
udp://tracker.opentrackr.org:1337/announce
udp://open.tracker.cl:1337/announce
udp://open.demonii.com:1337/announce
udp://tracker.openbittorrent.com:6969/announce
udp://exodus.desync.com:6969/announce
udp://tracker.torrent.eu.org:451/announce
udp://tracker.moeking.me:6969/announce

# HTTPS (firewall-friendly)
https://tracker.gbitt.info:443/announce
https://tracker.tamersunion.org:443/announce

# WebSocket (WebTorrent/browser support)
wss://tracker.btorrent.xyz
wss://tracker.openwebtorrent.com
```

---

## Task 1: Add torrent generation to reusable build workflow

**Files:**
- Modify: `.github/workflows/reusable-build-iso-anaconda.yml:190` (after the Rename ISO step)

**Step 1: Add mktorrent install + torrent generation step**

Insert after the "Rename ISO" step (after line 190), before the "Upload to Job Artifacts" step:

```yaml
      - name: Generate Torrent File
        env:
          OUTPUT_DIRECTORY: ${{ steps.rename.outputs.output_directory }}
          OUTPUT_NAME: ${{ steps.image_ref.outputs.artifact_format }}
          IMAGE_VERSION: ${{ matrix.image_version }}
          FLAVOR: ${{ matrix.flavor }}
          PLATFORM: ${{ matrix.platform }}
        run: |
          set -eoux pipefail

          sudo apt-get install -y mktorrent

          BUILD_DATE=$(date -u +%Y-%m-%d)

          cd "${OUTPUT_DIRECTORY}"
          mktorrent \
            -a udp://tracker.opentrackr.org:1337/announce \
            -a udp://open.tracker.cl:1337/announce \
            -a udp://open.demonii.com:1337/announce \
            -a udp://tracker.openbittorrent.com:6969/announce \
            -a udp://exodus.desync.com:6969/announce \
            -a udp://tracker.torrent.eu.org:451/announce \
            -a udp://tracker.moeking.me:6969/announce \
            -a https://tracker.gbitt.info:443/announce \
            -a https://tracker.tamersunion.org:443/announce \
            -a wss://tracker.btorrent.xyz \
            -a wss://tracker.openwebtorrent.com \
            -w "https://projectbluefin.dev/${OUTPUT_NAME}.iso" \
            -w "https://download.projectbluefin.io/${OUTPUT_NAME}.iso" \
            -c "Bluefin ${IMAGE_VERSION} ${FLAVOR} (${PLATFORM}) - ${BUILD_DATE}" \
            -o "${OUTPUT_NAME}.iso.torrent" \
            "${OUTPUT_NAME}.iso"

          sha256sum "${OUTPUT_NAME}.iso.torrent" | tee "${OUTPUT_NAME}.iso.torrent-CHECKSUM"
```

**Why two web seeds:** The testing URL (`projectbluefin.dev`) works immediately after build. The production URL (`download.projectbluefin.io`) works after promotion. Both are listed so the torrent is functional in both phases.

**No other changes needed in this file.** The existing `rclone copy "${SOURCE_DIR}" R2:testing` uploads the entire output directory, so `.iso.torrent` and `.iso.torrent-CHECKSUM` are uploaded automatically. Same for the artifact upload step.

**Step 2: Commit**

```
feat(ci): add torrent generation to ISO build workflow

Generate .torrent files for each ISO with public trackers and web seeds
pointing to both testing and production R2 buckets.

Assisted-by: Claude Opus 4 via OpenCode
```

---

## Task 2: Fix promote-iso.yml filters to include torrent files

**Files:**
- Modify: `.github/workflows/promote-iso.yml:62`

**Step 1: Update the `all` filter**

The `stable` and `lts` filters use `*.iso*` which already matches `.iso.torrent` and `.iso.torrent-CHECKSUM`. Only the `all` filter needs fixing because it uses exact patterns `*.iso` and `*.iso-CHECKSUM`.

Change line 62 from:
```yaml
              echo "filter=--include *.iso --include *.iso-CHECKSUM" >> $GITHUB_OUTPUT
```
to:
```yaml
              echo "filter=--include *.iso --include *.iso-CHECKSUM --include *.iso.torrent --include *.iso.torrent-CHECKSUM" >> $GITHUB_OUTPUT
```

**Step 2: Commit**

```
fix(ci): include torrent files in promote-iso 'all' filter

The stable and lts filters already match via *.iso* glob, but the 'all'
filter uses exact patterns that would miss .torrent files.

Assisted-by: Claude Opus 4 via OpenCode
```

---

## Task 3: Create GitHub Release workflow

**Files:**
- Create: `.github/workflows/create-torrent-release.yml`

**Step 1: Create the workflow file**

This workflow triggers automatically via `workflow_run` when any build workflow succeeds. It downloads all torrent files from R2 testing bucket and creates a single GitHub Release.

```yaml
---
name: Create Torrent Release
# Automatically creates a GitHub Release with .torrent files
# after a successful ISO build workflow completes.
on:
  workflow_run:
    workflows:
      - "Build Stable ISOs"
      - "Build LTS ISOs"
      - "Build LTS-HWE ISOs"
      - "Build All ISOs"
    types:
      - completed

jobs:
  create-release:
    name: Create Torrent Release
    runs-on: ubuntu-latest
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    permissions:
      contents: write
    env:
      RCLONE_CONFIG_R2_TYPE: s3
      RCLONE_CONFIG_R2_PROVIDER: Cloudflare
      RCLONE_CONFIG_R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID_2025 }}
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY_2025 }}
      RCLONE_CONFIG_R2_REGION: auto
      RCLONE_CONFIG_R2_ENDPOINT: ${{ secrets.R2_ENDPOINT_2025 }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Homebrew
        uses: Homebrew/actions/setup-homebrew@master

      - name: Install rclone
        run: brew install rclone

      - name: Download Torrent Files from R2
        run: |
          set -eoux pipefail
          mkdir -p torrents
          rclone copy R2:testing torrents \
            --include "*.iso.torrent" \
            --include "*.iso.torrent-CHECKSUM" \
            --log-level INFO

          echo "Downloaded torrent files:"
          ls -lh torrents/

          if [ -z "$(ls torrents/*.torrent 2>/dev/null)" ]; then
            echo "No torrent files found in R2 testing bucket"
            exit 1
          fi

      - name: Determine Release Version
        id: version
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -eoux pipefail
          YEAR_MONTH=$(date -u +%y.%m)

          if gh release view "${YEAR_MONTH}" >/dev/null 2>&1; then
            PATCH=1
            while gh release view "${YEAR_MONTH}.${PATCH}" >/dev/null 2>&1; do
              PATCH=$((PATCH + 1))
            done
            VERSION="${YEAR_MONTH}.${PATCH}"
          else
            VERSION="${YEAR_MONTH}"
          fi

          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          TRIGGER_WORKFLOW: ${{ github.event.workflow_run.name }}
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          set -eoux pipefail

          TORRENT_LIST=""
          for f in torrents/*.torrent torrents/*.torrent-CHECKSUM; do
            [ -f "$f" ] && TORRENT_LIST="${TORRENT_LIST} ${f}"
          done

          gh release create "${VERSION}" \
            --title "Bluefin ISOs ${VERSION}" \
            --notes "$(cat <<'NOTES'
          ## Bluefin ISO Torrents

          ### How to Download

          1. Download a `.torrent` file below
          2. Open with a BitTorrent client (qBittorrent, Transmission, etc.)
          3. Torrents include web seeds -- downloads work immediately

          ### Direct Downloads

          ISOs are also available at https://download.projectbluefin.io/

          ### Verify

          ```bash
          sha256sum -c <filename>.torrent-CHECKSUM
          ```
          NOTES
          )" \
            ${TORRENT_LIST}
```

**Key design decisions:**
- Uses `workflow_run` so **zero changes** to existing caller workflows
- Only runs when builds succeed (`conclusion == 'success'`)
- Downloads ALL torrents from testing bucket (creates a combined release)
- `YY.MM` for first release of the month, `YY.MM.1`, `YY.MM.2`, etc. for subsequent
- Only `.torrent` and `.torrent-CHECKSUM` files -- no ISOs in releases

**Step 2: Commit**

```
feat(ci): add automatic torrent release workflow

Creates GitHub Releases with .torrent files after successful ISO builds.
Uses workflow_run trigger -- no changes to existing workflows needed.
Versioned as YY.MM with .x patches for multiple builds per month.

Assisted-by: Claude Opus 4 via OpenCode
```

---

## Task 4: Validate all changes

**Step 1: Run pre-commit**

```bash
pre-commit run --all-files
```

**Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/reusable-build-iso-anaconda.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/create-torrent-release.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/promote-iso.yml'))"
```

**Step 3: Fix any pre-commit issues and commit if needed**

```
chore: fix formatting from pre-commit

Assisted-by: Claude Opus 4 via OpenCode
```

---

## Summary

| File | Change | Lines touched |
|------|--------|---------------|
| `reusable-build-iso-anaconda.yml` | Add torrent generation step after Rename ISO | ~25 lines inserted |
| `promote-iso.yml` | Add torrent patterns to `all` filter | 1 line changed |
| `create-torrent-release.yml` | New workflow for GitHub Releases | ~90 lines |

**Files NOT modified:** `build-iso-stable.yml`, `build-iso-lts.yml`, `build-iso-lts-hwe.yml`, `build-iso-all.yml`

**Total: 2 files modified, 1 file created.**
