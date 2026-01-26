#!/usr/bin/env bash
set -euo pipefail

# This script is intended to run inside the Titanoboa chroot
# to optimize Flatpak and Container installations using host-provided data.

echo "--- Bluefin ISO Optimization Script ---"

# Network Diagnostic
echo "Checking network connectivity..."
if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "  Network: OK (Connected to 8.8.8.8)"
else
    echo "  Warning: Network appears to be DOWN (Cannot ping 8.8.8.8)"
fi

# 1. Optimize Flatpak
HOST_FLATPAK_REPO="/host-flatpak-repo"
if [[ -d "$HOST_FLATPAK_REPO/objects" ]]; then
    echo "Found host flatpak objects. Setting up OSTree optimization..."
    if command -v flatpak &>/dev/null; then
        if [[ ! -d /var/lib/flatpak/repo ]]; then
            echo "Initializing Flatpak repository..."
            flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
        fi
        mkdir -p /var/lib/flatpak/repo/objects/info
        echo "$HOST_FLATPAK_REPO/objects" > /var/lib/flatpak/repo/objects/info/alternates
        echo "Success: Host flatpak objects added as OSTree alternate."
        
        echo "--- Debug: Flatpak/OSTree Optimization ---"
        echo "Alternates file content: $(cat /var/lib/flatpak/repo/objects/info/alternates)"
        echo "Host objects directory check: $(ls -d $HOST_FLATPAK_REPO/objects 2>/dev/null || echo 'NOT FOUND')"
        echo "Number of objects in host repo: $(find "$HOST_FLATPAK_REPO/objects" -type f | wc -l 2>/dev/null || echo '0')"
        echo "------------------------------------------"
    fi
fi

# 2. Realize Containers (Podman)
STORES=()
[[ -d "/host-container-storage-rootful" ]] && STORES+=("/host-container-storage-rootful")
[[ -d "/host-container-storage-rootless" ]] && STORES+=("/host-container-storage-rootless")

if [[ ${#STORES[@]} -gt 0 ]]; then
    echo "Found host container storage(s). Preparing to realize images..."
    
    # Ensure skopeo is available for efficient copying
    if ! command -v skopeo &>/dev/null; then
        echo "Installing skopeo..."
        dnf clean all && dnf install -y skopeo || true
    fi

    # For each image requested as an argument, try to find it in host stores and copy it
    if [[ $# -gt 0 ]]; then
        for img in "$@"; do
            [[ -z "$img" ]] && continue
            echo "Realizing $img..."
            SUCCESS=0
            for store in "${STORES[@]}"; do
                echo "  Checking host store: $store"
                # Correct skopeo syntax for custom containers-storage:
                # containers-storage:[driver@root]image
                if skopeo copy "containers-storage:[overlay@$store]$img" "containers-storage:$img"; then
                    echo "  Success: $img realized from $store"
                    SUCCESS=1
                    break
                fi
            done
            if [[ $SUCCESS -eq 0 ]]; then
                echo "  Warning: Could not find $img in host stores. Pulling from internet..."
                podman pull "$img" || echo "  Error: Failed to pull $img from internet."
            fi
        done
        echo "Successfully realized images in local storage."
    fi

    echo "--- Final Podman Image List ---"
    podman images
    echo "--------------------------------"
else
    echo "No host container storage found, skipping Podman optimization."
fi
