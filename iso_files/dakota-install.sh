#!/usr/bin/env bash
set -e

# Ensure gum is installed
if ! command -v gum &> /dev/null; then
    echo "Error: gum is not installed. Please install it first."
    exit 1
fi

echo "--- Dakota Standalone Installer ---"

# Identify the installer disk (best effort)
# In many live environments, the ISO is mounted via a loop device or directly from a USB.
# We can try to find the disk containing the label 'Fedora', 'Bluefin', or 'ANACONDA'
INSTALLER_DISK=$(lsblk -rnlo NAME,LABEL,TYPE | grep -E "Fedora|Bluefin|ANACONDA" | grep "part" | head -n1 | cut -d' ' -f1 | sed 's/[0-9]*$//')
if [ -z "$INSTALLER_DISK" ]; then
    # Fallback: check where /run/initramfs/live is mounted if it exists
    INSTALLER_DISK=$(lsblk -no PKNAME $(df /run/initramfs/live 2>/dev/null | tail -n1 | awk '{print $1}') 2>/dev/null)
fi

echo "Identifying available disks..."

# List disks excluding zram and potentially the installer disk
MAPFILE_DISKS=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    MODEL=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//')
    
    # Skip zram
    [[ "$NAME" == zram* ]] && continue
    
    DISPLAY_NAME="$NAME ($SIZE) - $MODEL"
    if [[ "$NAME" == "$INSTALLER_DISK" ]]; then
        DISPLAY_NAME="$DISPLAY_NAME [INSTALLER DISK - WARNING]"
    fi
    MAPFILE_DISKS+=("$DISPLAY_NAME")
done < <(lsblk -nlo NAME,SIZE,MODEL,TYPE | grep disk)

if [ ${#MAPFILE_DISKS[@]} -eq 0 ]; then
    echo "No disks found!"
    exit 1
fi

echo "Select target disk for Dakota installation:"
SELECTED_DISPLAY=$(printf "%s\n" "${MAPFILE_DISKS[@]}" | gum choose)

if [ -z "$SELECTED_DISPLAY" ]; then
    echo "No disk selected. Exiting."
    exit 1
fi

SELECTED_DISK=$(echo "$SELECTED_DISPLAY" | awk '{print $1}')

if [[ "$SELECTED_DISK" == "$INSTALLER_DISK" ]]; then
    gum confirm "WARNING: You have selected the installer disk ($SELECTED_DISK). Are you sure you want to proceed? This will likely destroy the installer media." || exit 1
else
    gum confirm "Are you sure you want to install Dakota to $SELECTED_DISK? THIS WILL WIPE THE DISK!" || exit 1
fi

echo "Proceeding with installation to /dev/$SELECTED_DISK..."

# Ensure the Dakota image is available
echo "Checking for Dakota image..."
if ! podman image exists ghcr.io/projectbluefin/dakota:latest; then
    echo "Dakota image not found locally. Attempting to pull..."
    podman pull ghcr.io/projectbluefin/dakota:latest || {
        echo "Error: Failed to pull Dakota image and it is not available locally."
        echo "If you are offline, ensure the image was pre-pulled during ISO build."
        exit 1
    }
else
    echo "Dakota image found locally. Proceeding..."
    # Optional: try to pull if online, but don't fail if offline
    podman pull ghcr.io/projectbluefin/dakota:latest || echo "Warning: Failed to check for latest Dakota image, using local version."
fi

# Use bootc install to-disk
# partitioning is handled by bootc to-disk if specify --wipe
# We use the arguments from the original script but adapted for to-disk
echo "Running bootc install..."
podman run \
    --rm --privileged --pid=host \
    -v /etc/containers:/etc/containers:Z \
    -v /var/lib/containers:/var/lib/containers:Z \
    -v /dev:/dev \
    -e RUST_LOG=debug \
    --security-opt label=type:unconfined_t \
    "ghcr.io/projectbluefin/dakota:latest" \
    bootc install to-disk \
    --wipe \
    --bootloader systemd \
    --karg splash \
    --karg quiet \
    "/dev/$SELECTED_DISK"

echo "Installation complete! You can now reboot."
