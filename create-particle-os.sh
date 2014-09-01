#!/bin/bash

set -e

SELF="$0"
RELEASE=rawhide
KERNEL_REPO=fedora-rawhide-kernel-nodebug
#KERNEL_REPO=jwboyer-kernel-playground
#SYSTEMD_REPO=harald-systemd-kdbus-git
CPIO_REPO=harald-cpio-reproducible
#EXTRA_REPOS="jwboyer-kernel-playground-fedora-rawhide.repo harald-systemd-kdbus-git-fedora-rawhide.repo harald-cpio-reproducible-fedora-rawhide.repo"
#EXTRA_REPOS="fedora-rawhide-kernel-nodebug.repo harald-systemd-kdbus-git-fedora-rawhide.repo harald-cpio-reproducible-fedora-rawhide.repo"
EXTRA_REPOS="fedora-rawhide-kernel-nodebug.repo harald-cpio-reproducible-fedora-rawhide.repo"

PARTICLE_ROOT=/mnt/particle

DEST="${PARTICLE_ROOT}/install"
MASTER="${PARTICLE_ROOT}/master"
PREPARE="${PARTICLE_ROOT}/prepare"
INSTALL="${PARTICLE_ROOT}/install"
STORE="${PARTICLE_ROOT}/store"
TMPSTORE="${PARTICLE_ROOT}/tmp"
ARCH="$(arch)"
OS="org.fedoraproject.FedoraWorkstation"
OS_ARCH="$OS:$ARCH"
VERSION="$(date -u +'%Y%m%d%H%M%S')"
SNAPSHOT_NAME="usr:$OS_ARCH:$VERSION"

for i in "$PREPARE" "$DEST" "$MASTER" "$STORE" "$TMPSTORE"; do
    [[ -d "$i" ]] || exit 1
done

[[ -f "$TMPSTORE"/.in_progress ]] && exit 0
> "$TMPSTORE"/.in_progress

trap '
    ret=$?;
    for i in proc dev sys run; do
        umount "$DEST/$i" || :
    done
    rm -f "$TMPSTORE"/.in_progress
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
    yum --releasever="$RELEASE" --disablerepo='*' \
        --enablerepo=fedora \
	--enablerepo=$KERNEL_REPO \
	--enablerepo=$CPIO_REPO \
        --nogpg --installroot="$DEST" \
        --setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	clean metadata

    if yum -y --releasever="$RELEASE" --disablerepo='*' \
	--enablerepo=fedora \
        --exclude='kernel*' \
	--nogpg --installroot="$DEST" \
	--setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	check-update \
	&& yum -y --releasever="$RELEASE" --disablerepo='*' \
	--enablerepo=$KERNEL_REPO \
	--nogpg --installroot="$DEST" \
	--setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	check-update
    then
        exit 0
    fi

    for i in proc dev sys run; do
        umount "$DEST/$i" || :
    done
    rm -fr "$DEST"/* "$TMPSTORE"/.in_progress
    exec "$SELF"
fi

# create base directories"
# include /var links because yum itself messes up the directories which need to be symlinks
mkdir -p "$DEST"/{boot,proc,run,var,sys,dev,etc,var/tmp}
ln -fs ../run "$DEST"/var/run
ln -fs ../run/lock "$DEST"/var/lock

# make resolver work inside the chroot, yum will need it if called a second time
ln -fs /run/systemd/resolve/resolv.conf "$DEST"/etc

printf "\n### download and install base packages\n"
yum -y --releasever="$RELEASE" --nogpg --installroot="$DEST" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --enablerepo=$CPIO_REPO \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    install \
    systemd passwd fedora-release \
    procps-ng psmisc less vi tree bash-completion \
    gummiboot dracut dracut-config-generic binutils \
    iputils iproute \
    dosfstools btrfs-progs parted \
    strace linux-firmware

# include the usb-storage kernel module
cat > "$DEST"/etc/dracut.conf.d/usb.conf <<EOF
add_drivers+=' usb-storage '
EOF

(
    printf -- "BUILD_ID=$VERSION\n"
    printf -- "ID=$OS\n"
) >> $DEST/etc/os-release


mkdir -p "$DEST"/usr/lib/systemd/system/initrd-fs.target.requires

cat > "$DEST"/usr/lib/systemd/system/sysroot-usr.mount <<EOF
[Unit]
Before=initrd-fs.target
ConditionPathExists=/etc/initrd-release

[Mount]
What=/dev/gpt-auto-root
Where=/sysroot/usr
Type=btrfs
Options=subvol=$SNAPSHOT_NAME
EOF

ln -snfr "$DEST"/usr/lib/systemd/system/sysroot-usr.mount "$DEST"/usr/lib/systemd/system/initrd-fs.target.requires/sysroot-usr.mount

cat > "$DEST"/usr/lib/systemd/system/sysroot.mount <<EOF
[Unit]
Before=initrd-root-fs.target
ConditionPathExists=/etc/initrd-release

[Mount]
What=/dev/gpt-auto-root
Where=/sysroot
Type=btrfs
Options=rw,subvol=root:default:org.particle.OS:$ARCH
EOF


# include the usb-storage kernel module
cat > "$DEST"/etc/dracut.conf.d/particle.conf <<EOF
early_microcode="no"
reproducible="yes"
EOF

#cp /etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo $DEST/etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo
for i in $EXTRA_REPOS; do
	[[ -f /etc/yum.repos.d/"$i" ]] || continue
        cp /etc/yum.repos.d/"$i" $DEST/etc/yum.repos.d/
done

rm -f $DEST/boot/*/*/initrd $DEST/boot/initramfs*

printf "\n### download and install kernel\n"
# install after systemd.rpm created the machine-id which kernel-install wants
yum -y --releasever="$RELEASE" --disablerepo='*' \
    --enablerepo=$KERNEL_REPO \
    --nogpg --installroot="$DEST" \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    install kernel


yum -y --releasever="$RELEASE" --nogpg --installroot="$DEST" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --enablerepo=$CPIO_REPO \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    --exclude 'kernel*' \
    --exclude 'plymouth*' \
    --exclude 'dracut*' \
    --exclude 'chrony*' \
    --exclude 'abrt*' \
    --skip-broken \
    groupinstall "Fedora Workstation"


yum -y --releasever="$RELEASE" --nogpg --installroot="$DEST" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    remove dracut

rsync -Paqorx --delete-after "$INSTALL"/ "$PREPARE"/

rm -f "$PREPARE"/usr/sbin/fsck.btrfs
ln -sfrn "$PREPARE"/usr/bin/true "$PREPARE"/usr/sbin/fsck.btrfs
# set default target
systemctl --root="$PREPARE" set-default multi-user.target

# Copy os-release (should move to /usr and /etc be a symlink)
cp --reflink=always -a $PREPARE/etc/os-release $PREPARE/usr/lib/

# factory directory to populate /etc
mkdir -p $PREPARE/usr/share/factory/etc/

# shadow utils
mv "$PREPARE"/etc/login.defs "$PREPARE"/usr/share/factory/etc/
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-shadow-utils.conf <<EOF
C /etc/login.defs - - - -
EOF

# D-Bus
mv "$PREPARE"/etc/dbus-1/ "$PREPARE"/usr/share/factory/etc/
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-dbus.conf <<EOF
C /etc/dbus-1 - - - -
EOF

cat > "$PREPARE"/usr/lib/sysusers.d/dbus.conf <<EOF
u dbus - "D-Bus Legacy User"
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
    MACHINE_ID=$(<$PREPARE/etc/machine-id)
    cd $PREPARE/lib/modules
    for v in *; do
	[[ -f $PREPARE/boot/$MACHINE_ID/$v/initrd ]] \
	    && cp --reflink=always -a  $PREPARE/boot/$MACHINE_ID/$v/initrd $v/initrd
	[[ -f $PREPARE/boot/$MACHINE_ID/$v/kernel ]] \
	    && cp --reflink=always -a $PREPARE/boot/$MACHINE_ID/$v/kernel $v/vmlinuz

	for f in config System.map vmlinuz; do
	    [[ -f $PREPARE/boot/${f}-${v} ]] || continue
	    cp --reflink=always -a $PREPARE/boot/${f}-${v} $v/$f
	done

	(
	    cd $PREPARE
	    (
		echo "./usr/lib/systemd/system/sysroot.mount"
		echo "./usr/lib/systemd/system/sysroot-usr.mount"
		echo "./usr/lib/systemd/system/initrd-fs.target.requires"
		echo "./usr/lib/systemd/system/initrd-fs.target.requires/sysroot-usr.mount"
	    ) | cpio -H newc -o --quiet | gzip -n -9 --rsyncable > $PREPARE/usr/lib/modules/$v/initrd.root

	)

	# vfat does not like ":" in filenames
	cat > $v/bootloader-${OS}-${ARCH}-${VERSION}.conf <<EOF
title      $OS $VERSION $ARCH
version    $VERSION
options    quiet raid=noautodetect rw console=ttyS0,115200n81 console=tty0 kdbus
linux      /${OS}-${ARCH}/${VERSION}/vmlinuz
initrd     /${OS}-${ARCH}/${VERSION}/initrd
initrd     /${OS}-${ARCH}/${VERSION}/initrd.root
EOF

	touch -r $v/kernel $v/{initrd,initrd.root,vmlinuz,bootloader-${OS}-${ARCH}-${VERSION}.conf}
    done
)

rm -f $PREPARE/usr/lib/systemd/system/sysroot-usr.mount \
    $PREPARE/usr/lib/systemd/system/initrd-fs.target.requires/sysroot-usr.mount


rm -rf -- "$PREPARE/usr/bin.usrmove-new"
echo "Make a copy of \`$PREPARE/usr/bin'."
[[ -d "$PREPARE/usr/bin" ]] \
    && cp -ax -l "$PREPARE/usr/bin" "$PREPARE/usr/bin.usrmove-new"
echo "Merge the copy with \`$PREPARE/usr/sbin'."
[[ -d "$PREPARE/usr/bin.usrmove-new" ]] \
    || mkdir -p "$PREPARE/usr/bin.usrmove-new"
cp -axT --reflink=always --backup --suffix=.usrmove~ "$PREPARE/usr/sbin" "$PREPARE/usr/bin.usrmove-new"
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

ln -s bin "$PREPARE/usr/sbin"


mv $PREPARE/usr/lib64 $PREPARE/usr/lib/x86_64-linux-gnu
ln -sfnr $PREPARE/usr/lib/x86_64-linux-gnu $PREPARE/usr/lib64

for i in \
    $PREPARE/usr \
    $PREPARE/usr/lib/rpm/macros.d/macros.rpmdb \
    $PREPARE/usr/lib/rpm/macros.d \
    $PREPARE/usr/lib/rpm \
    $PREPARE/usr/lib/systemd/network/* \
    $PREPARE/usr/lib/systemd/network \
    $PREPARE/usr/lib/tmpfiles.d/factory-*.conf \
    $PREPARE/usr/lib/tmpfiles.d \
    $PREPARE/usr/lib \
    $PREPARE/usr/share/factory/etc/security/* \
    $PREPARE/usr/share/factory/etc/security \
    $PREPARE/usr/share/factory/etc/pki/ca-trust/extracted/java/cacerts \
    $PREPARE/usr/share/factory/etc \
    $PREPARE/usr/share/factory \
    $PREPARE/usr/share \
    ; do
    [[ -e $i ]] || continue
    touch -r $PREPARE/etc/os-release "$i"
done

touch -r $PREPARE/usr/lib/locale/locale-archive.tmpl $PREPARE/usr/lib/locale/locale-archive

for i in $PREPARE/usr/lib/*/modules/modules.*; do
    [[ -e $i ]] || continue
    touch -r $PREPARE/usr/lib/*/modules/modules.builtin "$i"
done

(
    cd $PREPARE
    for i in *; do
	[[ $i == usr ]] && continue
	rm -fr "$i"
    done
)


cd  "$MASTER"
while read a a a g a a a a v; do
    [[ $v ]] || continue
    gen="$g"
    vol="$v"
done < <(btrfs subvolume list usr)

rsync -Pavorxc --inplace --delete-after "$PREPARE"/usr/ "$MASTER"/usr/

btrfs subvolume snapshot -r usr "$SNAPSHOT_NAME"

#btrfs subvolume find-new | fgrep -m 1 -q inode || exit 0

if [[ $vol != "usr" ]]; then
    btrfs send -p "$vol" "$SNAPSHOT_NAME" -f $TMPSTORE/usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc
    xz -9 -T0 $TMPSTORE/usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc
    mv $TMPSTORE/usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc.xz $STORE/increment/
    ln -sfn usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc.xz $STORE/increment/usr:$OS_ARCH:"${vol##*:}".btrfsinc.xz
fi

LATEST="$STORE/images/usr:$OS_ARCH:latest.btrfs.xz"

if ! [[ -f "$LATEST" ]] || (( ($(date +%s) - $(stat -L --format %Y "$LATEST" )) > (7*24*60*60) )); then
    btrfs send "$SNAPSHOT_NAME" -f "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    xz -9 -T0 "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    mv "$TMPSTORE/$SNAPSHOT_NAME.btrfs.xz" $STORE/images/
    ln -sfn "$SNAPSHOT_NAME.btrfs.xz" "$LATEST"
fi


cd "$STORE/images"
for i in *; do
    [[ -L $i ]]  && continue
    [[ -f "../torrents/images/$i.torrent" ]] && continue
    mktorrent -o ../torrents/images/"$i".torrent -w "http://particles.surfsite.org/images/$i" -a 'udp://tracker.openbittorrent.com:80/announce' "$i"
done

cd "$STORE/increment"

for i in *; do
    [[ -L $i ]]  && continue
    [[ -f ../torrents/increment/"$i".torrent ]] && continue
    mktorrent -o ../torrents/increment/"$i".torrent -w "http://particles.surfsite.org/increment/$i" -a 'udp://tracker.openbittorrent.com:80/announce' "$i"
done


chcon -R --type=httpd_sys_content_t $STORE
chmod -R a+r  $STORE
printf "\n### finished\n"
