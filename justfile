image-builder := "image-builder"
image-builder-dev := "image-builder-dev"

# Output directory for built ISOs and intermediate artifacts.
# Override with: just output_dir=/your/path iso-sd-boot bluefin
output_dir := "output"

# Working directory for ISO builds where container storage staging
# and the squashfs-root are stored.
# Override with: just workdir=/your/path iso-sd-boot bluefin
workdir := output_dir

# Set to 1 to enable SSH in the live session for debugging.
# Never use debug=1 for production/release ISOs.
debug := "0"

# Set to "dev" to pull the bootc-installer dev build (continuous-dev release).
installer_channel := "stable"

# LUKS passphrase used by luks-install for testing.
luks-passphrase := "testpassphrase"

# Squashfs compression preset:
#   fast    (default) — zstd level 3,  128K blocks — quick local builds/CI
#   release           — zstd level 15, 1M blocks   — ~20% smaller, ~5× slower
compression := "fast"

# Create an XFS loopback mount at /mnt for faster VFS import.
mount-xfs:
    #!/usr/bin/bash
    set -euo pipefail
    if findmnt -n -o FSTYPE /mnt 2>/dev/null | grep -q '^xfs$'; then
        echo "/mnt is already XFS — skipping"
        exit 0
    fi
    echo "Creating 45G XFS loopback at /mnt..."
    IMG="/var/tmp/bluefin-xfs-loopback.img"
    truncate -s 0 "${IMG}"
    chattr +C "${IMG}" 2>/dev/null || true
    fallocate -l 45G "${IMG}"
    mkfs.xfs -f "${IMG}"
    mount -o loop "${IMG}" /mnt
    echo "XFS mounted at /mnt (45G)"
    echo ""
    echo "Now run your build with workdir on /mnt:"
    echo "  just workdir=/mnt iso-sd-boot bluefin"
    df -h /mnt

# Build the ISO in the background, detached from the terminal session.
build-bg target:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p {{output_dir}}
    LOG=$(realpath {{output_dir}})/build.log
    echo "Starting background build → ${LOG}"
    setsid \
        debug={{debug}} \
        installer_channel={{installer_channel}} \
        output_dir={{output_dir}} \
        compression={{compression}} \
        just iso-sd-boot {{target}} \
        > "${LOG}" 2>&1 &
    disown $!
    echo "Build PID $! — tailing log (Ctrl-C is safe, build continues)"
    tail -f "${LOG}"

# Helper: returns "--bootc-installer-payload-ref <ref>" or "" if no payload_ref file
_payload_ref_flag target:
    @if [ -f "{{target}}/payload_ref" ]; then echo "--bootc-installer-payload-ref $(cat '{{target}}/payload_ref' | tr -d '[:space:]')"; fi

# Map target to filesystem: bluefin=btrfs, bluefin-lts=xfs. Default=btrfs.
_filesystem_for target:
    @if [ "{{target}}" = "bluefin-lts" ]; then echo "xfs"; else echo "btrfs"; fi

container target:
    @test -f "{{target}}/payload_ref" || { echo "ERROR: {{target}}/payload_ref not found — create it with the base image reference, e.g.: echo 'ghcr.io/ublue-os/bluefin:stable' > {{target}}/payload_ref"; exit 1; }
    podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        --build-arg DEBUG={{debug}} \
        --build-arg INSTALLER_CHANNEL={{installer_channel}} \
        --build-arg BASE_IMAGE=$(cat {{target}}/payload_ref | tr -d '[:space:]') \
        --build-arg FILESYSTEM=$(just _filesystem_for {{target}}) \
        -t {{target}}-installer -f ./Containerfile .

# Build the Debian-based ISO assembly container for the given target.
iso-builder target:
    podman build --security-opt label=disable -t {{target}}-iso-builder \
        -f ./Containerfile.builder .

# Build a UEFI live ISO for the given target using systemd-boot and dmsquash-live.
#
# Uses a two-container approach:
#   1. localhost/<target>-installer — the live environment (3-stage Containerfile)
#   2. localhost/<target>-iso-builder — Debian ISO assembly tools (Containerfile.builder)
#
# Output: output/<target>-live.iso
iso-sd-boot target:
    #!/usr/bin/bash
    set -euo pipefail
    PAYLOAD_IMAGE=$(cat "{{target}}/payload_ref" | tr -d '[:space:]')

    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")
    WORKDIR=$(realpath "{{workdir}}")

    echo "=== Disk space before container build ==="
    df -h "${OUTPUT_DIR}"

    if ! findmnt -n -o FSTYPE -T "${WORKDIR}" 2>/dev/null | grep -qE '^(xfs|btrfs)$'; then
        echo "Hint: $WORKDIR is not an XFS/BTRFS mount.  For faster VFS import, run:" >&2
        echo "  sudo just mount-xfs" >&2
        echo "  sudo just workdir=/mnt iso-sd-boot {{target}}" >&2
    fi

    AVAILABLE_KB=$(df --output=avail -B1024 "${OUTPUT_DIR}" | tail -1 | tr -d ' ')
    REQUIRED_KB=$((20 * 1024 * 1024))
    if [ "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]; then
        echo "WARNING: Only $(( AVAILABLE_KB / 1024 / 1024 ))GB free on $(df --output=target "${OUTPUT_DIR}" | tail -1) — ISO output needs ~5GB, full build needs more" >&2
    fi
    podman images --format "table {{{{.Repository}}}}\t{{{{.Tag}}}}\t{{{{.Size}}}}" 2>/dev/null || true

    just debug={{debug}} installer_channel={{installer_channel}} container {{target}}

    echo "=== Disk space after container build ==="
    df -h "${OUTPUT_DIR}"
    podman images --format "table {{{{.Repository}}}}\t{{{{.Tag}}}}\t{{{{.Size}}}}" 2>/dev/null || true

    podman rmi debian:sid 2>/dev/null || true
    podman image prune -f 2>/dev/null || true
    echo "=== Disk space after intermediate cleanup ==="
    df -h "${OUTPUT_DIR}"

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
    fi

    SQUASHFS="${OUTPUT_DIR}/{{target}}-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/{{target}}-boot-files.tar"
    CS_STAGING="${WORKDIR}/{{target}}-cs-staging"
    SQUASHFS_ROOT="${WORKDIR}/{{target}}-sfs-root"
    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${OUTPUT_DIR}/{{target}}-payload.oci.tar' 2>/dev/null || true" EXIT
    echo "=== Disk space before squashfs assembly ==="
    df -h "${OUTPUT_DIR}"
    if [[ "$WORKDIR" != "$OUTPUT_DIR" ]]; then
        df -h "${WORKDIR}"
    fi
    echo "Building squashfs and boot tar from localhost/{{target}}-installer..."
    _ns "
        set -euo pipefail

        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        CS_STAGING='${CS_STAGING}'
        OVERLAY_UPPER=\$(mktemp -d \"\${SQUASHFS_ROOT}_upper_XXXXXX\")
        OVERLAY_WORK=\$(mktemp -d \"\${SQUASHFS_ROOT}_work_XXXXXX\")

        ns_cleanup() {
            umount \"\${SQUASHFS_ROOT}/var/lib/containers/storage\" 2>/dev/null || true
            umount \"\${SQUASHFS_ROOT}\"                            2>/dev/null || true
            podman image unmount localhost/{{target}}-installer     2>/dev/null || true
            rm -rf \"\${OVERLAY_UPPER}\" \"\${OVERLAY_WORK}\"       2>/dev/null || true
            rm -rf \"\${CS_STAGING}\" \"\${SQUASHFS_ROOT}\"         2>/dev/null || true
        }
        trap ns_cleanup EXIT

        MOUNT=\$(podman image mount localhost/{{target}}-installer)
        PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH

        PAYLOAD_OCI='${OUTPUT_DIR}/{{target}}-payload.oci.tar'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/var/lib/containers/storage\"
        STORAGE_CONF=\"\$(mktemp '${OUTPUT_DIR}'/live-storage-XXXXXX.conf)\"
        mkdir -p \"\${SQUASHFS_STORAGE}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"/tmp/cs-runroot\"\ngraphroot = \"/vfs-storage\"\n' \
            > \"\${STORAGE_CONF}\"

        echo 'Exporting squashed OCI image to archive...'
        echo '=== Squashing '"${PAYLOAD_IMAGE}"' to single layer (avoids VFS explosion) ==='
        SQUASH_CTR=\$(buildah from --pull-never '"${PAYLOAD_IMAGE}"')
        buildah commit --squash \"\${SQUASH_CTR}\" oci-archive:\${PAYLOAD_OCI}:'"${PAYLOAD_IMAGE}"'
        buildah rm \"\${SQUASH_CTR}\"
        podman rmi '"${PAYLOAD_IMAGE}"' || true

        echo 'Importing Bluefin OCI image into squashfs containers-storage...'
        echo '=== Disk space before VFS import ==='
        df -h '${OUTPUT_DIR}'
        if [[ '$WORKDIR' != '$OUTPUT_DIR' ]]; then
            df -h '${WORKDIR}'
        fi
        podman run --rm \
            --privileged \
            -v \"\${PAYLOAD_OCI}:/payload.oci.tar:ro\" \
            -v \"\${SQUASHFS_STORAGE}:/vfs-storage\" \
            -v \"\${STORAGE_CONF}:/tmp/st.conf:ro\" \
            localhost/{{target}}-installer \
            sh -c 'mkdir -p /tmp/cs-runroot /var/tmp && CONTAINERS_STORAGE_CONF=/tmp/st.conf skopeo copy oci-archive:/payload.oci.tar:'"${PAYLOAD_IMAGE}"' containers-storage:'"${PAYLOAD_IMAGE}"''

        rm -f \"\${PAYLOAD_OCI}\" \"\${STORAGE_CONF}\"

        echo '=== Disk space after VFS import ==='
        df -h '${OUTPUT_DIR}'
        if [[ '$WORKDIR' != '$OUTPUT_DIR' ]]; then
            df -h '${WORKDIR}'
        fi
        du -sh \"\${CS_STAGING}\" 2>/dev/null || true

        echo 'Building unified squashfs source tree using bind mounts...'
        mkdir -p \"\${SQUASHFS_ROOT}\"

        FS_TYPE=\$(findmnt -n -o FSTYPE -T \"\${SQUASHFS_ROOT}\" 2>/dev/null || echo \"unknown\")
        if [[ \"\${FS_TYPE}\" == \"xfs\" || \"\${FS_TYPE}\" == \"ext4\" ]]; then
            echo \"Filesystem is \${FS_TYPE}, trying overlay\"
            if ! mount -t overlay overlay \
                -o lowerdir=\"\${MOUNT}\",upperdir=\"\${OVERLAY_UPPER}\",workdir=\"\${OVERLAY_WORK}\" \"\${SQUASHFS_ROOT}\"; then
                echo \"Overlay mount failed on \${FS_TYPE}; falling back to cp -a\"
                cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\"
            fi
        else
            echo \"Filesystem is \${FS_TYPE}, doing it the boring way\"
            cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\"
        fi

        mkdir -p \"\${SQUASHFS_ROOT}/var/lib/containers/storage\"
        mount --bind \"\${CS_STAGING}/var/lib/containers/storage\" \"\${SQUASHFS_ROOT}/var/lib/containers/storage\"
        echo '=== Disk space after creation of squashfs root ==='
        df -h '${OUTPUT_DIR}'
        if [[ '$WORKDIR' != '$OUTPUT_DIR' ]]; then
            df -h '${WORKDIR}'
        fi
        du -sh \"\${SQUASHFS_ROOT}\" 2>/dev/null || true

        SFS_LEVEL=3; SFS_BLOCK=131072
        [[ '{{compression}}' == 'release' ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
        mksquashfs \"\${SQUASHFS_ROOT}\" '${SQUASHFS}' \
            -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp

        tar -C \"\$MOUNT\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
    "

    echo "=== Disk space after squashfs, before ISO assembly ==="
    df -h "${OUTPUT_DIR}"
    du -sh "${SQUASHFS}" "${BOOT_TAR}" 2>/dev/null || true

    TMPDIR="${OUTPUT_DIR}" \
    PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
        bash "src/build-iso.sh" "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/{{target}}-live.iso"

    echo "ISO ready: ${OUTPUT_DIR}/{{target}}-live.iso"

# ── QEMU and libvirt boot / LUKS testing recipes ─────────────────────────────

# Boot a built ISO in QEMU via UEFI (OVMF) with serial console output on stdout.
boot-iso-serial target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 \
               /home/linuxbrew/.linuxbrew/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    ISO=$(ls \
        {{output_dir}}/{{target}}-live.iso \
        output/bootiso/install.iso \
        output/bootc-{{target}}*.iso \
        2>/dev/null | head -1 || true)
    if [[ -z "$ISO" ]]; then
        echo "No ISO found for '{{target}}' — run: just iso-sd-boot {{target}}" >&2
        exit 1
    fi

    OVMF_CODE=""
    for f in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /home/linuxbrew/.linuxbrew/Cellar/qemu/11.0.0/share/qemu/edk2-x86_64-code.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS_SRC=""
    for f in \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { OVMF_VARS_SRC="$f"; break; }
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found — install edk2-ovmf or ovmf" >&2
        exit 1
    fi

    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    [[ -n "$OVMF_VARS_SRC" ]] && cp "${OVMF_VARS_SRC}" "${OVMF_VARS}"
    trap "rm -f ${OVMF_VARS}" EXIT

    echo "Booting ${ISO} via UEFI — serial console below (Ctrl-A X to quit)"
    echo "SSH available on localhost:2222 (user: liveuser, password: live) if built with debug=1"
    "$QEMU" \
        -machine q35 \
        -m 4096 \
        -accel kvm \
        -cpu host \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio \
        -display none \
        -no-reboot

# Boot a built ISO in libvirt with UEFI, a target install disk, and SSH via
# the default libvirt network.
boot-libvirt-debug target:
    #!/usr/bin/bash
    set -euo pipefail

    VM_NAME="bluefin-debug"
    VM_RAM=8192
    VM_CPUS=4
    DISK_SIZE=64

    ISO=$(ls \
        {{output_dir}}/{{target}}-live.iso \
        output/bootiso/install.iso \
        output/bootc-{{target}}*.iso \
        2>/dev/null | head -1 || true)
    if [[ -z "$ISO" ]]; then
        echo "No ISO found for '{{target}}' — run: just debug=1 iso-sd-boot {{target}}" >&2
        exit 1
    fi

    OVMF_CODE=""
    for f in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /home/linuxbrew/.linuxbrew/Cellar/qemu/11.0.0/share/qemu/edk2-x86_64-code.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS=""
    for f in \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { OVMF_VARS="$f"; break; }
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found — install edk2-ovmf or ovmf" >&2
        exit 1
    fi

    sudo cp "$ISO" /var/lib/libvirt/images/${VM_NAME}.iso

    if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "VM '${VM_NAME}' already exists — swapping ISO and rebooting..."
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
        CDROM_DEV=$(sudo virsh domblklist "$VM_NAME" \
            | awk 'NR>2 && $2 == "-" {print $1; exit}')
        if [[ -z "$CDROM_DEV" ]]; then
            CDROM_DEV=$(sudo virsh domblklist "$VM_NAME" \
                | awk 'NR>2 && ($2 ~ /\.iso$/) {print $1; exit}')
        fi
        sudo virsh change-media "$VM_NAME" "$CDROM_DEV" \
            /var/lib/libvirt/images/${VM_NAME}.iso --force
        sudo virsh start "$VM_NAME"
    else
        echo "Creating libvirt VM: ${VM_NAME} (${VM_RAM}M RAM, ${VM_CPUS} vCPUs, ${DISK_SIZE}G disk)"
        sudo virt-install \
            --name "$VM_NAME" \
            --memory "$VM_RAM" --vcpus "$VM_CPUS" \
            --boot loader="${OVMF_CODE}",loader.readonly=yes,loader.type=pflash,nvram.template="${OVMF_VARS}" \
            --cdrom /var/lib/libvirt/images/${VM_NAME}.iso \
            --disk size=${DISK_SIZE},format=qcow2 \
            --network network=default \
            --graphics vnc,listen=127.0.0.1 \
            --os-variant generic \
            --tpm none \
            --noautoconsole
    fi

    MAC=$(sudo virsh domiflist "$VM_NAME" | awk '/network/{print $5}')
    echo "VM started. MAC: ${MAC}"
    echo "Waiting for DHCP lease (this takes 30-90s while the ISO boots)..."

    GUEST_IP=""
    for i in $(seq 1 60); do
        GUEST_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null \
            | awk -v mac="$MAC" '$3 == mac {split($5, a, "/"); print a[1]}' \
            | head -1)
        if [[ -n "$GUEST_IP" ]]; then
            break
        fi
        sleep 3
    done

    if [[ -z "$GUEST_IP" ]]; then
        echo "WARNING: No DHCP lease found after 3 minutes." >&2
        echo "Try: sudo virsh net-dhcp-leases default" >&2
        echo "Or:  sudo virsh console ${VM_NAME}" >&2
        exit 1
    fi

    echo ""
    echo "========================================"
    echo " SSH ready:"
    echo "   ssh liveuser@${GUEST_IP}"
    echo "   password: live"
    echo "========================================"
    echo ""
    echo "VNC: $(sudo virsh domdisplay ${VM_NAME} 2>/dev/null || echo 'unavailable')"
    echo "Serial: sudo virsh console ${VM_NAME}"
    echo "Cleanup: sudo virsh destroy ${VM_NAME} && sudo virsh undefine ${VM_NAME} --nvram"

# Run LUKS encrypted install via fisherman into the running bluefin-debug libvirt VM.
luks-install target:
    #!/usr/bin/bash
    set -euo pipefail

    VM_NAME="bluefin-debug"
    PASSPHRASE="{{luks-passphrase}}"
    DISK="/dev/sda"
    PAYLOAD_IMAGE=$(cat "{{target}}/payload_ref" | tr -d '[:space:]')
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes -o PreferredAuthentications=password"
    SSH="sshpass -p live ssh $SSH_OPTS"
    SCP="sshpass -p live scp $SSH_OPTS"

    MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | awk '/network/{print $5; exit}')
    if [[ -z "$MAC" ]]; then
        echo "ERROR: VM '${VM_NAME}' is not running."
        echo "Start it first: just debug=1 boot-libvirt-debug {{target}}"
        exit 1
    fi

    GUEST_IP=""
    echo "Looking up DHCP lease for ${VM_NAME} (${MAC})..."
    for i in $(seq 1 20); do
        GUEST_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null \
            | awk -v mac="$MAC" '$3 == mac {split($5, a, "/"); print a[1]}' \
            | head -1)
        [[ -n "$GUEST_IP" ]] && break
        sleep 3
    done
    if [[ -z "$GUEST_IP" ]]; then
        echo "ERROR: no DHCP lease found — is the VM fully booted?"
        echo "Check: sudo virsh net-dhcp-leases default"
        exit 1
    fi
    echo "Guest IP: ${GUEST_IP}"

    echo "Waiting for SSH..."
    for i in $(seq 1 30); do
        $SSH liveuser@"$GUEST_IP" true 2>/dev/null && break
        sleep 3
    done
    $SSH liveuser@"$GUEST_IP" true || { echo "ERROR: SSH timed out"; exit 1; }

    RECIPE_TMP=$(mktemp /tmp/luks-recipe-XXXXXX.json)
    trap "rm -f '${RECIPE_TMP}'" EXIT
    printf '{\n  "disk": "%s",\n  "filesystem": "btrfs",\n  "image": "containers-storage:'"${PAYLOAD_IMAGE}"'",\n  "composeFsBackend": false,\n  "bootloader": "grub2",\n  "hostname": "bluefin-luks-test",\n  "encryption": {"type": "luks-passphrase", "passphrase": "%s"},\n  "flatpaks": []\n}\n' \
        "${DISK}" "${PASSPHRASE}" > "${RECIPE_TMP}"
    $SCP "${RECIPE_TMP}" liveuser@"$GUEST_IP":/tmp/luks-recipe.json
    echo "Uploaded recipe to /tmp/luks-recipe.json"

    echo "Running fisherman install (this takes several minutes)..."
    $SSH liveuser@"$GUEST_IP" 'sudo /usr/local/bin/fisherman /tmp/luks-recipe.json'
    echo "Install finished."

    CDROM_DEV=$(sudo virsh domblklist "$VM_NAME" \
        | awk 'NR>2 && ($2 ~ /\.iso$/ || $2 == "-") {print $1; exit}')
    if [[ -n "$CDROM_DEV" ]]; then
        sudo virsh change-media "$VM_NAME" "$CDROM_DEV" --eject --force 2>/dev/null || true
        echo "ISO ejected from ${CDROM_DEV}."
    else
        echo "Warning: could not identify CD-ROM device; eject skipped."
    fi

    echo "Rebooting VM into installed system..."
    sudo virsh reboot "$VM_NAME" || $SSH liveuser@"$GUEST_IP" 'sudo reboot' || true

    echo ""
    echo "========================================"
    echo " VM is rebooting into the installed system."
    echo " Unlock LUKS: just luks-unlock {{target}}"
    echo " Watch boot:  just luks-boot {{target}}"
    echo "========================================"

# Automate LUKS passphrase entry on the bluefin-debug VM serial console.
luks-unlock target:
    #!/usr/bin/bash
    VM_NAME="bluefin-debug"
    PASSPHRASE="{{luks-passphrase}}"
    if ! sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
        echo "ERROR: VM '${VM_NAME}' is not running."
        echo "Run: just luks-install {{target}}"
        exit 1
    fi
    MAC=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | awk '/network/{print $5; exit}')
    if [[ -z "$MAC" ]]; then
        echo "ERROR: VM '${VM_NAME}' is not running."
        exit 1
    fi
    echo "Waiting for Plymouth passphrase prompt (VM MAC: ${MAC})..."
    echo "Passphrase: ${PASSPHRASE}"
    sudo python3 "src/luks-unlock.py" libvirt "$VM_NAME" "$PASSPHRASE" "$MAC"

# Connect to the serial console of the bluefin-debug VM.
luks-boot target:
    #!/usr/bin/bash
    VM_NAME="bluefin-debug"
    if ! sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
        echo "ERROR: VM '${VM_NAME}' is not running."
        echo "Run: just luks-install {{target}}"
        exit 1
    fi
    echo "Connecting to serial console (detach: Ctrl-])"
    echo "At the LUKS passphrase prompt type: {{luks-passphrase}}"
    echo ""
    sudo virsh console "$VM_NAME"

# ── QEMU-native LUKS test (used by CI; mirrors the libvirt recipes) ───────────

luks-qemu-disk := "/var/tmp/bluefin-luks-install.qcow2"
luks-qemu-monitor-live := "/tmp/bluefin-qemu-live.sock"
luks-qemu-monitor-installed := "/tmp/bluefin-qemu-installed.sock"
luks-qemu-serial-live := "/tmp/bluefin-qemu-live-serial.log"
luks-qemu-serial-installed := "/tmp/bluefin-qemu-installed-serial.log"
luks-qemu-ssh-port := "2222"

# Full end-to-end test: build the ISO then run the LUKS install + boot test.
e2e target:
    #!/usr/bin/bash
    set -euo pipefail
    echo "=== Step 1/2: Building ISO (debug={{debug}}, installer_channel={{installer_channel}}) ==="
    just debug={{debug}} installer_channel={{installer_channel}} output_dir={{output_dir}} iso-sd-boot {{target}}
    echo "=== Step 2/2: LUKS end-to-end test ==="
    sudo rm -f "{{luks-qemu-disk}}" "{{luks-qemu-monitor-live}}" "{{luks-qemu-monitor-installed}}" \
               "{{luks-qemu-serial-live}}" "{{luks-qemu-serial-installed}}"
    just luks-test-qemu {{target}}

# Run the full LUKS end-to-end test in QEMU (CI entry point).
luks-test-qemu target:
    #!/usr/bin/bash
    set -euo pipefail
    just luks-qemu-disk={{luks-qemu-disk}} luks-boot-qemu-live {{target}}
    just luks-qemu-ssh-port={{luks-qemu-ssh-port}} luks-install-qemu {{target}}
    just luks-qemu-disk={{luks-qemu-disk}} luks-boot-qemu-installed {{target}}
    just luks-qemu-monitor-installed={{luks-qemu-monitor-installed}} \
         luks-qemu-serial-installed={{luks-qemu-serial-installed}} \
         luks-unlock-qemu {{target}}

# Boot the live ISO in QEMU (daemonized) with a blank install disk attached.
luks-boot-qemu-live target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 \
               /home/linuxbrew/.linuxbrew/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    ISO=$(ls \
        {{output_dir}}/{{target}}-live.iso \
        output/bootiso/install.iso \
        output/bootc-{{target}}*.iso \
        2>/dev/null | head -1 || true)
    if [[ -z "$ISO" ]]; then
        echo "No ISO found — run: just debug=1 iso-sd-boot {{target}}" >&2
        exit 1
    fi

    OVMF_CODE=""; OVMF_VARS=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
              /home/linuxbrew/.linuxbrew/Cellar/qemu/11.0.0/share/qemu/edk2-x86_64-code.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
              /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        if [[ -f "$f" ]]; then cp "$f" /var/tmp/bluefin-qemu-live-vars.fd; OVMF_VARS=/var/tmp/bluefin-qemu-live-vars.fd; break; fi
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF firmware not found" >&2; exit 1; }

    [[ -f "{{luks-qemu-disk}}" ]] || qemu-img create -f qcow2 "{{luks-qemu-disk}}" 64G
    sudo rm -f "{{luks-qemu-monitor-live}}" "{{luks-qemu-serial-live}}"

    echo "Booting live ISO: $ISO"
    QEMU_ACCEL="-accel kvm"
    QEMU_PREFIX=""
    if ! test -r /dev/kvm 2>/dev/null; then
        if sudo test -r /dev/kvm 2>/dev/null; then
            echo "Using sudo for KVM access"
            QEMU_PREFIX="sudo"
        else
            echo "KVM not available, falling back to TCG emulation (slower)"
            QEMU_ACCEL="-accel tcg,thread=multi"
            QEMU_PREFIX=""
        fi
    fi
    $QEMU_PREFIX "$QEMU" \
        -machine q35 -cpu host -m 8192 -smp 4 $QEMU_ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=iso \
        -drive "if=none,id=disk,file={{luks-qemu-disk}},format=qcow2" \
        -device virtio-blk-pci,drive=disk \
        -netdev "user,id=net0,hostfwd=tcp::{{luks-qemu-ssh-port}}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:{{luks-qemu-monitor-live}},server,nowait" \
        -serial "file:{{luks-qemu-serial-live}}" \
        -display none \
        -daemonize
    echo "Live QEMU started (monitor: {{luks-qemu-monitor-live}})"

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password"
    echo "Waiting for live environment on port {{luks-qemu-ssh-port}}..."
    for i in $(seq 1 60); do
        if sudo grep -q "BLUEFIN_LIVE_READY" "{{luks-qemu-serial-live}}" 2>/dev/null; then
            echo "Live environment ready (serial marker seen)"
            break
        fi
        if sshpass -p live ssh $SSH_OPTS liveuser@127.0.0.1 -p {{luks-qemu-ssh-port}} true 2>/dev/null; then
            echo "Live environment ready (SSH connected)"
            break
        fi
        [[ "$i" -eq 60 ]] && { echo "ERROR: live env not ready after 5m"; sudo tail -30 "{{luks-qemu-serial-live}}" || true; exit 1; }
        sleep 5
    done

    sleep 2
    sudo socat - "UNIX-CONNECT:{{luks-qemu-monitor-live}}" \
        <<< "screendump /tmp/luks-screenshot-live.ppm" 2>/dev/null || true

# Run fisherman LUKS install via SSH into the live QEMU VM.
luks-install-qemu target:
    #!/usr/bin/bash
    set -euo pipefail
    PASSPHRASE="{{luks-passphrase}}"
    DISK="/dev/vda"
    PAYLOAD_IMAGE=$(cat "{{target}}/payload_ref" | tr -d '[:space:]')
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
    SSH="sshpass -p live ssh $SSH_OPTS liveuser@127.0.0.1 -p {{luks-qemu-ssh-port}}"
    SCP="sshpass -p live scp $SSH_OPTS -P {{luks-qemu-ssh-port}}"

    RECIPE_TMP=$(mktemp /tmp/luks-recipe-XXXXXX.json)
    trap "rm -f '${RECIPE_TMP}'" EXIT
    printf '{\n  "disk": "%s",\n  "filesystem": "btrfs",\n  "image": "containers-storage:'"${PAYLOAD_IMAGE}"'",\n  "composeFsBackend": false,\n  "bootloader": "grub2",\n  "hostname": "bluefin-luks-test",\n  "encryption": {"type": "luks-passphrase", "passphrase": "%s"},\n  "flatpaks": []\n}\n' \
        "${DISK}" "${PASSPHRASE}" > "${RECIPE_TMP}"
    $SCP "${RECIPE_TMP}" liveuser@127.0.0.1:/tmp/luks-recipe.json
    echo "Uploaded recipe — running fisherman (takes several minutes)..."
    $SSH 'sudo /usr/local/bin/fisherman /tmp/luks-recipe.json'
    echo "Install complete. Shutting down live QEMU..."
    echo "system_powerdown" | sudo socat - "UNIX-CONNECT:{{luks-qemu-monitor-live}}" 2>/dev/null || true
    sleep 5
    echo "quit" | sudo socat - "UNIX-CONNECT:{{luks-qemu-monitor-live}}" 2>/dev/null || true

# Boot the installed disk in QEMU (no ISO). Called after luks-install-qemu.
luks-boot-qemu-installed target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 \
               /home/linuxbrew/.linuxbrew/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    OVMF_CODE=""; OVMF_VARS=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
              /home/linuxbrew/.linuxbrew/Cellar/qemu/11.0.0/share/qemu/edk2-x86_64-code.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
              /usr/share/edk2/ovmf/OVMF_VARS.fd; do
        if [[ -f "$f" ]]; then cp "$f" /var/tmp/bluefin-qemu-installed-vars.fd; OVMF_VARS=/var/tmp/bluefin-qemu-installed-vars.fd; break; fi
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF firmware not found" >&2; exit 1; }

    sudo rm -f "{{luks-qemu-monitor-installed}}" "{{luks-qemu-serial-installed}}"

    echo "Booting installed disk: {{luks-qemu-disk}}"
    QEMU_ACCEL="-accel kvm"
    QEMU_PREFIX=""
    if ! test -r /dev/kvm 2>/dev/null; then
        if sudo test -r /dev/kvm 2>/dev/null; then
            echo "Using sudo for KVM access"
            QEMU_PREFIX="sudo"
        else
            echo "KVM not available, falling back to TCG emulation (slower)"
            QEMU_ACCEL="-accel tcg,thread=multi"
            QEMU_PREFIX=""
        fi
    fi
    $QEMU_PREFIX "$QEMU" \
        -machine q35 -cpu host -m 8192 -smp 4 $QEMU_ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -drive "if=none,id=disk,file={{luks-qemu-disk}},format=qcow2" \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -monitor "unix:{{luks-qemu-monitor-installed}},server,nowait" \
        -serial "file:{{luks-qemu-serial-installed}}" \
        -display none \
        -daemonize
    echo "Installed QEMU started (monitor: {{luks-qemu-monitor-installed}})"

    for i in $(seq 1 15); do
        [[ -S "{{luks-qemu-monitor-installed}}" ]] && break
        sleep 2
    done

# Send LUKS passphrase to installed QEMU VM via monitor screendump + sendkey.
luks-unlock-qemu target:
    #!/usr/bin/bash
    set -euo pipefail
    PASSPHRASE="{{luks-passphrase}}"
    echo "Unlocking LUKS on installed QEMU VM..."
    echo "Passphrase: ${PASSPHRASE}"
    sudo python3 "src/luks-unlock.py" qemu \
        "{{luks-qemu-monitor-installed}}" \
        "$PASSPHRASE" \
        "{{luks-qemu-serial-installed}}"

    for label in "Plymouth prompt" "Final boot"; do
        key=$(echo "$label" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
        bash "src/show-screenshot.sh" "/tmp/luks-screenshot-${key}.ppm" "$label" || true
    done
