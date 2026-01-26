#!/usr/bin/env bash

set -eoux pipefail

IMAGE_INFO="$(cat /usr/share/ublue-os/image-info.json)"
IMAGE_TAG="$(jq -c -r '."image-tag"' <<<"$IMAGE_INFO")"
IMAGE_REF="$(jq -c -r '."image-ref"' <<<"$IMAGE_INFO")"
IMAGE_REF="${IMAGE_REF##*://}"
# sbkey='https://github.com/ublue-os/akmods/raw/main/certs/public_key.der'

# Configure Live Environment

# Setup dock
tee /usr/share/glib-2.0/schemas/zz2-org.gnome.shell.gschema.override <<EOF
[org.gnome.shell]
welcome-dialog-last-shown-version='4294967295'
favorite-apps = ['anaconda.desktop', 'documentation.desktop', 'discourse.desktop', 'org.mozilla.firefox.desktop', 'org.gnome.Nautilus.desktop']
EOF

# Disable suspend/sleep during live environment and initial setup
# This prevents the system from suspending during installation or first-boot user creation
tee /usr/share/glib-2.0/schemas/zz3-bluefin-installer-power.gschema.override <<EOF
[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0

[org.gnome.desktop.session]
idle-delay=uint32 0
EOF

glib-compile-schemas /usr/share/glib-2.0/schemas

systemctl disable rpm-ostree-countme.service
systemctl disable tailscaled.service
systemctl disable bootloader-update.service
# systemctl disable brew-upgrade.timer
# systemctl disable brew-update.timer
# systemctl disable brew-setup.service
systemctl disable rpm-ostreed-automatic.timer
systemctl disable uupd.timer
systemctl disable ublue-system-setup.service
# systemctl disable ublue-guest-user.service
# systemctl disable check-sb-key.service
# systemctl --global disable ublue-flatpak-manager.service
systemctl --global disable podman-auto-update.timer
systemctl --global disable ublue-user-setup.service

# Configure Anaconda

# remove anaconda-liveinst to be replaced with anaconda-live
dnf remove -y anaconda-liveinst

# Install Anaconda, Webui if >= F42
SPECS=(
    "libblockdev"
    "libblockdev-lvm"
    "libblockdev-dm"
    "anaconda"
    "anaconda-live"
    "anaconda-webui"
    "firefox"
    "openssh-server"
    "tmux" # Required for anaconda.service
    "dbus-x11" # Required for dbus communication in some modules
    "libblockdev-plugins-all" # Required for storage module
    "gum" # Required for standalone dakota-install
    "cryptsetup" # Required for LUKS
    "btrfs-progs" # Required for Btrfs
    "dosfstools" # Required for mkfs.fat
    "gdisk" # Required for sgdisk
)

dnf copr enable -y jreilly1821/anaconda-webui

dnf install -y --allowerasing --nobest "${SPECS[@]}"

# Build and install custom bootc latest release
echo "Building bootc latest release from source..."
dnf install -y dnf-plugins-core epel-release
dnf config-manager --set-enabled crb
dnf install -y git cargo openssl-devel libzstd-devel glib2-devel gcc ostree-devel curl jq

# Get latest bootc release
LATEST_BOOTC_RELEASE=$(curl -s https://api.github.com/repos/bootc-dev/bootc/releases/latest | jq -r .tag_name)
git clone --branch "$LATEST_BOOTC_RELEASE" --depth 1 https://github.com/bootc-dev/bootc.git /tmp/bootc
pushd /tmp/bootc
cargo build --release
cp target/release/bootc /usr/bin/bootc
popd

# Verify bootc version
/usr/bin/bootc --version | grep "${LATEST_BOOTC_RELEASE#v}" || { echo "bootc version is not $LATEST_BOOTC_RELEASE"; exit 1; }

# Cleanup build artifacts and dependencies to reduce image size
rm -rf /tmp/bootc
dnf remove -y git cargo openssl-devel libzstd-devel glib2-devel gcc ostree-devel
dnf autoremove -y


# Fix the wrong dir for webui
sed -i 's|/usr/libexec/webui-desktop|/usr/libexec/anaconda/webui-desktop|g' /bin/liveinst

# HOTFIX: Fix Blivet/Dasbus import error in Anaconda Storage Module
# Resolves ModuleNotFoundError: No module named 'blivet.safe_dbus'
sed -i "s/from blivet.safe_dbus import SafeDBusError/from dasbus.error import DBusError as SafeDBusError/g" /usr/lib64/python3.12/site-packages/pyanaconda/modules/storage/iscsi/discover.py

echo "Adding dakota-install script (Advanced)..."
cat << 'DAKOTA_INSTALL_EOF' > /usr/bin/dakota-install
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
DAKOTA_INSTALL_EOF
chmod +x /usr/bin/dakota-install

echo "Pre-pulling Dakota image..."
podman pull ghcr.io/projectbluefin/dakota:latest || echo "Warning: Failed to pre-pull Dakota image."

# Anaconda Profile Detection

# Bluefin
tee /etc/anaconda/profile.d/bluefin-lts.conf <<'EOF'
# Anaconda configuration file for Bluefin LTS

[Profile]
# Define the profile.
profile_id = bluefin

[Profile Detection]
# Match os-release values
os_id = bluefin-lts

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = centos
menu_auto_hide = True

[Storage]
file_system_type = xfs
default_partitioning =
    /     (min 5 GiB, max 70 GiB)
    /var  (min 5 GiB)

[User Interface]
custom_stylesheet = /usr/share/anaconda/pixmaps/silverblue/fedora-silverblue.css
hidden_spokes =
    NetworkSpoke
    PasswordSpoke
    UserSpoke
hidden_webui_pages =
    anaconda-screen-accounts

[Localization]
use_geolocation = False
EOF

sed -i 's/^ID=.*/ID=bluefin-lts/' /usr/lib/os-release
echo "VARIANT_ID=bluefin-lts" >>/usr/lib/os-release

# Configure
. /etc/os-release
# if [[ "$IMAGE_TAG" =~ gts ]]; then
#     echo "Bluefin ${IMAGE_TAG^^} release $VERSION_ID (${VERSION_CODENAME:=Big Bird})" >/etc/system-release
# else
echo "Bluefin release $VERSION_ID Achillobator" >/etc/system-release
sed -i 's/ANACONDA_PRODUCTVERSION=.*/ANACONDA_PRODUCTVERSION=""/' /usr/{,s}bin/liveinst || true
sed -i 's|^Icon=.*|Icon=/usr/share/pixmaps/fedora-logo-icon.png|' /usr/share/applications/liveinst.desktop || true
sed -i 's| Fedora| Bluefin|' /usr/share/anaconda/gnome/fedora-welcome || true
sed -i 's|Activities|in the dock|' /usr/share/anaconda/gnome/fedora-welcome || true

# Get Artwork
git clone --depth=1 https://github.com/projectbluefin/branding.git /tmp/branding
mkdir -p /usr/share/anaconda/pixmaps/silverblue
cp -r /tmp/branding/anaconda/* /usr/share/anaconda/pixmaps/silverblue/
rm -rf /tmp/branding

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=$IMAGE_REF:$IMAGE_TAG --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
EOF

# Signed Images
tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $IMAGE_REF:$IMAGE_TAG
%end
EOF

# # Disable Fedora Flatpak
# tee /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks <<'EOF'
# %post --erroronfail
# systemctl disable flatpak-add-fedora-repos.service
# %end
# EOF

# Install Flatpaks
tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/$deployment.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak "$target"
%end
EOF

# Fetch the Secureboot Public Key
# curl --retry 15 -Lo /etc/sb_pubkey.der "$sbkey"

# # Enroll Secureboot Key
# tee /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks <<'EOF'
# %post --erroronfail --nochroot
# set -oue pipefail

# readonly ENROLLMENT_PASSWORD="universalblue"
# readonly SECUREBOOT_KEY="/etc/sb_pubkey.der"

# if [[ ! -d "/sys/firmware/efi" ]]; then
#     echo "EFI mode not detected. Skipping key enrollment."
#     exit 0
# fi

# if [[ ! -f "$SECUREBOOT_KEY" ]]; then
#     echo "Secure boot key not provided: $SECUREBOOT_KEY"
#     exit 0
# fi

# SYS_ID="$(cat /sys/devices/virtual/dmi/id/product_name)"
# if [[ ":Jupiter:Galileo:" =~ ":$SYS_ID:" ]]; then
#     echo "Steam Deck hardware detected. Skipping key enrollment."
#     exit 0
# fi

# mokutil --timeout -1 || :
# echo -e "$ENROLLMENT_PASSWORD\n$ENROLLMENT_PASSWORD" | mokutil --import "$SECUREBOOT_KEY" || :
# %end
# EOF

sed -i -e "s/Fedora/Bluefin/g" -e "s/CentOS/Bluefin/g" /usr/share/anaconda/gnome/org.fedoraproject.welcome-screen.desktop
