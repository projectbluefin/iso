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
systemctl disable rpm-ostreed-automatic.timer
systemctl disable uupd.timer
systemctl disable ublue-system-setup.service
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

# Create Firefox Flatpak Wrapper
echo "Creating Firefox Flatpak wrapper..."
cat << 'EOF' > /usr/bin/firefox
#!/usr/bin/env bash
exec flatpak run org.mozilla.firefox "\$@"
EOF
chmod +x /usr/bin/firefox


# Fix the wrong dir for webui
sed -i 's|/usr/libexec/webui-desktop|/usr/libexec/anaconda/webui-desktop|g' /bin/liveinst

# HOTFIX: Fix Blivet/Dasbus import error in Anaconda Storage Module
# Resolves ModuleNotFoundError: No module named 'blivet.safe_dbus'
sed -i "s/from blivet.safe_dbus import SafeDBusError/from dasbus.error import DBusError as SafeDBusError/g" /usr/lib64/python3.12/site-packages/pyanaconda/modules/storage/iscsi/discover.py


# Dakota Install Script
if [[ "${ENABLE_DAKOTA:-false}" == "true" ]]; then
    echo "Adding dakota-install script (Advanced)..."
    if [ -f "/app/dakota-install.sh" ]; then
        cp /app/dakota-install.sh /usr/bin/dakota-install
        chmod +x /usr/bin/dakota-install
    else
        echo "Error: /app/dakota-install.sh not found!"
        exit 1
    fi

    echo "Pre-pulling Dakota image..."
    podman pull ghcr.io/projectbluefin/dakota:latest || echo "Warning: Failed to pre-pull Dakota image."
else
    echo "Dakota installer disabled for this variant."
fi

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

# Install Flatpaks
tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/$deployment.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak "$target"
%end
EOF


sed -i -e "s/Fedora/Bluefin/g" -e "s/CentOS/Bluefin/g" /usr/share/anaconda/gnome/org.fedoraproject.welcome-screen.desktop
