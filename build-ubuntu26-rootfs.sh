#!/bin/bash
set -euo pipefail

# Ubuntu 26.04 LTS (Resolute) ARM64 rootfs builder for Xiaomi Pad 6S Pro.
source "$(dirname "$0")/lib/rootfs-common.sh"

IMAGE_SIZE="8G"
UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
UBUNTU_SUITE="resolute"
UBUNTU_MIRROR="https://ports.ubuntu.com/ubuntu-ports"

ROOT_PASS="${ROOT_PASS:-1234}"
USER_PASS="${USER_PASS:-luser}"
USER_NAME="${USER_NAME:-luser}"

usage() {
    echo "Usage: $0 <distro> <kernel_version> <boot_mode> <desktop_environment>"
    echo "desktop_environment: kde, gnome, or xfce"
    echo "boot_mode: dual or single"
    exit 1
}

if [ $# -lt 2 ] || [ $# -gt 4 ]; then usage; fi
if [ "$(id -u)" -ne 0 ]; then echo "Error: Must run as root"; exit 1; fi

KERNEL="$2"
BOOT_MODE="${3:-dual}"
DESKTOP_ENV="${4:-kde}"

if [ -z "$DESKTOP_ENV" ] || [ "$DESKTOP_ENV" = "all" ]; then
    DESKTOP_ENV="kde"
fi
if [[ ! "$DESKTOP_ENV" =~ ^(gnome|kde|xfce)$ ]]; then
    echo "Error: desktop_environment must be kde, gnome, or xfce" >&2
    exit 1
fi

if [ "$BOOT_MODE" = "all" ]; then
    BOOT_MODE="dual"
fi
if [[ ! "$BOOT_MODE" =~ ^(dual|single)$ ]]; then
    echo "Error: boot_mode must be dual or single (got: $BOOT_MODE)" >&2
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="ubuntu26_${DESKTOP_ENV}_${TIMESTAMP}.img"

echo "=========================================="
echo "Ubuntu 26.04 LTS (Resolute) ARM64 build"
echo "Desktop: $DESKTOP_ENV"
echo "Kernel: $KERNEL"
echo "Boot mode: $BOOT_MODE"
echo "=========================================="

preflight_checks 10240 debootstrap

create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
trap_teardown "$ROOTDIR"

debootstrap --arch=arm64 "$UBUNTU_SUITE" "$ROOTDIR" "$UBUNTU_MIRROR"

# debootstrap manages and unmounts its own pseudo-filesystems. Mount ours only
# after it has finished, otherwise /proc and /sys disappear before apt runs.
setup_chroot_mounts "$ROOTDIR"
touch "$ROOTDIR/etc/machine-id"

# Package post-install scripts must not attempt to start services in the chroot.
cat > "$ROOTDIR/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOTDIR/usr/sbin/policy-rc.d"

cat > "$ROOTDIR/etc/apt/sources.list" <<EOF
deb $UBUNTU_MIRROR $UBUNTU_SUITE main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_SUITE-updates main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_SUITE-backports main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_SUITE-security main restricted universe multiverse
EOF

chroot "$ROOTDIR" env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$ROOTDIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-resolved sudo vim-tiny wget curl locales ca-certificates \
    network-manager openssh-server wpasupplicant dbus kmod initramfs-tools \
    alsa-utils pipewire pipewire-pulse wireplumber bluez qrtr-tools

shopt -s nullglob
deb_files=(./*.deb)
shopt -u nullglob
if [ ${#deb_files[@]} -eq 0 ]; then
    echo "Error: No kernel .deb packages found" >&2
    exit 1
fi

cp "${deb_files[@]}" "$ROOTDIR/tmp/"
if ! chroot "$ROOTDIR" bash -c \
    'export DEBIAN_FRONTEND=noninteractive; apt-get install -y /tmp/*.deb'; then
    echo "Error: Kernel bundle installation failed" >&2
    exit 1
fi

KERNEL_MODULE_DIR=$(detect_kernel_module_dir "$ROOTDIR" || true)
if [ -n "$KERNEL_MODULE_DIR" ]; then
    echo "Detected kernel module directory: $KERNEL_MODULE_DIR"
    chroot "$ROOTDIR" depmod -a "$KERNEL_MODULE_DIR" || true
fi

echo 'LANG=en_US.UTF-8' > "$ROOTDIR/etc/default/locale"
chroot "$ROOTDIR" locale-gen en_US.UTF-8
echo "ubuntu26-${DESKTOP_ENV}" > "$ROOTDIR/etc/hostname"

setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
    "sudo,audio,video,render,input,plugdev,bluetooth,netdev"

if [ "$DESKTOP_ENV" = "kde" ]; then
    chroot "$ROOTDIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kubuntu-desktop plasma-workspace-wayland sddm-theme-breeze \
        dolphin konsole plasma-nm plasma-pa powerdevil bluedevil \
        kdeconnect xdg-desktop-portal-kde discover packagekit maliit-keyboard
elif [ "$DESKTOP_ENV" = "gnome" ]; then
    chroot "$ROOTDIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ubuntu-desktop-minimal gnome-terminal gdm3
elif [ "$DESKTOP_ENV" = "xfce" ]; then
    chroot "$ROOTDIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xfce4 xfce4-terminal lightdm lightdm-gtk-greeter mousepad thunar
fi

setup_autologin "$ROOTDIR" "$DESKTOP_ENV" "$USER_NAME"

if [ "$DESKTOP_ENV" = "kde" ]; then
    if chroot "$ROOTDIR" id -u sddm >/dev/null 2>&1; then
        chroot "$ROOTDIR" usermod -aG video,render,input sddm || true
    fi
    mkdir -p "$ROOTDIR/etc/sddm.conf.d"
    cat > "$ROOTDIR/etc/sddm.conf.d/10-sheng.conf" <<EOF
[General]
DisplayServer=wayland

[Autologin]
User=$USER_NAME
Session=plasmawayland
Relogin=true
EOF
fi

chroot "$ROOTDIR" systemctl set-default graphical.target
setup_getty_ttyMSM0 "$ROOTDIR"
setup_systemd_resolved_symlink "$ROOTDIR"
configure_touchscreen "$ROOTDIR"
fix_wifi_firmware "$ROOTDIR"
setup_qrtr_service "$ROOTDIR"

generate_fstab "$ROOTDIR" "$BOOT_MODE"
chroot "$ROOTDIR" apt-get clean
chroot "$ROOTDIR" rm -f /tmp/*.deb
teardown_mounts "$ROOTDIR"
TEARDOWN_ROOTDIR=""
trap - EXIT ERR INT TERM

apply_fs_uuid "$UUID" "$ROOTFS_IMG"
pack_sparse_image "$ROOTFS_IMG" "ubuntu26_${DESKTOP_ENV}_${TIMESTAMP}.7z"

echo "Ubuntu 26.04 KDE build successful"
