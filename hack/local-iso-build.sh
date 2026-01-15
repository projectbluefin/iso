#!/usr/bin/env bash

set -euo pipefail

# Script to build Bluefin LTS images using the Titanoboa builder
# Usage: local-iso-build.sh <flavor> <repo> [hook_script] [flatpaks_file]
#   flavor: base, dx, gdx
#   repo: local, ghcr
#   hook_script: optional post_rootfs hook script (default: iso_files/configure_lts_iso_anaconda.sh)
#   flatpaks_file: optional flatpaks list (default: flatpaks/system-flatpaks.list or empty if missing)

GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-ublue-os}"
IMAGE_NAME="${IMAGE_NAME:-bluefin}"

# Resolve repo root (assuming script is in hack/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bluefin LTS is based on CentOS Stream
IMAGE_DISTRO="centos"
variant="lts"

flavor="${1:-base}"
repo="${2:-ghcr}"
hook_script="${3:-$REPO_ROOT/iso_files/configure_lts_iso_anaconda.sh}"
flatpaks_file="${4:-$REPO_ROOT/flatpaks/system-flatpaks.list}"

# Verify hook script exists
if [ ! -f "$hook_script" ]; then
    echo "Error: Hook script not found at $hook_script"
    exit 1
fi

BUILD_DIR="$REPO_ROOT/.build/${variant}-${flavor}"

# Construct the image URI
if [ "$flavor" != "base" ]; then
	FLAVOR_SUFFIX="-$flavor"
else
	FLAVOR_SUFFIX=""
fi

if [ "$repo" = "ghcr" ]; then
	TARGET_IMAGE_NAME="ghcr.io/${GITHUB_REPOSITORY_OWNER}/${IMAGE_NAME}:${variant}${FLAVOR_SUFFIX}"
elif [ "$repo" = "local" ]; then
	TARGET_IMAGE_NAME="localhost/${IMAGE_NAME}:${variant}${FLAVOR_SUFFIX}"
else
	echo "Unknown repo: $repo. Use 'local' or 'ghcr'" >&2
	exit 1
fi

echo -e "\n\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;33m                        Building with Titanoboa\033[0m"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "  \033[1;32mVariant:\033[0m       $variant"
echo -e "  \033[1;32mFlavor:\033[0m        $flavor"
echo -e "  \033[1;32mRepo:\033[0m          $repo"
echo -e "  \033[1;32mImage Distro:\033[0m  $IMAGE_DISTRO"
echo -e "  \033[1;32mImage Name:\033[0m    $TARGET_IMAGE_NAME"
echo -e "  \033[1;32mHook Script:\033[0m   $hook_script"
echo -e "  \033[1;32mFlatpaks File:\033[0m $flatpaks_file"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"

# Clean up any previous copy of Titanoboa that might have sudo permissions
if [ -d "$BUILD_DIR" ]; then
	echo "Cleaning up previous Titanoboa build directory..."
	sudo rm -rf "$BUILD_DIR"
fi

# Clone Titanoboa if not already present
if [ ! -d "$BUILD_DIR" ]; then
	echo "Cloning Titanoboa builder..."
	git clone https://github.com/hanthor/titanoboa "$BUILD_DIR"
fi

# Handle flatpaks file
echo "Copying flatpaks file to $BUILD_DIR directory..."
if [ -f "$flatpaks_file" ]; then
	cp "$flatpaks_file" "$BUILD_DIR/flatpaks.list"
else
    echo "Warning: Flatpaks file not found, creating empty list."
    touch "$BUILD_DIR/flatpaks.list"
fi

echo "Copying hook script to $BUILD_DIR directory..."
cp "$hook_script" "$BUILD_DIR/hook.sh"

# Change to the $BUILD_DIR directory
cd "$BUILD_DIR"

# Run the Titanoboa build command
echo "Running Titanoboa build..."
sudo TITANOBOA_BUILDER_DISTRO="$IMAGE_DISTRO" \
	HOOK_post_rootfs="hook.sh" \
	just build "$TARGET_IMAGE_NAME" 1 flatpaks.list

echo "Titanoboa build completed successfully!"
