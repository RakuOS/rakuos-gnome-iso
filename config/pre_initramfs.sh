#!/usr/bin/env bash
set -exo pipefail

echo "Preparing initramfs for RakuOS Linux Live ISO"

# Swap the CachyOS kernel for a vanilla signed Fedora kernel so the live ISO
# boots with Secure Boot enabled. The installed system gets the CachyOS kernel
# from the container image — this only affects the live boot environment.
kernel_pkgs=(
    kernel-cachyos
    kernel-cachyos-core
    kernel-cachyos-devel
    kernel-cachyos-devel-matched
    kernel-cachyos-modules
    kernel-cachyos-modules-core
    kernel-cachyos-modules-extra
)
dnf -y versionlock delete "${kernel_pkgs[@]}" 2>/dev/null || true
dnf --setopt=protect_running_kernel=False -y remove "${kernel_pkgs[@]}" 2>/dev/null || true
(cd /usr/lib/modules && rm -rf -- ./*)
dnf -y --repo fedora,updates --setopt=tsflags=noscripts install kernel kernel-core
kernel=$(find /usr/lib/modules -maxdepth 1 -type d -printf '%P\n' | grep .)
depmod "$kernel"
dnf clean all -yq
