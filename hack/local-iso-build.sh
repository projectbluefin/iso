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

if [ "$repo" = "ghcr" ]; then
	TARGET_IMAGE_NAME="ghcr.io/${GITHUB_REPOSITORY_OWNER}/${IMAGE_NAME}:${variant}${FLAVOR_SUFFIX}"
elif [ "$repo" = "local" ]; then
	TARGET_IMAGE_NAME="localhost/${IMAGE_NAME}:${variant}${FLAVOR_SUFFIX}"
else
	echo "Unknown repo: $repo. Use 'local' or 'ghcr'" >&2
	exit 1
fi

# Determine if Dakota should be enabled
ENABLE_DAKOTA="false"
if [[ "$variant" == "bluefin" ]]; then
    # Fedora-based Bluefin stable
    ENABLE_DAKOTA="true"
elif [[ "$variant" == "lts" && "$flavor" == "hwe" ]]; then
    # LTS HWE
    ENABLE_DAKOTA="true"
fi

echo -e "\n\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;33m                        Building with Titanoboa\033[0m"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "  \033[1;32mVariant:\033[0m       $variant"
echo -e "  \033[1;32mFlavor:\033[0m        $flavor"
echo -e "  \033[1;32mENABLE_DAKOTA:\033[0m $ENABLE_DAKOTA"
echo -e "  \033[1;32mRepo:\033[0m          $repo"
echo -e "  \033[1;32mImage Distro:\033[0m  $IMAGE_DISTRO"
echo -e "  \033[1;32mImage Name:\033[0m    $TARGET_IMAGE_NAME"
echo -e "  \033[1;32mHook Script:\033[0m   $hook_script"
echo -e "  \033[1;32mFlatpaks Source:\033[0m $flatpaks_source"
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

# Pre-pull images on host to leverage local cache
echo "Pre-pulling images on host to optimize build..."
if podman image exists "$TARGET_IMAGE_NAME"; then
    echo "Image $TARGET_IMAGE_NAME found locally, skipping pull."
else
    echo "Image $TARGET_IMAGE_NAME not found locally. Pulling..."
    podman pull "$TARGET_IMAGE_NAME" || echo "Warning: Failed to pre-pull $TARGET_IMAGE_NAME"
fi
if [[ "$ENABLE_DAKOTA" == "true" ]]; then
    if podman image exists ghcr.io/projectbluefin/dakota:latest; then
        echo "Dakota image found locally, skipping pull."
    else
        echo "Dakota image not found locally. Pulling..."
        podman pull ghcr.io/projectbluefin/dakota:latest || echo "Warning: Failed to pre-pull Dakota image"
    fi
fi



# Patch Titanoboa Justfile to ignore setfiles errors
sed -i 's/setfiles -F -r . \/etc\/selinux\/targeted\/contexts\/files\/file_contexts ./setfiles -F -r . \/etc\/selinux\/targeted\/contexts\/files\/file_contexts . || true/' "$BUILD_DIR/Justfile"

# Detect host container storage paths
ROOTLESS_STORAGE=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
ROOTFUL_STORAGE="/var/lib/containers/storage"

# Build mount arguments for host storage
MOUNT_ARGS=""
if [[ -d "$ROOTFUL_STORAGE" ]]; then
    echo "Detected host rootful storage: $ROOTFUL_STORAGE"
    MOUNT_ARGS+=" --volume $ROOTFUL_STORAGE:/host-container-storage-rootful:rw"
fi
if [[ -n "$ROOTLESS_STORAGE" && -d "$ROOTLESS_STORAGE" ]]; then
    echo "Detected host rootless storage: $ROOTLESS_STORAGE"
    MOUNT_ARGS+=" --volume $ROOTLESS_STORAGE:/host-container-storage-rootless:rw"
fi

# 2. Add devices (for builder) and volumes (for both builder and chroot)
echo "Patching Titanoboa Justfile with mounts and permissions..."
sed -i "s|--security-opt label=disable|--security-opt label=disable --device /dev/fuse --device /dev/loop-control --device /dev/loop0|" "$BUILD_DIR/Justfile"
sed -i "s|--volume ' + git_root + ':/app|--volume ' + git_root + ':/app $MOUNT_ARGS --volume /var/lib/flatpak/repo:/host-flatpak-repo:ro|" "$BUILD_DIR/Justfile"

DAKOTA_IMAGE_ARG=""
[[ "$ENABLE_DAKOTA" == "true" ]] && DAKOTA_IMAGE_ARG="ghcr.io/projectbluefin/dakota:latest"


# Inject layer optimization script
sed -i "s|dnf install -y flatpak|dnf install -y flatpak podman skopeo \&\& /usr/bin/bash /app/optimize-iso-build.sh $TARGET_IMAGE_NAME $DAKOTA_IMAGE_ARG|" "$BUILD_DIR/Justfile"

# Add flatpak summary debug
sed -i '/xargs "-i{}" -d "\\n" sh -c/i \    echo "--- Flatpak Install Summary ---" \&\& flatpak list --columns=application,size \&\& echo "------------------------------"' "$BUILD_DIR/Justfile"

# 4. Export ENABLE_DAKOTA to chroot environments
# Using single quotes for the sed expression to avoid shell expansion issues
sed -i 's/chroot "$(cat '"'"'{{ hook }}'"'"')"/export ENABLE_DAKOTA='"$ENABLE_DAKOTA"' \&\& chroot "$(cat '"'"'{{ hook }}'"'"')"/g' "$BUILD_DIR/Justfile"

echo "Copying scripts to $BUILD_DIR..."
cp "$hook_script" "$BUILD_DIR/hook.sh"
cp "$REPO_ROOT/hack/optimize-iso-build.sh" "$BUILD_DIR/optimize-iso-build.sh"
cp "$REPO_ROOT/iso_files/dakota-install.sh" "$BUILD_DIR/dakota-install.sh"

# Run the Titanoboa build command
cd "$BUILD_DIR"
echo "Running Titanoboa build..."
sudo TITANOBOA_BUILDER_DISTRO="$IMAGE_DISTRO" \
     HOOK_post_rootfs="hook.sh" \
     ENABLE_DAKOTA="$ENABLE_DAKOTA" \
     just build "$TARGET_IMAGE_NAME" 1 flatpaks.list || true

echo "Titanoboa build process finished."

# Locate and move the resulting ISO
ISO_PATH="$BUILD_DIR/output.iso"
if [[ -f "$ISO_PATH" ]]; then
    TIMESTAMP="$(date +%Y%m%d)"
    OUTPUT_NAME="${IMAGE_NAME}-${variant}${FLAVOR_SUFFIX}-${TIMESTAMP}.iso"
    echo "Moving ISO to $REPO_ROOT/$OUTPUT_NAME..."
    sudo cp "$ISO_PATH" "$REPO_ROOT/$OUTPUT_NAME"
    sudo chown "$(id -u):$(id -g)" "$REPO_ROOT/$OUTPUT_NAME"
    echo -e "\n\033[1;32mSUCCESS: ISO available at: $REPO_ROOT/$OUTPUT_NAME\033[0m"
else
    echo "Error: Output ISO not found at $ISO_PATH"
    exit 1
fi
