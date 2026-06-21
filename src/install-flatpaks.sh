#!/usr/bin/bash
# Pre-install flatpaks into the live squashfs.
#
# Uses --mount=type=cache,target=/var/cache/flatpak-dl to persist the flatpak
# ostree repo across builds.  On each run the script:
#   1. Seeds /var/lib/flatpak/repo from the build cache (warm start)
#   2. Reconciles to match /tmp/flatpaks-list (only deltas downloaded)
#   3. Saves the repo back to the cache for next build
#
# /tmp/flatpaks-list is COPYd by the Containerfile so it's always current.
# Requires network at build time; CAP_SYS_ADMIN for dbus.

set -exo pipefail

FLATPAK_CACHE="/var/cache/flatpak-dl"

# overlayfs inside Podman builds doesn't support O_TMPFILE.  /dev/shm would
# work but is only ~3.5 GB on GHA 7-GB runners — too small for GNOME Platform.
# The --mount=type=cache volume is a bind-mount from btrfs (supports O_TMPFILE)
# and has ~60 GB free, so use a subdirectory of it as TMPDIR instead.
mkdir -p "${FLATPAK_CACHE}/tmp"
export TMPDIR="${FLATPAK_CACHE}/tmp"
mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile
sleep 1

# ── Seed flatpak repo from build cache (warm start) ──────────────────────────
if [ -d "${FLATPAK_CACHE}/repo/refs" ]; then
    echo "Seeding flatpak repo from build cache..."
    rsync -a --ignore-existing "${FLATPAK_CACHE}/repo/" /var/lib/flatpak/repo/ || true
    echo "Cache seed complete"
fi

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

# bootc-installer bundle
# INSTALLER_CHANNEL controls which release tag to pull from:
#   stable (default) → continuous   (latest stable build from prod branch)
#   dev              → continuous-dev (latest dev build, tracks dev branch)
# Primary source: projectbluefin/bootc-installer (Project Bluefin's fork).
# Fallback: tuna-os/tuna-installer (upstream) if projectbluefin assets are unavailable.
# v2.5.0 includes fisherman v0.2.0 with fix for #38 (OCI cache mount on composefs/btrfs).
INSTALLER_REPO="projectbluefin/bootc-installer"
FALLBACK_REPO="tuna-os/tuna-installer"
RELEASE_TAG="continuous"
FLATPAK_FILENAME="org.bootcinstaller.Installer.flatpak"
if [[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]]; then
    RELEASE_TAG="continuous-dev"
    FLATPAK_FILENAME="org.bootcinstaller.Installer.Devel.flatpak"
fi
if ! curl --retry 3 --fail --location \
    "https://github.com/${INSTALLER_REPO}/releases/download/${RELEASE_TAG}/${FLATPAK_FILENAME}" \
    -o /tmp/tuna-installer.flatpak 2>/dev/null; then
    echo "Primary source unavailable, falling back to ${FALLBACK_REPO}..."
    curl --retry 3 --fail --location \
        "https://github.com/${FALLBACK_REPO}/releases/download/${RELEASE_TAG}/${FLATPAK_FILENAME}" \
        -o /tmp/tuna-installer.flatpak
fi
INSTALLER_APP_ID="org.bootcinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"

flatpak install --system --noninteractive --bundle /tmp/tuna-installer.flatpak || \
    flatpak update --system --noninteractive "${INSTALLER_APP_ID}"
rm /tmp/tuna-installer.flatpak

flatpak override --system --filesystem=/etc:ro "${INSTALLER_APP_ID}"

# ── Reconcile Flathub apps against the wanted list ───────────────────────────
# In debug mode, skip the full Flathub app list to keep builds fast.
# NOTE: Disabled to allow debug ISOs with full flatpak suite + SSH access
# if [[ "${DEBUG:-0}" == "1" ]]; then
#     echo "DEBUG mode: skipping Flathub app list (installer-only ISO)"
#     # Still save cache for the installer runtime
#     echo "Saving flatpak repo to build cache..."
#     mkdir -p "${FLATPAK_CACHE}"
#     rsync -a --delete /var/lib/flatpak/repo/ "${FLATPAK_CACHE}/repo/"
#     exit 0
# fi

readarray -t WANTED < <(grep -v '^[[:space:]]*#' /tmp/flatpaks-list | grep -v '^[[:space:]]*$')

# Install or update everything in the list (--or-update = skip if current)
# --no-related skips locale packs and debug symbols (~3 GB uncompressed)
flatpak install --system --noninteractive --no-related --or-update flathub "${WANTED[@]}"

# Remove any system app that is no longer in the wanted list
readarray -t INSTALLED < <(flatpak list --app --system --columns=application 2>/dev/null || true)
for app in "${INSTALLED[@]}"; do
    # Keep the installer regardless (stable or devel app ID)
    [[ "$app" == "org.bootcinstaller.Installer" ]] && continue
    [[ "$app" == "org.bootcinstaller.Installer.Devel" ]] && continue
    if [[ ! " ${WANTED[*]} " =~ " ${app} " ]]; then
        echo "Removing dropped flatpak: $app"
        flatpak uninstall --system --noninteractive "$app" || true
    fi
done

# Prune unused runtimes left behind by removals
flatpak uninstall --system --noninteractive --unused || true

# ── Save flatpak repo to build cache for next build ──────────────────────────
echo "Saving flatpak repo to build cache..."
mkdir -p "${FLATPAK_CACHE}"
rsync -a --delete /var/lib/flatpak/repo/ "${FLATPAK_CACHE}/repo/"
echo "Cache updated"
