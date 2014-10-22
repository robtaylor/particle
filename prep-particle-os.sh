#!/bin/bash

PARTICLE_ROOT=/mnt/particle

sudo mkdir -p /mnt/particle
sudo chown $USER /mnt/particle

INSTALL="${PARTICLE_ROOT}/install"
PREPARE="${PARTICLE_ROOT}/prepare"
MASTER="${PARTICLE_ROOT}/master"
STORE="${PARTICLE_ROOT}/store"
TMPSTORE="${PARTICLE_ROOT}/tmp"

mkdir -p $INSTALL
mkdir -p $PREPARE
mkdir -p $MASTER
mkdir -p $STORE
mkdir -p $TMPSTORE

mkdir -p $STORE/images/
mkdir -p $STORE/installer/
mkdir -p $STORE/increment/
mkdir -p $STORE/torrents/increment/
mkdir -p $STORE/torrents/images/

sed -e "s%@STORE@%$STORE%" yum.conf.in >  $STORE/installer/yum.conf

if [ ! -e fedora-repos ]; then 
	git clone https://git.fedorahosted.org/git/fedora-repos.git
fi

mkdir -p $STORE/installer/yum.conf.d
cp fedora-repos/fedora*.repo $STORE/installer/yum.conf.d

if [ ! -f harald-cpio-reproducible-fedora-rawhide.repo ]; then
	wget https://copr.fedoraproject.org/coprs/harald/cpio-reproducible/repo/fedora-rawhide/harald-cpio-reproducible-fedora-rawhide.repo
fi

cp harald-cpio-reproducible-fedora-rawhide.repo $STORE/installer/yum.conf.d

if [ ! -f fedora-rawhide-kernel-nodebug.repo ]; then
	wget http://alt.fedoraproject.org/pub/alt/rawhide-kernel-nodebug/fedora-rawhide-kernel-nodebug.repo
fi

cp fedora-rawhide-kernel-nodebug.repo $STORE/installer/yum.conf.d


if [ ! -f particle.img ]; then
	dd if=/dev/zero of=particle.img bs=1G count=20
	mkfs.btrfs particle.img
fi

sudo umount "$MASTER" > /dev/null 2>&1
sudo umount "$PREPARE" > /dev/null 2>&1
sudo mount particle.img "${MASTER}"

if ! [[ -d "$MASTER/prepare" ]]; then
    sudo sh -c "cd $MASTER && btrfs subvolume create prepare"
fi

sudo mount -t btrfs -o subvol=prepare particle.img $PREPARE
