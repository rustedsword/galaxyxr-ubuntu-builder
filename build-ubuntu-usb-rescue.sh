#!/bin/bash
# Build an Ubuntu rescue image for the Galaxy XR, to dd onto a USB stick.
#
# usage: build-ubuntu-usb-rescue.sh <image> [size]
#
# The image (900M by default, fits 1 GB sticks) has a GPT with:
#   1. XRBOOT  FAT16, XrBoot's kernels and boot entries
#   2. root    f2fs, the rest
#
# Steps:
#   1. create the image and partition it
#   2. attach it to a loop device
#   3. format XRBOOT and root
#   4. mount root, XRBOOT and tmpfs for apt and dracut, write the hostname and the kernel options
#   5. install a minimal Ubuntu, the Galaxy XR kernel and the rest with mmdebstrap
#   6. check the boot entry on XRBOOT
#   7. set the locale, add the hostname to /etc/hosts
#   8. set up the Wi-Fi access point on its own interface, wlan0 stays free for a client
#   9. enable ssh at boot, disable networkd: NetworkManager runs the network
#  10. create the user
#  11. allow the user passwordless sudo
#  12. write fstab
#  13. remove ssh host keys, generate them on any boot that lacks them
#  14. unmount and detach
#  15. compress
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
SOURCES=$(dirname "$(readlink -f "$0")")/sources
PACKAGES=(
    systemd-sysv udev dbus systemd-resolved systemd-timesyncd openssh-server sudo
    iproute2 iputils-ping procps less vim-tiny ca-certificates netbase bash-completion
    network-manager network-manager-tui wpasupplicant dnsmasq-base iptables wireless-regdb iw
    linux-image-galaxyxr
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

IMAGE=${1:?usage: $0 <image> [size]}
SIZE=${2:-900M}

step() { echo; echo "=== $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

chroot_run() {
    chroot "$MP" /usr/bin/env -i PATH=/usr/sbin:/usr/bin LC_ALL=C.UTF-8 "$@"
}

# --- checks -------------------------------------------------------------------
for tool in mmdebstrap sfdisk losetup mkfs.vfat mkfs.f2fs blkid xz; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
[ ! -e "$IMAGE" ] || die "$IMAGE already exists"
[ ! -e "$IMAGE.xz" ] || die "$IMAGE.xz already exists"
[ -f "$SOURCES/ubuntu.sources" ] || die "$SOURCES/ubuntu.sources not found"
[ -f "$SOURCES/gxr.sources" ] || die "$SOURCES/gxr.sources not found"
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

# --- 4. mount and kernel options ----------------------------------------------
step "4. mount $ROOT_DEV on $MP and XRBOOT on $MP/boot/xrboot, hostname $HOST_NAME, root=UUID=$root_uuid"
mount -t f2fs -o "$MOUNT_OPTS" "$ROOT_DEV" "$MP"
findmnt -no OPTIONS "$MP"
# apt's downloads, lists and caches and dracut's work dir don't fit on the image
# next to the system; the image keeps the empty directories
mkdir -p "$MP/var/cache/apt/archives" "$MP/var/lib/apt/lists"
install -d -m 1777 "$MP/var/tmp"
for m in var/cache/apt var/lib/apt/lists var/tmp; do
    mount -t tmpfs tmpfs "$MP/$m"
done
# kernel-install reads the rest when mmdebstrap installs the kernel
mkdir -p "$MP/boot/xrboot" "$MP/etc/kernel"
mount -t vfat -o umask=0077 "$XRBOOT_DEV" "$MP/boot/xrboot"
mkdir "$MP/boot/xrboot/loader"
printf 'default ubuntu-*\nxrboot-log yes\n' > "$MP/boot/xrboot/loader/loader.conf"
# dracut copies it into the initramfs
echo "$HOST_NAME" > "$MP/etc/hostname"
# net.ifnames=0: the wlan driver's wlan0, p2p0 and wifi-aware0 share one PCI path,
# udev's name for it goes to whichever comes first
echo "root=UUID=$root_uuid rootflags=$MOUNT_OPTS net.ifnames=0" > "$MP/etc/kernel/cmdline"
echo ubuntu > "$MP/etc/kernel/entry-token"

# --- 5. mmdebstrap ------------------------------------------------------------
step "5. install Ubuntu $SUITE: ${PACKAGES[*]}"
LC_ALL=C.UTF-8 mmdebstrap --verbose --mode=root --variant=minbase --skip=check/empty --include="${PACKAGES[*]}" \
    "$SUITE" "$MP" "$SOURCES/ubuntu.sources" "$SOURCES/gxr.sources"
umount "$MP/var/cache/apt" "$MP/var/lib/apt/lists" "$MP/var/tmp"
mount -t proc proc "$MP/proc"

# --- 6. boot entry ------------------------------------------------------------
step "6. check the boot entry"
entries=("$MP"/boot/xrboot/loader/entries/ubuntu-*.conf)
[ ${#entries[@]} -eq 1 ] && [ -f "${entries[0]}" ] || die "need one ubuntu-*.conf entry on XRBOOT"
grep -qF "root=UUID=$root_uuid" "${entries[0]}" || die "${entries[0]} does not boot UUID=$root_uuid"
cat "${entries[0]}"

# --- 7. locale and hosts ------------------------------------------------------
step "7. locale C.UTF-8, $HOST_NAME in /etc/hosts"
echo LANG=C.UTF-8 > "$MP/etc/default/locale"
printf '127.0.1.1\t%s\n' "$HOST_NAME" >> "$MP/etc/hosts"

# --- 8. access point ----------------------------------------------------------
step "8. Wi-Fi access point '$AP_SSID' on $AP_IF: $AP_ADDR/24 with DHCP and NAT, $CLIENT_IF stays a client"
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

# --- 9. services --------------------------------------------------------------
step "9. enable ssh at boot, disable networkd"
# ssh is socket-activated; sshd-keygen.service creates host keys on first start
chroot_run systemctl enable ssh.socket
chroot_run systemctl disable systemd-networkd.service
chroot_run systemctl is-enabled NetworkManager.service
# the kernel has no audit support
printf '[logging]\naudit=false\n' > "$MP/etc/NetworkManager/conf.d/no-audit.conf"

# --- 10. user -----------------------------------------------------------------
step "10. create user $USERNAME"
# useradd prints nothing on success. It can return 0 after a failed
# /etc/skel copy, so any output counts as failure.
err=$(chroot_run useradd -m -s /bin/bash -G sudo "$USERNAME" 2>&1) || die "useradd: $err"
[ -z "$err" ] || die "useradd: $err"
chroot_run chpasswd <<<"$USERNAME:$PASSWORD"
chroot_run id "$USERNAME"

# --- 11. sudo -----------------------------------------------------------------
step "11. passwordless sudo for $USERNAME"
install -m 0440 -o root -g root /dev/stdin "$MP/etc/sudoers.d/$USERNAME" \
    <<<"$USERNAME ALL=(ALL) NOPASSWD: ALL"
chroot_run visudo -cf "/etc/sudoers.d/$USERNAME"

# --- 12. fstab ----------------------------------------------------------------
step "12. write fstab"
# fsck pass 0: the image has no fsck.f2fs
printf 'UUID=%s\t/\tf2fs\t%s\t0 0\n' "$root_uuid" "$MOUNT_OPTS" > "$MP/etc/fstab"
cat "$MP/etc/fstab"

# --- 13. cleanup --------------------------------------------------------------
step "13. remove ssh host keys, generate them on any boot that lacks them"
rm -f "$MP"/etc/ssh/ssh_host_*
# not only on the first boot: an unplugged stick loses keys that were not yet written
mkdir -p "$MP/etc/systemd/system/sshd-keygen.service.d"
printf '[Unit]\nConditionFirstBoot=\nConditionPathExists=!/etc/ssh/ssh_host_ed25519_key\n' \
    > "$MP/etc/systemd/system/sshd-keygen.service.d/missing-keys.conf"

# --- 14. unmount --------------------------------------------------------------
step "14. unmount and detach"
df -h "$MP" "$MP/boot/xrboot"
umount "$MP/proc" "$MP/boot/xrboot" "$MP"
losetup -d "$LOOP"

# --- 15. compress -------------------------------------------------------------
step "15. compress to $IMAGE.xz"
xz -T0 -k "$IMAGE"
ls -l "$IMAGE" "$IMAGE.xz"

step "done"
