#!/bin/bash
# Build an Ubuntu rescue image for the Galaxy XR, to dd onto a USB stick.
#
# usage: build-ubuntu-usb-rescue.sh [-k kernel-debs-dir] <image> [size]
#
# The image (900M by default, fits 1 GB sticks) has a GPT with:
#   1. XRBOOT  FAT16, XrBoot's kernels and boot entries
#   2. root    f2fs, the rest
#
# -k installs the kernel from linux-image-* and linux-modules-* .debs in
# kernel-debs-dir instead of the gxr PPA's.
#
# Steps:
#   1. create the image and partition it
#   2. attach it to a loop device
#   3. format XRBOOT and root
#   4. mount root
#   5. install a minimal Ubuntu and the gxr packages with mmdebstrap
#   6. set up a chroot
#   7. set the hostname
#   8. configure kernel-install for XRBOOT
#   9. install the Galaxy XR kernel, without linux-firmware
#  10. set up the Wi-Fi access point on its own interface, wlan0 stays free for a client
#  11. enable ssh at boot, disable networkd: NetworkManager runs the network
#  12. create the user
#  13. allow the user passwordless sudo
#  14. write fstab
#  15. remove ssh host keys, generate them on any boot that lacks them
#  16. unmount and detach
#  17. compress
#
# Any failure stops the script. Nothing is repaired or worked around.
#
# Flash: xzcat <image>.xz | sudo dd of=/dev/sdX bs=4M conv=fsync

set -euo pipefail
trap 'echo "FAILED (line $LINENO): $BASH_COMMAND" >&2' ERR

MP=/mnt/ubuntu-usb
XRBOOT_SIZE=128M
XBOOTLDR_TYPE=bc13c2ff-59e6-4262-a352-b275fd6f7172
SUITE=stonking
UBUNTU_SOURCES=$(dirname "$(readlink -f "$0")")/sources/ubuntu.sources
GXR_SOURCES=$(dirname "$(readlink -f "$0")")/sources/gxr.sources
PACKAGES=(
    systemd-sysv udev dbus systemd-resolved openssh-server sudo
    iproute2 iputils-ping procps less vim-tiny ca-certificates netbase
    network-manager network-manager-tui wpasupplicant dnsmasq-base nftables wireless-regdb iw
    galaxyxr-firmware galaxyxr-initramfs-android-crap xrboot-kernel-install
)
HOST_NAME=gxr-usb
CLIENT_IF=wlan0
AP_IF=ap0
AP_SSID=lightofmysoul
AP_PASSPHRASE=lightofmysoul
AP_ADDR=192.168.50.1
USERNAME=lightofmysoul
PASSWORD=lightofmysoul
# noatime,lazytime: no writes on reads, batched timestamp updates
# nodiscard:        the stick does not support discard
# mode=lfs:         never overwrite in place (slow path on cheap flash)
# compress_*:       lz4-compress every file, fewer bytes go to the stick
MOUNT_OPTS='noatime,lazytime,nodiscard,mode=lfs,compress_algorithm=lz4,compress_extension=*'

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
# the mounts would otherwise leak into running services' mount namespaces and pin the loop device
[ -n "${BUILD_UNSHARED:-}" ] ||
    exec env BUILD_UNSHARED=1 unshare --mount --propagation private -- "$0" "$@"

USAGE="usage: $0 [-k kernel-debs-dir] <image> [size]"
KERNEL_DEBS=
while getopts k: opt; do
    case $opt in
        k) KERNEL_DEBS=$OPTARG ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
IMAGE=${1:?$USAGE}
SIZE=${2:-900M}

step() { echo; echo "=== $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

chroot_run() {
    chroot "$MP" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-dumb}" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        "$@"
}

# Undo the chroot helper mounts on any exit. On failure the image stays
# attached to its loop device so it can be inspected.
chroot_teardown() {
    for m in var/tmp var/cache/apt var/lib/apt/lists run/systemd/resolve run dev/pts dev sys proc; do
        if mountpoint -q "$MP/$m"; then umount "$MP/$m"; fi
    done
}
trap chroot_teardown EXIT

# --- checks -------------------------------------------------------------------
for tool in mmdebstrap sfdisk losetup mkfs.vfat mkfs.f2fs blkid xz dpkg-deb; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
[ ! -e "$IMAGE" ] || die "$IMAGE already exists"
[ ! -e "$IMAGE.xz" ] || die "$IMAGE.xz already exists"
[ -f "$UBUNTU_SOURCES" ] || die "$UBUNTU_SOURCES not found"
[ -f "$GXR_SOURCES" ] || die "$GXR_SOURCES not found"
if [ -n "$KERNEL_DEBS" ]; then
    debs=("$KERNEL_DEBS"/linux-image-[0-9]*_arm64.deb)
    [ ${#debs[@]} -eq 1 ] && [ -f "${debs[0]}" ] || die "need one linux-image-*_arm64.deb in $KERNEL_DEBS"
    KERNEL_IMAGE_DEB=${debs[0]}
    debs=("$KERNEL_DEBS"/linux-modules-[0-9]*_arm64.deb)
    [ ${#debs[@]} -eq 1 ] && [ -f "${debs[0]}" ] || die "need one linux-modules-*_arm64.deb in $KERNEL_DEBS"
    KERNEL_MODULES_DEB=${debs[0]}
fi
mkdir -p "$MP"
if mountpoint -q "$MP"; then die "$MP is already a mount point"; fi
[ -z "$(ls -A "$MP")" ] || die "$MP is not empty"

# --- 1. image -----------------------------------------------------------------
step "1. create $IMAGE ($SIZE): XRBOOT $XRBOOT_SIZE, root the rest"
truncate -s "$SIZE" "$IMAGE"
sfdisk "$IMAGE" <<EOF
label: gpt
size=$XRBOOT_SIZE, type=$XBOOTLDR_TYPE, name=XRBOOT
type=linux, name=root
EOF

# --- 2. loop device -----------------------------------------------------------
step "2. attach $IMAGE"
LOOP=$(losetup --find --show --partscan "$IMAGE")
udevadm settle
XRBOOT_DEV=${LOOP}p1
ROOT_DEV=${LOOP}p2
[ -b "$XRBOOT_DEV" ] && [ -b "$ROOT_DEV" ] || die "no partitions on $LOOP"
echo "$LOOP"

# --- 3. format ----------------------------------------------------------------
step "3. format $XRBOOT_DEV as FAT16 XRBOOT, $ROOT_DEV as f2fs"
mkfs.vfat -F 16 -n XRBOOT "$XRBOOT_DEV"
mkfs.f2fs -f -O extra_attr,inode_checksum,sb_checksum,compression "$ROOT_DEV"
root_uuid=$(blkid -p -s UUID -o value "$ROOT_DEV")
[ -n "$root_uuid" ] || die "no filesystem UUID on $ROOT_DEV"

# --- 4. mount -----------------------------------------------------------------
step "4. mount $ROOT_DEV on $MP"
mount -t f2fs -o "$MOUNT_OPTS" "$ROOT_DEV" "$MP"
findmnt -no OPTIONS "$MP"

# --- 5. mmdebstrap ------------------------------------------------------------
step "5. install Ubuntu $SUITE: ${PACKAGES[*]}"
LC_ALL=C.UTF-8 mmdebstrap --mode=root --variant=minbase --include="${PACKAGES[*]}" \
    "$SUITE" "$MP" "$UBUNTU_SOURCES" "$GXR_SOURCES"

# --- 6. chroot ----------------------------------------------------------------
step "6. set up chroot"
mount -t proc proc "$MP/proc"
mount -t sysfs sys "$MP/sys"
mount --bind /dev "$MP/dev"
mount --bind /dev/pts "$MP/dev/pts"
# empty /run: no /run/systemd/system, so package scripts see that systemd is
# not running and do not start services
mount -t tmpfs tmpfs "$MP/run"
# the image's /etc/resolv.conf points to /run/systemd/resolve/stub-resolv.conf;
# share the host's resolver config there
mkdir -p "$MP/run/systemd/resolve"
mount --bind -o ro /run/systemd/resolve "$MP/run/systemd/resolve"
# apt's lists and caches and dracut's work dir stay out of the image
for m in var/lib/apt/lists var/cache/apt var/tmp; do
    mount -t tmpfs tmpfs "$MP/$m"
done
chroot_run apt-get update

# --- 7. hostname --------------------------------------------------------------
# before the kernel: dracut copies it into the initramfs
step "7. hostname $HOST_NAME"
echo "$HOST_NAME" > "$MP/etc/hostname"
printf '127.0.1.1\t%s\n' "$HOST_NAME" >> "$MP/etc/hosts"

# --- 8. kernel-install --------------------------------------------------------
step "8. kernel-install: XRBOOT on $XRBOOT_DEV, root=UUID=$root_uuid"
# net.ifnames=0: the wlan driver's wlan0, p2p0 and wifi-aware0 share one PCI path,
# udev's name for it goes to whichever comes first
echo "root=UUID=$root_uuid rootflags=$MOUNT_OPTS net.ifnames=0" > "$MP/etc/kernel/cmdline"
echo ubuntu > "$MP/etc/kernel/entry-token"
mkdir -p "$MP/boot/xrboot"
mount -t vfat -o umask=0077 "$XRBOOT_DEV" "$MP/boot/xrboot"
mkdir "$MP/boot/xrboot/loader"
printf 'default ubuntu-*\nxrboot-log yes\n' > "$MP/boot/xrboot/loader/loader.conf"

# --- 9. kernel ----------------------------------------------------------------
if [ -n "$KERNEL_DEBS" ]; then
    kver=$(dpkg-deb -f "$KERNEL_IMAGE_DEB" Package)
    kver=${kver#linux-image-}
    [ "$(dpkg-deb -f "$KERNEL_MODULES_DEB" Package)" = "linux-modules-$kver" ] ||
        die "$KERNEL_MODULES_DEB is not linux-modules-$kver"
    cp "$KERNEL_IMAGE_DEB" "$KERNEL_MODULES_DEB" "$MP/var/tmp/"
    kernel_packages=("/var/tmp/${KERNEL_IMAGE_DEB##*/}" "/var/tmp/${KERNEL_MODULES_DEB##*/}")
else
    # linux-image-galaxyxr depends on linux-firmware, the kernel and its modules don't
    kver=$(chroot_run apt-cache depends linux-image-galaxyxr | sed -n 's/^ *Depends: linux-image-\([0-9][^ ]*\)$/\1/p')
    kernel_packages=("linux-image-$kver" "linux-modules-$kver")
fi
[[ $kver =~ ^[0-9][^[:space:]]*$ ]] || die "no kernel version: '$kver'"
step "9. install kernel $kver"
chroot_run apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-unsafe-io \
    "${kernel_packages[@]}"
entry=$MP/boot/xrboot/loader/entries/ubuntu-$kver.conf
[ -f "$entry" ] || die "no $entry on XRBOOT"
grep -qF "root=UUID=$root_uuid" "$entry" || die "$entry does not boot UUID=$root_uuid"
cat "$entry"

# --- 10. access point ---------------------------------------------------------
step "10. Wi-Fi access point '$AP_SSID' on $AP_IF: $AP_ADDR/24 with DHCP and NAT, $CLIENT_IF stays a client"
# the driver allows one AP next to one client
install -m 644 -o root -g root /dev/stdin "$MP/etc/udev/rules.d/90-$AP_IF.rules" <<EOF
ACTION=="add", SUBSYSTEM=="net", KERNEL=="$CLIENT_IF", RUN+="/usr/sbin/iw dev $CLIENT_IF interface add $AP_IF type __ap"
EOF
install -m 600 -o root -g root /dev/stdin "$MP/etc/NetworkManager/system-connections/$AP_SSID.nmconnection" <<EOF
[connection]
id=$AP_SSID
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
interface-name=$AP_IF

[wifi]
mode=ap
ssid=$AP_SSID
band=bg

[wifi-security]
key-mgmt=wpa-psk
proto=rsn;
pairwise=ccmp;
group=ccmp;
psk=$AP_PASSPHRASE

[ipv4]
method=shared
address1=$AP_ADDR/24

[ipv6]
method=disabled
EOF

# --- 11. services -------------------------------------------------------------
step "11. enable ssh at boot, disable networkd"
# ssh is socket-activated; sshd-keygen.service creates host keys on first start
chroot_run systemctl enable ssh.socket
chroot_run systemctl disable systemd-networkd.service
chroot_run systemctl is-enabled NetworkManager.service

# --- 12. user -----------------------------------------------------------------
step "12. create user $USERNAME"
# useradd prints nothing on success. It can return 0 after a failed
# /etc/skel copy, so any output counts as failure.
err=$(chroot_run useradd -m -s /bin/bash -G sudo "$USERNAME" 2>&1) || die "useradd: $err"
[ -z "$err" ] || die "useradd: $err"
chroot_run chpasswd <<<"$USERNAME:$PASSWORD"
chroot_run id "$USERNAME"

# --- 13. sudo -----------------------------------------------------------------
step "13. passwordless sudo for $USERNAME"
install -m 0440 -o root -g root /dev/stdin "$MP/etc/sudoers.d/$USERNAME" \
    <<<"$USERNAME ALL=(ALL) NOPASSWD: ALL"
chroot_run visudo -cf "/etc/sudoers.d/$USERNAME"

# --- 14. fstab ----------------------------------------------------------------
step "14. write fstab"
# fsck pass 0: the image has no fsck.f2fs
printf 'UUID=%s\t/\tf2fs\t%s\t0 0\n' "$root_uuid" "$MOUNT_OPTS" > "$MP/etc/fstab"
cat "$MP/etc/fstab"

# --- 15. cleanup --------------------------------------------------------------
step "15. remove ssh host keys, generate them on any boot that lacks them"
rm -f "$MP"/etc/ssh/ssh_host_*
# not only on the first boot: an unplugged stick loses keys that were not yet written
mkdir -p "$MP/etc/systemd/system/sshd-keygen.service.d"
printf '[Unit]\nConditionFirstBoot=\nConditionPathExists=!/etc/ssh/ssh_host_ed25519_key\n' \
    > "$MP/etc/systemd/system/sshd-keygen.service.d/missing-keys.conf"

# --- 16. unmount --------------------------------------------------------------
step "16. unmount and detach"
df -h "$MP" "$MP/boot/xrboot"
chroot_teardown
umount "$MP/boot/xrboot"
umount "$MP"
losetup -d "$LOOP"

# --- 17. compress -------------------------------------------------------------
step "17. compress to $IMAGE.xz"
xz -T0 -k "$IMAGE"
ls -l "$IMAGE" "$IMAGE.xz"

step "done"
