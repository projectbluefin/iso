#!/usr/bin/env bash
set -e

# Configuration
MAPPER_NAME="cryptroot"
BOOT_LABEL="BOOT"
ROOT_LABEL="ROOT"
BOOT_SIZE="2G"
MOUNT_POINT="/mnt"
IMAGE="ghcr.io/projectbluefin/dakota:latest"

# Ensure dependencies are installed
DEPS=(gum cryptsetup mkfs.btrfs mkfs.fat sgdisk podman lsblk)
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo "Error: $dep is not installed."
        exit 1
    fi
done

echo "--- Dakota Advanced Installer (LUKS + Btrfs) ---"

# Identify available disks
MAPFILE_DISKS=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    MODEL=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//')
    [[ "$NAME" == zram* ]] && continue
    MAPFILE_DISKS+=("$NAME ($SIZE) - $MODEL")
done < <(lsblk -nlo NAME,SIZE,MODEL,TYPE | grep disk)

if [ ${#MAPFILE_DISKS[@]} -eq 0 ]; then
    echo "No disks found!"
    exit 1
fi

echo "Select target disk:"
SELECTED_DISPLAY=$(printf "%s\n" "${MAPFILE_DISKS[@]}" | gum choose)
[ -z "$SELECTED_DISPLAY" ] && exit 1

DISK=$(echo "$SELECTED_DISPLAY" | awk '{print $1}')
[[ "$DISK" != /dev/* ]] && DISK="/dev/$DISK"

PART_PREFIX=""
[[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]] && PART_PREFIX="p"

DEV_BOOT="${DISK}${PART_PREFIX}1"
DEV_ROOT="${DISK}${PART_PREFIX}2"
MAPPER="/dev/mapper/$MAPPER_NAME"

gum style --border normal --margin "1" --padding "1" --border-foreground 212 \
    "Target Disk: $DISK" \
    "Boot Partition: $DEV_BOOT" \
    "Root Partition: $DEV_ROOT" \
    "Encryption: LUKS2" \
    "Filesystem: Btrfs" \
    "Image: $IMAGE"

gum confirm "⚠️  WIPE ALL DATA on $DISK?" || exit 1

gum spin --spinner dot --title "Cleaning up..." -- bash -c "umount -R $MOUNT_POINT 2>/dev/null || true; cryptsetup close $MAPPER_NAME 2>/dev/null || true"

echo "-> Partitioning..."
wipefs -a "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+"$BOOT_SIZE" -t 1:ef00 -c 1:"$BOOT_LABEL" "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"$ROOT_LABEL" "$DISK"

echo "-> Setting up LUKS..."
cryptsetup luksFormat --type luks2 "$DEV_ROOT"
cryptsetup open "$DEV_ROOT" "$MAPPER_NAME"

echo "-> Creating filesystems..."
mkfs.fat -F 32 -n "$BOOT_LABEL" "$DEV_BOOT"
mkfs.btrfs -L "$ROOT_LABEL" -f "$MAPPER"

echo "-> Mounting..."
mkdir -p "$MOUNT_POINT"
mount "$MAPPER" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot"
mount "$DEV_BOOT" "$MOUNT_POINT/boot"

BOOT_UUID=$(blkid -s UUID -o value "$DEV_BOOT")
LUKS_UUID=$(blkid -s UUID -o value "$DEV_ROOT")

echo "Checking for Dakota image..."
if ! podman image exists "$IMAGE"; then
    podman pull "$IMAGE" || exit 1
fi

gum style --foreground 212 "Running bootc install..."
podman run \
    --rm --privileged --pid=host \
    -v /etc/containers:/etc/containers:Z \
    -v /var/lib/containers:/var/lib/containers:Z \
    -v /dev:/dev \
    -e RUST_LOG=debug \
    -v "$MOUNT_POINT:/mnt" \
    --security-opt label=type:unconfined_t \
    "$IMAGE" bootc install to-filesystem /mnt \
    --composefs-backend \
    --bootloader systemd \
    --karg splash \
    --karg quiet \
    --karg "rd.luks.name=${LUKS_UUID}=$MAPPER_NAME" \
    --karg "root=$MAPPER" \
    --karg rootflags=subvol=/ \
    --karg rw || true

echo "Configuring system..."
mount -o remount,rw "$MOUNT_POINT"
mount -o remount,rw "$MOUNT_POINT/boot"

DEPLOY_DIR=$(find "$MOUNT_POINT/state/deploy" -maxdepth 1 -type d -name '*' | grep -v "$MOUNT_POINT/state/deploy$" | head -n 1)
BOOT_ENTRY=$(find "$MOUNT_POINT/boot/loader/entries/" -name "*.conf" | head -n 1)
COMPOSEFS_HASH=$(basename "$DEPLOY_DIR")

if [ -n "$BOOT_ENTRY" ]; then
    sed -i "s|^options.*|options rd.luks.name=${LUKS_UUID}=${MAPPER_NAME} rd.luks.uuid=luks-${LUKS_UUID} root=$MAPPER rootflags=subvol=/ rw boot=UUID=${BOOT_UUID} composefs=${COMPOSEFS_HASH} splash quiet|" "$BOOT_ENTRY"
fi

mkdir -p "${DEPLOY_DIR}/etc"
cat << EOF > "${DEPLOY_DIR}/etc/crypttab"
${MAPPER_NAME} UUID=${LUKS_UUID} none luks
EOF

cat << EOF > "${DEPLOY_DIR}/etc/fstab"
$MAPPER  /      btrfs  defaults  0 0
UUID=${BOOT_UUID}      /boot  vfat   defaults  0 2
EOF

sync
umount -R "$MOUNT_POINT"
cryptsetup close "$MAPPER_NAME"
gum style --foreground 212 --bold "Installation Complete!"
