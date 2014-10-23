#!/bin/bash

set -e

function usage {
    echo "Usage: $0 [particle-usr-snapshot]" >&2
    exit 1
}

if [[ "$1" == "--help" ]] ; then
	usage
fi

PARTICLE_ROOT=/mnt/particle
MASTER="${PARTICLE_ROOT}/master"
SNAPSHOT=""

if [[ "x$1" == "x" ]] ; then
	IFS=" "
	og=0
	while read a a a g a a a a a a a a a v; do 
		echo  x$og x$g x$v  x$gen x$vol
		if [[ $g > $og ]]; then gen="$g"; vol="$v"; fi
	done < <(sudo btrfs subvolume list -s $MASTER)
	SNAPSHOT=$vol
elif [[ ! -e $1 ]]; then
	usage
fi

echo "Using snapshot $SNAPSHOT as usr"

export ROOT=`mktemp -d`
sudo mount -t tmpfs -o size=512m tmpfs $ROOT
mkdir $ROOT/{boot,proc,run,var,sys,dev,etc,usr}
sudo mount --bind $MASTER/$SNAPSHOT $ROOT/usr
#sudo mount --bind /proc  $ROOT/proc
#sudo mount --bind /sys  $ROOT/sys
#sudo mount --bind /run  $ROOT/run
ln -s ../run $ROOT/var/run
ln -s ../run/lock $ROOT/var/lock
for i in bin sbin lib lib64; do ln -s usr/$i $ROOT/$i; done
systemd-machine-id-setup --root=$ROOT
echo "Container created in $ROOT"
echo "To run:"
echo "$ sudo systemd-nspawn --link-journal=guest -D  $ROOT /bin/bash"
