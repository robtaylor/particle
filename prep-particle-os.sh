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

mkdir -p $STORE/installer/
cp /etc/yum.conf $STORE/installer/ > /dev/null 2>&1 || cp /etc/yum/yum.conf $STORE/installer/ > /dev/null 2>&1

if [ ! -e fedora-repos ]; then 
	git clone https://git.fedorahosted.org/git/fedora-repos.git
fi

mkdir -p $STORE/installer/yum.conf.d
cp fedora-repos/fedora*.repo $STORE/installer/yum.conf.d

wget https://copr.fedoraproject.org/coprs/harald/cpio-reproducible/repo/fedora-rawhide/harald-cpio-reproducible-fedora-rawhide.repo

cp harald-cpio-reproducible-fedora-rawhide.repo $STORE/installer/yum.conf.d

if [ ! -f particle.img ]; then
	dd if=/dev/zero of=particle.img bs=1G count=20
	mkfs.btrfs particle.img
fi

sudo umount "${PARTICLE_ROOT}/master" > /dev/null 2>&1
sudo mount particle.img "${PARTICLE_ROOT}/master"

