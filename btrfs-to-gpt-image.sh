#!/bin/bash
set -e

if ! [[ -f "$1" ]] || [[ -z "$2" ]]; then
    echo "Usage: $0 <btrfs-send-image.xz> <disk or image file to re-format>" >&2
    exit 1
fi

IMAGE="$2"
BTRFSIMAGE="$(readlink -f $1)"

trap '
    ret=$?;
    if [[ $ROOT ]]; then
        for i in /proc /run /boot /dev /sys ""; do
            umount /run/installer-$ROOT/system$i || :
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

case "x`uname -m`" in
        xx86_64)
                ROOT_UUID=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
                ;;
        xi686|xi586|xi486|xi386)
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

# mount System
mkdir -p /run/installer-$ROOT/system
mount $SYSTEM_PART /run/installer-$ROOT/system
(
    cd /run/installer-$ROOT/system
    xz -cd $BTRFSIMAGE | btrfs receive -v ./
    while read a a a g a a a a v; do
        [[ $v ]] || continue
        gen="$g"
        vol="$v"
    done < <(btrfs subvolume list .)
    btrfs subvolume snapshot -r "$vol" usr
)
sync
printf "\n### finished\n"
