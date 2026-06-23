#!/usr/bin/env bash

set -euo pipefail

# Script to build Bluefin LTS images using the Titanoboa builder
# Usage: local-iso-build.sh <variant> <flavor> <repo> [hook_script] [flatpaks_file]
#   flavor: base, dx, gdx
#   repo: local, ghcr
#   hook_script: optional post_rootfs hook script (default: iso_files/configure_lts_iso_anaconda.sh)
#   flatpaks_file: optional flatpaks list (default: flatpaks/system-flatpaks.list or empty if missing)

GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-ublue-os}"
IMAGE_NAME="${IMAGE_NAME:-bluefin}"

# Resolve repo root (assuming script is in hack/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

variant="${1:-lts}"
flavor="${2:-base}"
repo="${3:-ghcr}"

if [ "$variant" == "lts" ]; then
    IMAGE_DISTRO="centos"
    DEFAULT_HOOK="$REPO_ROOT/iso_files/configure_lts_iso_anaconda.sh"
elif [ "$variant" == "bluefin" ]; then
    IMAGE_DISTRO="fedora"
    DEFAULT_HOOK="$REPO_ROOT/iso_files/configure_iso_anaconda.sh"
else
    echo "Error: Unknown variant '$variant'. Supported variants: lts, bluefin"
    exit 1
fi

hook_script="${4:-$DEFAULT_HOOK}"
flatpaks_source="${5:-https://raw.githubusercontent.com/projectbluefin/common/refs/heads/main/system_files/bluefin/usr/share/ublue-os/homebrew/system-flatpaks.Brewfile}"

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

# Map variant name to image tag
if [ "$variant" = "bluefin" ]; then
	IMAGE_TAG="stable"
else
	IMAGE_TAG="$variant"
fi

if [ "$repo" = "ghcr" ]; then
	TARGET_IMAGE_NAME="ghcr.io/${GITHUB_REPOSITORY_OWNER}/${IMAGE_NAME}:${IMAGE_TAG}${FLAVOR_SUFFIX}"
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
echo -e "  \033[1;32mFlatpaks Source:\033[0m $flatpaks_source"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"

# Clone or update Titanoboa
if [ ! -f "$BUILD_DIR/Justfile" ]; then
	echo "Fetching Titanoboa..."
	# Clone to temp then copy files (BUILD_DIR may have root-owned work/ from previous runs)
	git clone https://github.com/hanthor/titanoboa "/tmp/titanoboa-fresh-$$"
	mkdir -p "$BUILD_DIR"
	rsync -a --exclude='work/' "/tmp/titanoboa-fresh-$$/" "$BUILD_DIR/"
	rm -rf "/tmp/titanoboa-fresh-$$"
fi
# Clean work dir from previous build using Titanoboa's own clean target
if [ -d "$BUILD_DIR/work" ]; then
	echo "Cleaning previous work dir via privileged container..."
	sudo /usr/bin/podman run --rm --privileged \
		-v "$BUILD_DIR/work:/work" \
		alpine sh -c 'rm -rf /work/*' 2>/dev/null || true
	rm -rf "$BUILD_DIR/work" 2>/dev/null || true
fi

# Handle flatpaks file
echo "Setting up flatpaks list..."
if [ -f "$flatpaks_source" ]; then
    echo "Using local flatpaks file: $flatpaks_source"
    cp "$flatpaks_source" "$BUILD_DIR/flatpaks.list"
elif [[ "$flatpaks_source" =~ ^https?:// ]]; then
    echo "Fetching flatpaks from URL: $flatpaks_source"
    if curl -sL "$flatpaks_source" -o "$BUILD_DIR/flatpaks.raw"; then
        # Check if it's a Brewfile and parse it
        if grep -q '^flatpak "' "$BUILD_DIR/flatpaks.raw"; then
            echo "Detected Brewfile format, parsing..."
            grep '^flatpak ' "$BUILD_DIR/flatpaks.raw" | awk -F'"' '{print $2}' > "$BUILD_DIR/flatpaks.list"
        else
            mv "$BUILD_DIR/flatpaks.raw" "$BUILD_DIR/flatpaks.list"
        fi
    else
        echo "Warning: Failed to fetch flatpaks list, creating empty list."
        touch "$BUILD_DIR/flatpaks.list"
    fi
else
    echo "Warning: Flatpaks source '$flatpaks_source' not found, creating empty list."
    touch "$BUILD_DIR/flatpaks.list"
fi



# Patch Titanoboa Justfile to ignore setfiles errors (workaround for smartmontools/FS issues)
echo "Patching Titanoboa Justfile to ignore setfiles errors..."
sed -i 's/setfiles -F -r . \/etc\/selinux\/targeted\/contexts\/files\/file_contexts ./setfiles -F -r . \/etc\/selinux\/targeted\/contexts\/files\/file_contexts . || true/' "$BUILD_DIR/Justfile"

# Patch Titanoboa Justfile to ensure builder has device access (fix loop mount)
echo "Patching Titanoboa Justfile to add --device /dev/fuse to builder..."
sed -i 's/--security-opt label=disable/--security-opt label=disable --device \/dev\/fuse/' "$BUILD_DIR/Justfile"

# Patch out root check so we can build without sudo
echo "Patching Titanoboa Justfile to remove root check..."
sed -i "s/if \[ \`id -u\` -gt 0 \]; then echo.*Must be root.*exit 1; fi/echo 'Skipping root check'/" "$BUILD_DIR/Justfile"

# Patch clean recipe to handle root-owned overlay files via privileged podman
echo "Patching Titanoboa clean recipe to handle root-owned files..."
sed -i '/^@clean:/,/^[^ @]/{s|rm -rf {{ absolute_path(workdir) }}|{{ PODMAN }} run --rm --privileged -v {{ absolute_path(workdir) }}:/work alpine sh -c \x27rm -rf /work/*\x27 2>/dev/null \|\| true \&\& rm -rf {{ absolute_path(workdir) }} 2>/dev/null \|\| true|}' "$BUILD_DIR/Justfile"

echo "Copying hook script to $BUILD_DIR directory..."
cp "$hook_script" "$BUILD_DIR/hook.sh"

# Change to the $BUILD_DIR directory
cd "$BUILD_DIR"

# Run the Titanoboa build command
# Titanoboa needs root podman for loop device access during ISO creation
echo "Running Titanoboa build..."
export PODMAN="sudo /usr/bin/podman"
TITANOBOA_BUILDER_DISTRO="$IMAGE_DISTRO" \
	HOOK_post_rootfs="hook.sh" \
    just PODMAN="sudo /usr/bin/podman" build "$TARGET_IMAGE_NAME" 1 flatpaks.list || true

echo "Titanoboa build process finished."

# Locate and Move ISO
ISO_PATH="$BUILD_DIR/output.iso"
if [ -f "$ISO_PATH" ]; then
    TIMESTAMP="$(date +%Y%m%d)"
    OUTPUT_NAME="${IMAGE_NAME}-${variant}${FLAVOR_SUFFIX}-${TIMESTAMP}.iso"

    echo "Copying ISO to $REPO_ROOT/$OUTPUT_NAME..."
    cp "$ISO_PATH" "$REPO_ROOT/$OUTPUT_NAME"

    echo -e "\n\033[1;32mSUCCESS: ISO available at: $REPO_ROOT/$OUTPUT_NAME\033[0m"
else
    echo "Error: Output ISO not found at $ISO_PATH"
    exit 1
fi
