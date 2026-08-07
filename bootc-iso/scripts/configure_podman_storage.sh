#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Configure podman storage driver intelligently based on available filesystem
# Clears existing podman storage to avoid database mismatch errors

set -eo pipefail

# Stop podman if running
sudo podman rm -fa 2>/dev/null || true
sudo podman rmi -a 2>/dev/null || true

# Clear existing podman storage database to avoid driver mismatch
# This is safe in CI where we start fresh each run
echo "Clearing podman storage database..."
if command -v podman &> /dev/null; then
    sudo podman system reset -f 2>/dev/null || {
        # Fallback if podman system reset isn't available
        sudo rm -rf /var/lib/containers/storage.lock 2>/dev/null || true
        sudo rm -rf /run/containers/storage.lock 2>/dev/null || true
        echo "Warning: podman system reset not available, tried lock file cleanup as fallback"
    }
else
    echo "Podman not installed, skipping reset"
fi

# Detect filesystem type at /var/lib/containers (where BTRFS loopback is mounted)
# Use findmnt to reliably detect filesystem (stat --file-system returns "ext2/ext3" for ext4)
if [ -d /var/lib/containers ]; then
    FS_TYPE=$(findmnt -n -o FSTYPE -T /var/lib/containers 2>/dev/null || echo "unknown")
else
    FS_TYPE=$(findmnt -n -o FSTYPE -T /var/lib 2>/dev/null || echo "unknown")
fi

echo "Detected filesystem for /var/lib/containers: $FS_TYPE"

# Choose driver based on filesystem (native drivers preferred for COW efficiency)
case "$FS_TYPE" in
    btrfs)
        DRIVER="btrfs"
        echo "Using btrfs driver (native COW support on BTRFS filesystem)"
        ;;
    zfs)
        DRIVER="zfs"
        echo "Using zfs driver (native COW support on ZFS filesystem)"
        ;;
    ext4|ext3|ext2|xfs)
        DRIVER="overlay"
        echo "Using overlay driver (space-efficient on ext4/xfs)"
        ;;
    *)
        DRIVER="vfs"
        echo "Using vfs driver (fallback for $FS_TYPE)"
        ;;
esac

# Write storage.conf
echo "Configuring podman storage driver: $DRIVER"
GRAPHROOT="/var/lib/containers/storage"

sudo bash -c "cat > /etc/containers/storage.conf" << CONF
[storage]
driver = "$DRIVER"
graphroot = "$GRAPHROOT"
runroot = "/run/containers/storage"
CONF

# Verify configuration
echo ""
echo "=== Podman storage configuration ==="
sudo podman info | grep -A 5 "storage:" || sudo podman info | head -20
