#!/usr/bin/env bash

set -exo pipefail

source /etc/os-release

# Import Terra keys
    echo "RakuOS overlay sync: importing Terra GPG keys for Fedora ${VERSION_ID}..."
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}/key.asc"
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-mesa/key.asc"
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-multimedia/key.asc"
    #rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-nvidia/key.asc"

# Disable overlay services in live enviroment
systemctl disable --now rakuos-overlay-sync.service \
          rakuos-overlay-mount.service

# sudo requires drop-in files to be owned by root and not be writable by others
chown root:root /etc/sudoers.d/rakuos-software
chmod 0440 /etc/sudoers.d/rakuos-software

# add flatpak
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak update --system --appstream -y

# Remove all versionlocks, in order to avoid dependency issues
dnf -qy versionlock clear

# Install Anaconda
dnf install -qy --enable-repo=fedora-cisco-openh264 --allowerasing anaconda-live libblockdev-{btrfs,lvm,dm}

mkdir -p /var/lib/rpm-state # Needed for Anaconda Web UI

    # Read packages into array
    mapfile -t PACKAGES < <(
        grep -v '^\s*#' "/usr/share/rakuos/packages-live.list" \
        | grep -v '^\s*$' \
        | sed 's/\s*#.*//' \
        | tr -s ' \t' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$'
    ) || true

dnf install -y --refresh "${PACKAGES[@]}"

# Utilities for displaying a dialog prompting users to review secure boot documentation
dnf install -qy --setopt=install_weak_deps=0 qrencode yad

# The installed image already carries the real prebaked overlay state.
# For the live squashfs, wipe that state back out so the live environment stays
# simple and does not try to carry a prebaked installed-system overlay around.
echo "Resetting RakuOS overlay state for live ISO..."
rm -rf /var/lib/rakuos
mkdir -p /var/lib/rakuos
if [[ -f /usr/share/rakuos/packages-live.list ]]; then
    cp /usr/share/rakuos/packages-live.list /var/lib/rakuos/packages.list
    sed -i -e '$a\' /var/lib/rakuos/packages.list
fi

# Variables
imageref="$(podman images --format '{{ index .Names 0 }}\n' 'rakuos*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"
imagetag="$(podman images --format '{{ .Tag }}\n' "$imageref" | head -1)"
SECUREBOOT_KEY="/usr/share/rakuos/sb_pubkey.der"
SECUREBOOT_DOC_URL="https://rakuos.org/docs/secure-boot"
SECUREBOOT_DOC_URL_QR="/usr/share/rakuos/secure_boot_qr.png"

# Rakuos anaconda profile
: ${VARIANT_ID:?}

echo "Rakuos release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

# Get Artwork
git clone --depth 1 --quiet https://gitlab.com/rakuos/iso/iso-base.git /root/packages

# Installer icon
_icon=/root/packages/installer/branding/rakuos-installer.svg
_icon_symbol=/root/packages/installer/branding/rakuos-installer-symbolic.svg
if [[ -f $_icon ]]; then
    for f in \
        /usr/share/icons/hicolor/48x48/apps/org.fedoraproject.AnacondaInstaller.svg \
        /usr/share/icons/hicolor/scalable/apps/org.fedoraproject.AnacondaInstaller.svg; do
        cp "$_icon" "$f"
    done
    cp "$_icon_symbol" /usr/share/icons/hicolor/symbolic/apps/org.fedoraproject.AnacondaInstaller-symbolic.svg
fi
unset -v _icon
unset -v _icon_symbol

# Hardcode installer icon path so WhiteSur icon theme doesn't override it
sed -i 's|^Icon=.*|Icon=/usr/share/icons/hicolor/scalable/apps/org.fedoraproject.AnacondaInstaller.svg|' \
    /usr/share/applications/liveinst.desktop 2>/dev/null || true

# Default Kickstart
cat <<EOF >>/usr/share/anaconda/interactive-defaults.ks

# Create log directory
%pre
mkdir -p /tmp/anacoda_custom_logs
%end

# Check CPU is x86-64-v3 compatible (required by the RakuOS CachyOS kernel)
%pre --log=/tmp/anacoda_custom_logs/cpu_compat_check.log
IS_V3=true
for flag in avx2 bmi2 fma; do
    grep -qw "\$flag" /proc/cpuinfo || IS_V3=false
done
if [[ "\$IS_V3" == "false" ]]; then
    run0 --user=liveuser yad \
        --on-top \
        --fixed \
        --timeout=0 \
        --title="Incompatible CPU" \
        --button="Exit Installer":0 \
        --image=dialog-error \
        --text="<span size='x-large'><b>Your CPU is not compatible with RakuOS</b></span>\n\nRakuOS requires an <b>x86-64-v3</b> compatible processor.\nThis requires AVX2, BMI2, and FMA instruction support.\n\nMinimum supported CPUs:\n  • Intel: Haswell (2013) or newer\n  • AMD: Zen 1 (2017) or newer\n\nInstallation cannot continue on this system."
    pkill liveinst || true
    pkill firefox || true
fi
%end

# Check if there is a bitlocker partition and ask the user to disable it
%pre --erroronfail --log=/tmp/anacoda_custom_logs/detect_bitlocker.log
DOCS_QR=/tmp/detect_bitlocker_qr.png
IS_BITLOCKER=\$(lsblk -o FSTYPE --json | jq '.blockdevices | map(select(.fstype == "BitLocker")) | . != []')
{ WARNING_MSG="\$(</dev/stdin)"; } << 'WARNINGEOF'
<span size="x-large">Windows Bitlocker partition detected</span>

It might interrupt the installation process.
In such case, please, do <b>one</b> of the following:
    a) Disconnect its storage drive.
    b) Disable Bitlocker in Windows.
    c) Delete it in GNOME Disks.

Do you wish to continue?
WARNINGEOF

if [[ \$IS_BITLOCKER =~ true ]]; then
    qrencode -o \$DOCS_QR "https://www.wikihow.com/Turn-Off-BitLocker"
    _EXITLOCK=1
    _RETCODE=0
    while [[ \$_EXITLOCK -ne 0 ]]; do
        run0 --user=liveuser yad \
            --on-top \
            --timeout=10 \
            --image=\$DOCS_QR \
            --text="\$WARNING_MSG" \
            --button="Yes, I'm aware, continue":0 --button="Cancel installation":10
        _RETCODE=\$?
        case \$_RETCODE in
            0) _EXITLOCK=0; ;;
            10) _EXITLOCK=0; pkill liveinst; pkill firefox; exit 0 ;;
        esac
    done
fi
%end

# Remove the efi dir, must match efi_dir from the profile config
%pre-install --erroronfail
rm -rf /mnt/sysroot/boot/efi/EFI/fedora
%end

# Relabel the boot partition for the
%pre-install --erroronfail --log=/tmp/anacoda_custom_logs/repartitioning.log
set -x
xboot_dev=\$(findmnt -o SOURCE --nofsroot --noheadings -f --target /mnt/sysroot/boot)
if [[ -z \$xboot_dev ]]; then
  echo "ERROR: xboot_dev not found"
  exit 1
fi
e2label "\$xboot_dev" "rakuos_xboot"
%end

# Open a dialog with the installation logs
%onerror
run0 --user=liveuser yad \
    --timeout=0 \
    --text-info \
    --no-buttons \
    --width=600 \
    --height=400 \
    --text="An error occurred during installation. Please report this issue to the developers." \
    < /tmp/anaconda.log
%end

$(
    if [[ $imageref == *-deck* ]]; then
        cat <<EOCAT
# Set default user
user --name=rakuos --password=rakuos --plaintext --groups=wheel
EOCAT
    fi
)

ostreecontainer --url=$imageref:$imagetag --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/flatpak-restore-selinux-labels.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
%include /usr/share/anaconda/post-scripts/secureboot-docs.ks

EOF

# Enroll Secure Boot Key
cat <<EOF >>/usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
%post --erroronfail --nochroot --log=/tmp/anacoda_custom_logs/secureboot-enroll-key.log
set -oue pipefail

readonly ENROLLMENT_PASSWORD="rakuos"
readonly SECUREBOOT_KEY="$SECUREBOOT_KEY"

if [[ ! -d "/sys/firmware/efi" ]]; then
    echo "EFI mode not detected. Skipping key enrollment."
    exit 0
fi

if [[ ! -f "\$SECUREBOOT_KEY" ]]; then
    echo "Secure boot key not found: \$SECUREBOOT_KEY"
    exit 0
fi

mokutil --timeout -1 || :
echo -e "\$ENROLLMENT_PASSWORD\n\$ENROLLMENT_PASSWORD" | mokutil --import "\$SECUREBOOT_KEY" || :
%end
EOF

# Secure Boot docs dialog
cat <<EOF >>/usr/share/anaconda/post-scripts/secureboot-docs.ks
%post --nochroot --log=/tmp/anacoda_custom_logs/secureboot-docs.log
SECUREBOOT_KEY="$SECUREBOOT_KEY"
SECUREBOOT_DOC_URL="$SECUREBOOT_DOC_URL"
SECUREBOOT_DOC_URL_QR="$SECUREBOOT_DOC_URL_QR"

LC_ALL=C mokutil -t "\$SECUREBOOT_KEY" 2>/dev/null | grep -q "is already in the enrollment request" && \
    run0 --user=liveuser yad \
        --timeout=0 --on-top --button=Ok:0 \
        --image="\$SECUREBOOT_DOC_URL_QR" \
        --text="<b>Secure Boot Key enrollment queued</b>\n\nOn your next reboot, a blue screen will appear.\nSelect <b>Enroll MOK</b> and enter the password: <b>rakuos</b>\n\nFor more info visit: \$SECUREBOOT_DOC_URL"
%end
EOF

qrencode -o "$SECUREBOOT_DOC_URL_QR" "$SECUREBOOT_DOC_URL"

# Signed Images
cat <<EOF >>/usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%post --erroronfail --log=/tmp/anacoda_custom_logs/bootc-switch.log
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $imageref:$imagetag
%end
EOF

### Desktop-enviroment specific tweaks ###
# Setup script to show dialog popups at login

# Use GSK_RENDERER=gl for nvidia, workaround for GTK apps not opening.
if [[ $imageref == *-nvidia* ]]; then
    mkdir -p /etc/environment.d /etc/skel/.config/environment.d
    echo "GSK_RENDERER=gl" >>/etc/environment.d/99-nvidia-fix.conf
    echo "GSK_RENDERER=gl" >>/etc/skel/.config/environment.d/99-nvidia-fix.conf
fi

# Reenable noveau.
if [[ $imageref == *-nvidia* ]]; then
    for pkg in nvidia-gpu-firmware mesa-vulkan-drivers; do
        dnf -yq reinstall --allowerasing $pkg ||
            dnf -yq install --allowerasing $pkg
    done
    # Ensure noveau vulkan icds exist
    (
        shopt -u nullglob
        ls /usr/share/vulkan/icd.d/nouveau_icd.*.json >/dev/null
    ) || {
        echo >&2 "::error::No nouveau vulkan icds found at /usr/share/vulkan/icd.d/nouveau_icd.*.json"
        exit 1
    }
fi

# Don't check for verified image
rm -vf /etc/profile.d/verify_motd.sh

echo "Copying shared system files..."
cp -af /root/packages/installer/system_files/shared/. /

echo "Copying GNOME-specific system files..."
cp -a /root/packages/installer/system_files/gnome/. /

# Don't start the fedora-welcome app (gnome only)
sed -i 's@\[Desktop Entry\]@\[Desktop Entry\]\nHidden=true@g' /usr/share/anaconda/gnome/org.fedoraproject.welcome-screen.desktop || :

###############################
#remove rakuos-welcome automatic launch for live environment
rm -f /etc/xdg/autostart/rakuos-welcome.desktop

rm -rf /root/packages
