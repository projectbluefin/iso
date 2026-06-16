#!/usr/bin/bash
# Live-environment setup for the Bluefin ISO installer image.
#
# Runs inside the final Bluefin container stage with:
#   --cap-add sys_admin --security-opt label=disable
#
# At this point the initramfs has already been replaced (by the Debian
# initramfs-builder stage) with a dmsquash-live capable one.  This script
# handles the runtime live-environment: user, GDM autologin, bootc-installer
# configuration + autostart, and Flatpak pre-installation.

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── VERSION_ID ────────────────────────────────────────────────────────────────
# Ensure VERSION_ID is present in os-release for image-builder and bootc tooling.
if grep -q '^VERSION_ID=' /usr/lib/os-release 2>/dev/null; then
    sed -i 's/^VERSION_ID=.*/VERSION_ID=latest/' /usr/lib/os-release
else
    echo 'VERSION_ID=latest' >> /usr/lib/os-release
fi

# ── Live user ─────────────────────────────────────────────────────────────────
# Create a passwordless live user for the live session.
useradd --create-home --uid 1000 --user-group \
    --comment "Live User" liveuser || true
passwd --delete liveuser

# Debug builds only: enable SSH so the live session is reachable for testing.
# Never enabled in production ISOs.
if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "liveuser:live" | chpasswd

    # Enable root login with a known password so hotfixes can be applied
    # directly via `ssh root@<ip>` or `su -` without going through sudo.
    passwd --unlock root
    echo "root:root" | chpasswd

    # Enable sshd: the Bluefin preset marks sshd disabled, so a plain
    # wants symlink gets overridden at first boot.  A preset file in
    # /etc/systemd/system-preset/ takes priority over /usr/lib and forces it on.
    mkdir -p /etc/systemd/system-preset
    echo "enable sshd.service" > /etc/systemd/system-preset/90-live-debug.preset
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/sshd.service \
        /etc/systemd/system/multi-user.target.wants/sshd.service

    cat >> /etc/ssh/sshd_config << 'SSHEOF'
PermitEmptyPasswords no
PasswordAuthentication yes
PermitRootLogin yes
SSHEOF

    # Open SSH through firewalld so port 22 is reachable from the host
    mkdir -p /etc/firewalld/zones
    cat > /etc/firewalld/zones/public.xml << 'FWEOF'
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <service name="ssh"/>
  <service name="mdns"/>
  <service name="dhcpv6-client"/>
</zone>
FWEOF

    # Print SSH connection info to the serial console once the network is up.
    cat > /usr/lib/systemd/system/debug-ssh-banner.service << 'BANNEREOF'
[Unit]
Description=Print SSH connection info to serial console
After=sshd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  IP=$(hostname -I | awk "{print \\$1}"); \
  echo ""; \
  echo "========================================"; \
  echo " DEBUG SSH READY"; \
  echo " ssh liveuser@${IP:-<no-ip>}  (password: live)"; \
  echo " ssh root@${IP:-<no-ip>}      (password: root)"; \
  echo "========================================"; \
  echo ""'
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
BANNEREOF
    systemctl enable debug-ssh-banner.service
fi

# Give liveuser passwordless sudo so the live session is fully manageable
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# Skip gnome-initial-setup in the live session so GNOME Shell starts directly
mkdir -p /home/liveuser/.config
touch /home/liveuser/.config/gnome-initial-setup-done
chown -R liveuser:liveuser /home/liveuser/.config

# Remove gnome-tour desktop file so GNOME Shell can never launch it on the
# live ISO regardless of dconf state.
rm -f /usr/share/applications/org.gnome.Tour.desktop

# Override the bootc-installer flatpak's desktop entry so it appears as
# "Bluefin Installer" with the bluefin icon instead of "bootc Installer (Devel)".
# On Fedora/ostree /usr/local is a symlink to /var/usrlocal — resolve it.
LOCAL_APPS=$(realpath /usr/local 2>/dev/null || echo /usr/local)/share/applications
mkdir -p "${LOCAL_APPS}" || { LOCAL_APPS=/usr/share/applications; mkdir -p "${LOCAL_APPS}"; }
cat > "${LOCAL_APPS}/org.bootcinstaller.Installer.Devel.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Name=Bluefin Installer
Exec=/usr/bin/flatpak run --branch=master --arch=x86_64 --command=bootc-installer org.bootcinstaller.Installer.Devel
Icon=bluefin
Terminal=false
Type=Application
Categories=GTK;System;Settings;
StartupNotify=true
X-Flatpak=org.bootcinstaller.Installer.Devel
DESKTOPEOF

# Suppress the GNOME Tour / "Welcome to Bluefin" dialog on first login.
mkdir -p /etc/dconf/db/distro.d /etc/dconf/db/distro.d/locks
cat > /etc/dconf/db/distro.d/50-live-iso << 'DCONFEOF'
[org/gnome/shell]
welcome-dialog-last-shown-version='999'
favorite-apps=['bluefin-installer.desktop', 'org.mozilla.firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Console.desktop']

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
power-button-action='nothing'
DCONFEOF

cat > /etc/dconf/db/distro.d/locks/50-live-iso << 'LOCKSEOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/desktop/session/idle-delay
/org/gnome/shell/favorite-apps
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
LOCKSEOF

dconf update

# Mask systemd sleep/suspend targets so the kernel never suspends regardless
# of what any userspace tool requests — belt-and-suspenders for the install.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# ── GDM autologin ─────────────────────────────────────────────────────────────
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'GDMEOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
GDMEOF

# ── /var/tmp tmpfs ────────────────────────────────────────────────────────────
# The live overlayfs puts /var on a small RAM overlay.  bootc needs substantial
# space in /var/tmp when staging an install; mount a dedicated tmpfs there.
cat > /usr/lib/systemd/system/var-tmp.mount << 'UNITEOF'
[Unit]
Description=Large tmpfs for /var/tmp in the live environment

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=8G,nr_inodes=1m

[Install]
WantedBy=local-fs.target
UNITEOF
systemctl enable var-tmp.mount

# ── Live-ready marker service ─────────────────────────────────────────────────
# Prints BLUEFIN_LIVE_READY to the serial console after display-manager.service
# starts.  CI boot verification greps for this token in the serial log.
cat > /usr/lib/systemd/system/live-ready.service << 'LREOF'
[Unit]
Description=Live environment ready marker
After=display-manager.service
Requires=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/echo BLUEFIN_LIVE_READY
StandardOutput=tty
TTYPath=/dev/ttyS0

[Install]
WantedBy=multi-user.target
LREOF
systemctl enable live-ready.service

# fisherman (bootc-installer backend) creates /var/fisherman-tmp and bind-mounts
# it to /var/tmp.  Pre-create the directory so it exists at boot time.
mkdir -p /var/fisherman-tmp

# ── Bluefin icon ──────────────────────────────────────────────────────────────
# Install icon in hicolor theme hierarchy for desktop integration
mkdir -p /usr/share/icons/hicolor/{16x16,24x24,32x32,48x48,64x64,128x128,256x256,512x512}/apps
for size in 16 24 32 48 64 128 256 512; do
  install -Dm644 "$SCRIPT_DIR/icons/hicolor/${size}x${size}/apps/bluefin.png" \
    "/usr/share/icons/hicolor/${size}x${size}/apps/bluefin.png"
done
# Symlink 512×512 to pixmaps for compatibility
install -Dm644 "$SCRIPT_DIR/icons/hicolor/512x512/apps/bluefin.png" /usr/share/pixmaps/bluefin.png
gtk-update-icon-cache /usr/share/icons/hicolor/

# ── Installer tour images ─────────────────────────────────────────────────────
# The bootc-installer Flatpak has --filesystem=host so absolute paths are visible.
mkdir -p /usr/share/bootc-installer/images
install -Dm644 "$SCRIPT_DIR/images/bluefin.png" /usr/share/bootc-installer/images/bluefin.png

# ── Installer configuration ───────────────────────────────────────────────────
# The bootc-installer reads both overrides from /etc/bootc-installer/:
#   images.json — locks the catalog to Bluefin only
#   recipe.json — sets distro branding, tour slides, and install steps
mkdir -p /etc/bootc-installer
cp "$SCRIPT_DIR/etc/bootc-installer/images.json" /etc/bootc-installer/images.json
cp "$SCRIPT_DIR/etc/bootc-installer/recipe.json" /etc/bootc-installer/recipe.json
# Flag file read by the installer to activate live ISO mode.
touch /etc/bootc-installer/live-iso-mode

# ── Installer autostart ───────────────────────────────────────────────────────
# App ID differs between stable and dev channel builds.
INSTALLER_APP_ID="org.bootcinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"

# Create a wrapper script to handle the delay safely without desktop entry quoting issues
cat > /usr/bin/autostart-installer << EOF
#!/usr/bin/bash
sleep 5
exec flatpak run --filesystem=/etc/bootc-installer:ro --env=VANILLA_CUSTOM_RECIPE=/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
EOF
chmod +x /usr/bin/autostart-installer

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/tuna-installer.desktop << DTEOF
[Desktop Entry]
Name=Bluefin Installer
Exec=/usr/bin/autostart-installer
Icon=bluefin
Type=Application
X-GNOME-Autostart-enabled=true
DTEOF

# A matching entry in /usr/share/applications/ lets GNOME Shell reference this
# app in the dock via favorite-apps.
mkdir -p /usr/share/applications
cat > /usr/share/applications/bluefin-installer.desktop << DTEOF
[Desktop Entry]
Name=Bluefin Installer
Comment=Install Bluefin to your computer
Exec=flatpak run --filesystem=/etc/bootc-installer:ro --env=VANILLA_CUSTOM_RECIPE=/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=bluefin
Type=Application
Categories=System;
NoDisplay=false
DTEOF

# ── Polkit rules for live installer ───────────────────────────────────────────
# The installer's polkit action (org.tunaos.Installer.install) defaults to
# auth_admin.  On the live ISO we want liveuser to install without any password
# prompt.  Two complementary mechanisms are used for belt-and-suspenders:
#
#  1. Policy override: write the action definition directly with allow_active=yes
#     so polkit approves it at the policy level before rules even run.
#
#  2. JS rule: belt-and-suspenders fallback that grants YES for liveuser.

# fisherman symlink — installer calls /usr/local/bin/fisherman via pkexec
INSTALLER_APP_DIR=$(find /var/lib/flatpak/app/${INSTALLER_APP_ID} -name fisherman -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
if [ -n "$INSTALLER_APP_DIR" ]; then
    mkdir -p /usr/local/bin
    ln -sf "${INSTALLER_APP_DIR}/fisherman" /usr/local/bin/fisherman
fi

# Policy file: allow any active session to run the installer without auth.
mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy << 'POLICYEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLICYEOF

# JS rule: grant YES for liveuser on both custom + generic polkit exec actions.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.policykit.exec" ||
         action.id === "org.tunaos.Installer.install") &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

# ── Live network defaults ─────────────────────────────────────────────────────
# /etc/hostname is bind-mounted by the container runtime during builds; writing
# to it in a RUN step doesn't persist into the image layer.  Use tmpfiles.d to
# create it at first boot instead.
mkdir -p /usr/lib/tmpfiles.d
echo 'f /etc/hostname 0644 - - - bluefin-live' > /usr/lib/tmpfiles.d/live-hostname.conf

# ── Container storage ────────────────────────────────────────────────────────
# Use overlay driver for space-efficient container operations.
# The embedded OCI in the squashfs is available via skopeo/podman pull
# from the registry. Overlay avoids VFS's full-image copy per layer.
cat > /etc/containers/storage.conf << 'STOREOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
additionalimagestores = [
  "/var/lib/containers/storage-additional"
]
STOREOF

# fisherman handles scratch space, OCI export, and GPT partition setup natively.
