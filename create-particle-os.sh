#!/bin/bash

set -e

SELF="$0"
RELEASE=rawhide
DEST=/mnt/particles/install
MASTER=/mnt/particles/master
PREPARE=/mnt/particles/prepare
STORE=/mnt/particles/store
TMPSTORE=/mnt/particles/tmp

trap '
    ret=$?;
    for i in proc dev sys run; do
        umount "$DEST/$i" || :
    done
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

mkdir -p "$DEST"/{proc,run,sys,dev}

# mount kernel filesystems
mount --bind /proc "$DEST"/proc
mount --bind /dev "$DEST"/dev
mount --bind /sys "$DEST"/sys

# packages wrongly install stuff here, but /run content does not belong on disk
mount -t tmpfs tmpfs "$DEST"/run

# short cut
if [[ -f $DEST/var/lib/rpm/Packages ]]; then
    yum -y --releasever="$RELEASE" --disablerepo='*' \
	--enablerepo=fedora --enablerepo=fedora-rawhide-kernel-nodebug \
	--nogpg --installroot="$DEST" --downloaddir=$STORE/packages \
	-c /mnt/particles/store/installer/yum.conf \
	check-update \
	&& exit 0

    for i in proc dev sys run; do
        umount "$DEST/$i" || :
    done
    rm -fr "$DEST"/*
    exec "$SELF"
fi


# create base directories"
# include /var links because yum itself messes up the directories which need to be symlinks
mkdir -p "$DEST"/{boot,proc,run,var,sys,dev,etc,var/tmp}
ln -fs ../run "$DEST"/var/run
ln -fs ../run/lock "$DEST"/var/lock

# make resolver work inside the chroot, yum will need it if called a second time
ln -fs /run/systemd/resolve/resolv.conf "$DEST"/etc

# at bootup mount / read-writable
cat > "$DEST"/etc/fstab <<EOF
ROOT       /               auto defaults           0 0
EOF

# kernel-install config
mkdir -p "$DEST"/etc/kernel
cat > "$DEST"/etc/kernel/cmdline <<EOF
raid=noautodetect quiet audit=0
EOF

printf "\n### download and install base packages\n"
yum -y --releasever="$RELEASE" --nogpg --installroot="$DEST" \
    --disablerepo='*' --enablerepo=fedora install \
    --downloaddir=$STORE/packages \
    -c /mnt/particles/store/installer/yum.conf \
    systemd passwd yum fedora-release \
    procps-ng psmisc less vi tree bash-completion \
    gummiboot dracut dracut-config-generic binutils \
    iputils iproute \
    dosfstools btrfs-progs parted \
    strace

# include the usb-storage kernel module
cat > "$DEST"/etc/dracut.conf.d/usb.conf <<EOF
add_drivers+=' usb-storage '
EOF

cp /etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo $DEST/etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo

printf "\n### download and install kernel\n"
# install after systemd.rpm created the machine-id which kernel-install wants
yum -y --releasever="$RELEASE" --disablerepo='*' \
    --enablerepo=fedora --enablerepo=fedora-rawhide-kernel-nodebug \
    --nogpg --installroot="$DEST" \
    --downloaddir=$STORE/packages \
    -c /mnt/particles/store/installer/yum.conf \
    install kernel

# set default target
systemctl --root="$DEST" set-default multi-user.target

INSTALL=/mnt/particles/install
PREPARE=/mnt/particles/prepare

rsync -Paqorx --delete-after "$INSTALL"/ "$PREPARE"/

# Copy os-release (should move to /usr and /etc be a symlink)
cp -a $PREPARE/etc/os-release $PREPARE/usr/lib/

# factory directory to populate /etc
mkdir -p $PREPARE/usr/share/factory/etc/

# copy PAM files to factory dir (PAM need to gain support for /usr/lib/pam.d/)
mv $PREPARE/etc/pam.d/ $PREPARE/usr/share/factory/etc/
mkdir $PREPARE/usr/share/factory/etc/security/
mv $PREPARE/etc/security/pam_env.conf $PREPARE/usr/share/factory/etc/security/
mv $PREPARE/etc/security/namespace.conf $PREPARE/usr/share/factory/etc/security/
mv $PREPARE/etc/security/limits.conf $PREPARE/usr/share/factory/etc/security/
cat > $PREPARE/usr/lib/tmpfiles.d/factory-pam.conf <<EOF
C /etc/pam.d - - - -
C /etc/security - - - -
F /etc/environment - - - - ""
EOF

# copy RPM database to /usr
mv $PREPARE/var/lib/rpm/ $PREPARE/usr/lib/rpm/db/
mkdir -p $PREPARE/usr/lib/rpm/macros.d/
cat > $PREPARE/usr/lib/rpm/macros.d/macros.rpmdb <<EOF
%_dbpath /usr/lib/rpm/db
EOF

# keep yum working
mv $PREPARE/etc/yum $PREPARE/usr/share/factory/etc/
mv $PREPARE/etc/yum.conf $PREPARE/usr/share/factory/etc/
mv $PREPARE/etc/yum.repos.d/ $PREPARE/usr/share/factory/etc/
mv $PREPARE/etc/pki/ $PREPARE/usr/share/factory/etc/
cat > $PREPARE/usr/lib/tmpfiles.d/factory-yum.conf <<EOF
C /etc/yum.conf - - - -
C /etc/yum - - - -
C /etc/yum.repos.d - - - -
EOF

cat > $PREPARE/usr/lib/tmpfiles.d/factory-pki.conf <<EOF
C /etc/pki - - - -
EOF

# make sure we always have a working root login
cat > $PREPARE/usr/lib/tmpfiles.d/factory-shadow.conf <<EOF
F /etc/shadow 0000 - - - root::::::::
EOF

# enable DHCP for all Ethernet interfaces
mkdir -p $PREPARE/usr/lib/systemd/network
cat > $PREPARE/usr/lib/systemd/network/dhcp.network <<EOF
[Match]
Name=en*

[Network]
DHCP=yes
EOF

( 
    MACHINE_ID=$(</etc/machine-id)
    cd $PREPARE/lib/modules
    for v in *; do
	for f in config System.map vmlinuz; do
	    [[ -f $PREPARE/boot/${f}-${v} ]] || continue
	    mv -v $PREPARE/boot/${f}-${v} $f
	done
	for f in initrd kernel; do
	    [[ -f $PREPARE/boot/$MACHINE_ID/$v/$f ]] || continue
	    mv -v $PREPARE/boot/$MACHINE_ID/$v/$f $f
	done
	[[ -f vmlinuz ]] && mv vmlinuz kernel
	touch -r "$v"/kernel "$PREPARE/lib/modules"
    done
)


rm -rf -- "$PREPARE/usr/bin.usrmove-new"
echo "Make a copy of \`$PREPARE/usr/bin'."
[[ -d "$PREPARE/usr/bin" ]] \
    && cp -ax -l "$PREPARE/usr/bin" "$PREPARE/usr/bin.usrmove-new"
echo "Merge the copy with \`$PREPARE/usr/sbin'."
[[ -d "$PREPARE/usr/bin.usrmove-new" ]] \
    || mkdir -p "$PREPARE/usr/bin.usrmove-new"
cp -axT $CP_HARDLINK --backup --suffix=.usrmove~ "$PREPARE/usr/sbin" "$PREPARE/usr/bin.usrmove-new"
echo "Clean up duplicates in \`$PREPARE/usr/bin'."
# delete all symlinks that have been backed up
find "$PREPARE/usr/bin.usrmove-new" -type l -name '*.usrmove~' -delete || :
# replace symlink with backed up binary
find "$PREPARE/usr/bin.usrmove-new" \
    -name '*.usrmove~' \
    -type f \
    -exec bash -c 'p="{}";o=${p%%.usrmove~};
                       [[ -L "$o" ]] && mv -f "$p" "$o"' ';' || :

touch -r "$PREPARE/usr/bin" "$PREPARE/usr/bin.usrmove-new"
rm -fr "$PREPARE/usr/bin"
mv "$PREPARE/usr/bin.usrmove-new" "$PREPARE/usr/bin"
rm -fr "$PREPARE/usr/sbin"

mv $PREPARE/usr/lib64 $PREPARE/usr/lib/x86_64-linux-gnu
ln -sfnr $PREPARE/usr/lib/x86_64-linux-gnu $PREPARE/usr/lib64

for i in \
    $PREPARE/usr \
    $PREPARE/usr/lib \
    $PREPARE/usr/lib/rpm \
    $PREPARE/usr/lib/systemd/network \
    $PREPARE/usr/lib/systemd/network/* \
    $PREPARE/usr/lib/tmpfiles.d \
    $PREPARE/usr/lib/tmpfiles.d/factory-*.conf \
    $PREPARE/usr/lib/rpm/macros.d \
    $PREPARE/usr/lib/rpm/macros.d/macros.rpmdb \
    $PREPARE/usr/share \
    $PREPARE/usr/share/factory \
    $PREPARE/usr/share/factory/etc \
    $PREPARE/usr/share/factory/etc/security \
    $PREPARE/usr/share/factory/etc/security/* \
    ; do
    [[ -e $i ]] || continue
    touch -r $PREPARE/etc/os-release "$i"
done

(
    cd $PREPARE
    for i in *; do
	[[ $i == usr ]] && continue
	rm -fr "$i"
    done
)


VENDOR="org.particle.OS:x86_64"
VERSION=$(date -u +'%Y%m%d%H%M%S')
SNAPSHOT_NAME="usr:$VENDOR:$VERSION"

cd  "$MASTER"
while read a a a g a a a a v; do
    [[ $v ]] || continue
    gen="$g"
    vol="$v"
done < <(btrfs subvolume list usr)

rsync -Pavorx --delete-after "$PREPARE"/usr/ "$MASTER"/usr/

btrfs subvolume snapshot -r usr "$SNAPSHOT_NAME"

#btrfs subvolume find-new | fgrep -m 1 -q inode || exit 0

if [[ $vol != "usr" ]]; then
    btrfs send -p "$vol" "$SNAPSHOT_NAME" -f $TMPSTORE/usr:$VENDOR:"${vol##*:}-$VERSION".btrfsinc
    xz -T0 $TMPSTORE/usr:$VENDOR:"${vol##*:}-$VERSION".btrfsinc
    mv $TMPSTORE/usr:$VENDOR:"${vol##*:}-$VERSION".btrfsinc* $STORE/increment/
fi

LATEST="$STORE/images/usr:$VENDOR:latest.btrfs.xz"

if ! [[ -f "$LATEST" ]] || (( ($(date +%s) - $(stat -L --format %Y "$LATEST" )) > (24*60*60) )); then
    btrfs send "$SNAPSHOT_NAME" -f "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    xz -T0 "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    mv "$TMPSTORE/$SNAPSHOT_NAME.btrfs"* $STORE/images/
    ln -sfnr $STORE/images/"$SNAPSHOT_NAME.btrfs"* "$LATEST"
fi

chcon -R --type=httpd_sys_content_t $STORE
chmod -R a+r  $STORE
printf "\n### finished\n"
