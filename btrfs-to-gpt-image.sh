#!/bin/bash
set -e

if ! [[ -f "$1" ]] || [[ -z "$2" ]]; then
    echo "Usage: $0 <btrfs-send-image.xz> <disk or image file to re-format>" >&2
    exit 1
fi

IMAGE="$2"
BTRFSIMAGE="$(readlink -f $1)"
ARCH=$(uname -m)

trap '
    ret=$?;
    if [[ $ROOT ]]; then
        for i in /proc /run /boot /dev /sys /usr ""; do
            mountpoint /run/installer-$ROOT/system$i &>/dev/null && umount /run/installer-$ROOT/system$i || :
        done
        rm -rf /run/installer-$ROOT
    fi
    [[ $DEV == /dev/loop* ]] && losetup -d $DEV
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

if [[ ! -e "$IMAGE" ]] || [[ -f "$IMAGE" ]]; then
    dd if=/dev/null of="$IMAGE" bs=1M seek=4096
    DEV=$(losetup -f --show "$IMAGE")
else
    DEV="$IMAGE"
fi

if [[ ! -b "$DEV" ]]; then
    echo "$IMAGE is not a block device" >&2
    exit 1
fi

ROOT=${DEV##*/}

echo "### installing Fedora rawhide at /dev/$ROOT"

printf "\n### erasing /dev/$ROOT\n"
# get rid of all signatures
wipefs -a /dev/$ROOT
udevadm settle
dd if=/dev/zero of=/dev/$ROOT bs=1M count=4

printf "\n### formatting EFI System Partition\n"
parted /dev/$ROOT --script "mklabel gpt" "mkpart ESP fat32 1MiB 511Mib" "set 1 boot on"
udevadm settle

BOOT_PART=/dev/${ROOT}1
[[ -b /dev/${ROOT}p1 ]] && BOOT_PART=/dev/${ROOT}p1

wipefs -a $BOOT_PART
mkfs.vfat -n EFI -F32 $BOOT_PART

printf "\n### formatting System Partition\n"
parted /dev/$ROOT --script "mkpart System ext4 512Mib -1Mib"

udevadm settle

case "$ARCH" in
        x86_64)
                ROOT_UUID=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
                ;;
        i686|i586|i486|i386)
                ROOT_UUID=44479540-f297-41b2-9af7-d131d5f0458a
                ;;
        *)
                ROOT_UUID=0fc63daf-8483-4772-8e79-3d69d8477de4
                ;;
esac

echo "t
2
$ROOT_UUID
w
y
q" | gdisk /dev/$ROOT ||:

udevadm settle

SYSTEM_PART=/dev/${ROOT}2
[[ -b /dev/${ROOT}p2 ]] && SYSTEM_PART=/dev/${ROOT}p2

wipefs -a $SYSTEM_PART
mkfs.btrfs -f -L System $SYSTEM_PART
udevadm settle

rm -rf /run/installer-$ROOT

btrfs_find_id() {
    local id gen level path where="$1" what="$2"
    while read id gen level path; do
        [[ "$level" != 5 ]] && continue
        [[ "$path" != $what ]] && continue
        printf -- "%s\n" "$id"
        return 0
    done < <(btrfs subvolume list -at "$where")
    return 1
}

# mount System
mkdir -p /run/installer-$ROOT/system
mount -o compress=lzo $SYSTEM_PART /run/installer-$ROOT/system

btrfs subvolume create /run/installer-$ROOT/system/"root:root:org.particle.OS:$ARCH"
#btrfs subvolume set-default $(btrfs_find_id /run/installer-$ROOT/system/ "root:root:org.particle.OS:$ARCH") /run/installer-$ROOT/system

xz -cd $BTRFSIMAGE | btrfs receive -v /run/installer-$ROOT/system
while read a a a g a a a a v; do
    [[ $v ]] || continue
    gen="$g"
    vol="$v"
    [[ "$vol" == usr:* ]] && break
done < <(btrfs subvolume list /run/installer-$ROOT/system)

ln -s "$vol" /run/installer-$ROOT/system/usr

umount /run/installer-$ROOT/system
mount -o compress=lzo,subvol="root:root:org.particle.OS:$ARCH" $SYSTEM_PART /run/installer-$ROOT/system

mkdir /run/installer-$ROOT/system/{boot,proc,run,var,sys,dev,etc,usr}
mount -o ro,subvol="$vol" $SYSTEM_PART /run/installer-$ROOT/system/usr

ln -s ../run /run/installer-$ROOT/system/var/run
ln -s ../run/lock /run/installer-$ROOT/system/var/lock
for i in bin sbin lib lib64; do
    ln -s usr/$i /run/installer-$ROOT/system/$i
done

mount $BOOT_PART /run/installer-$ROOT/system/boot
# mount kernel filesystems
mount --bind /proc /run/installer-$ROOT/system/proc
mount --bind /dev /run/installer-$ROOT/system/dev
mount --bind /sys /run/installer-$ROOT/system/sys
mount --bind /run /run/installer-$ROOT/system/run

chroot /run/installer-$ROOT/system/ gummiboot install --no-variables
mkdir -p /run/installer-$ROOT/system/boot/particle
cp /run/installer-$ROOT/system/usr/lib/modules/*/{vmlinuz,initrd} /run/installer-$ROOT/system/boot/particle
cat > /run/installer-$ROOT/system/boot/loader/entries/particle.conf <<EOF
title      Particle
options    quiet libahci.ignore_sss=1 raid=noautodetect selinux=0 rhgb plymouth.enable=0 rd.plymouth=0 rw root=/dev/gpt-auto-root rootflags=subvol=root:root:org.particle.OS:$ARCH console=ttyS0,115200n81 console=tty0 kdbus
linux      /particle/vmlinuz
initrd     /particle/initrd
EOF

for i in /proc /run /boot /dev /sys /usr; do
    mountpoint /run/installer-$ROOT/system$i &>/dev/null && umount /run/installer-$ROOT/system$i || :
done

rm -fr /run/installer-$ROOT/system/*
# workaround until systemd commit 5caeb7d6854e02321e0e00588e17412b161ef176 is available
mkdir /run/installer-$ROOT/system/{boot,run}

sync
printf "\n### finished\n"
