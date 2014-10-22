#!/bin/bash

set -e

#OS="org.fedoraproject.FedoraWorkstation"
#OS_COMPS="Fedora Workstation"

OS=${1:-org.fedoraproject.particle}
OS_COMPS=$2

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

INSTALL="${PARTICLE_ROOT}/install"
PREPARE="${PARTICLE_ROOT}/prepare"
MASTER="${PARTICLE_ROOT}/master"
STORE="${PARTICLE_ROOT}/store"
TMPSTORE="${PARTICLE_ROOT}/tmp"
ARCH="$(uname -m)"
OS_ARCH="$OS:$ARCH"
VERSION="$(date -u +'%Y%m%d%H%M%S')"
SNAPSHOT_NAME="usr:$OS_ARCH:$VERSION"

echo "Testing for prequisites:"
for i in "$PREPARE" "$INSTALL" "$MASTER" "$STORE" "$TMPSTORE"; do
    echo  -n "  $i"
    [[ -d "$i" ]] || ( echo ": Not found" && exit 1 )
    echo
done


HAVE_SELINUX=no

if [ -e /etc/selinux/config  && grep -v enforcing /etc/selinux/config ]; then
	HAVE_SELINUX=yes
fi

[[ -f "$TMPSTORE"/.in_progress ]] && echo "ERROR: Particle creation already in progress" && exit 0
> "$TMPSTORE"/.in_progress

mkdir -p "$INSTALL/$OS"
INSTALL="$INSTALL/$OS"
mkdir -p "$PREPARE/$OS"
PREPARE="$PREPARE/$OS"

trap '
    ret=$?;
    for i in proc dev sys run; do
        umount "$INSTALL/$i" || :
    done
    rm -f "$TMPSTORE"/.in_progress
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

mkdir -p "$INSTALL"/{proc,run,sys,dev}

# mount kernel filesystems
mount --bind /proc "$INSTALL"/proc
mount --bind /dev "$INSTALL"/dev
mount --bind /sys "$INSTALL"/sys

# packages wrongly install stuff here, but /run content does not belong on disk
mount -t tmpfs tmpfs "$INSTALL"/run

# short cut
echo "Testing for existing system"
if false; then
	#[[ -f $INSTALL/var/lib/rpm/Packages ]]; then
    echo "Updating..."

    yum --releasever="$RELEASE" --disablerepo='*' \
        --enablerepo=fedora \
	--enablerepo=$KERNEL_REPO \
	--enablerepo=$CPIO_REPO \
        --nogpg --installroot="$INSTALL" \
        --setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	clean metadata

    if yum -y --releasever="$RELEASE" --disablerepo='*' \
	--enablerepo=fedora \
        --exclude='kernel*' \
	--nogpg --installroot="$INSTALL" \
	--setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	check-update \
	&& yum -y --releasever="$RELEASE" --disablerepo='*' \
	--enablerepo=$KERNEL_REPO \
	--nogpg --installroot="$INSTALL" \
	--setopt=keepcache=0 \
        --setopt=metadata_expire=1m \
	check-update
    then
        exit 0
    fi

    for i in proc dev sys run; do
        umount "$INSTALL/$i" || :
    done
    rm -fr "$INSTALL"/* "$TMPSTORE"/.in_progress
    exec "$SELF"
fi

# create base directories"
# include /var links because yum itself messes up the directories which need to be symlinks
mkdir -p "$INSTALL"/{boot,proc,run,var,sys,dev,etc,var/tmp}
ln -fs ../run "$INSTALL"/var/run
ln -fs ../run/lock "$INSTALL"/var/lock

# make resolver work inside the chroot, yum will need it if called a second time
ln -fs /run/systemd/resolve/resolv.conf "$INSTALL"/etc

printf "\n### yum makecache\n"
echo yum -y --releasever="$RELEASE" --nogpg --installroot="$INSTALL" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --enablerepo=$CPIO_REPO \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
     makecache

printf "\n### download and install base packages\n"
yum -y --releasever="$RELEASE" --nogpg --installroot="$INSTALL" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --enablerepo=$CPIO_REPO \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    install \
    systemd passwd fedora-release \
    procps-ng psmisc less vi tree bash-completion \
    gummiboot dracut dracut-config-generic binutils \
    iputils iproute kbd kbd-misc \
    dosfstools btrfs-progs parted \
    strace ltrace \
    linux-firmware curl gdisk \
    man man-db man-pages \
    openssh-clients aria2

(
    printf -- "BUILD_ID=$VERSION\n"
    printf -- "ID=$OS\n"
    printf -- "PARTICLE_BASEURL_TORRENT_INC='http://particles.surfsite.org/torrents/increment/'\n"
    printf -- "PARTICLE_BASEURL_INC='http://particles.surfsite.org/increment/'\n"
    printf -- "PARTICLE_BASEURL_TORRENT_IMG='http://particles.surfsite.org/torrents/images/'\n"
    printf -- "PARTICLE_BASEURL_IMG='http://particles.surfsite.org/images/'\n"
) >> $INSTALL/etc/os-release


mkdir -p "$INSTALL"/usr/lib/systemd/system/initrd-fs.target.requires

cat > "$INSTALL"/usr/lib/systemd/system/sysroot-usr.mount <<EOF
[Unit]
Before=initrd-fs.target
ConditionPathExists=/etc/initrd-release

[Mount]
What=/dev/gpt-auto-root
Where=/sysroot/usr
Type=btrfs
Options=subvol=$SNAPSHOT_NAME
EOF

ln -snfr "$INSTALL"/usr/lib/systemd/system/sysroot-usr.mount "$INSTALL"/usr/lib/systemd/system/initrd-fs.target.requires/sysroot-usr.mount

cat > "$INSTALL"/usr/lib/systemd/system/sysroot.mount <<EOF
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
cat > "$INSTALL"/etc/dracut.conf.d/particle.conf <<EOF
add_drivers+=' usb-storage '
omit_dracutmodules='i18n resume rootfs-block terminfo usrmount shutdown'
filesystems=' vfat btrfs '
early_microcode="no"
reproducible="yes"
EOF

#cp /etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo $INSTALL/etc/yum.repos.d/fedora-rawhide-kernel-nodebug.repo
for i in $EXTRA_REPOS; do
	[[ -f /etc/yum.repos.d/"$i" ]] || continue
        cp /etc/yum.repos.d/"$i" $INSTALL/etc/yum.repos.d/
done

rm -f $INSTALL/boot/*/*/initrd $INSTALL/boot/initramfs*

printf "\n### download and install kernel\n"
# install after systemd.rpm created the machine-id which kernel-install wants
yum -y --releasever="$RELEASE" --disablerepo='*' \
    --enablerepo=$KERNEL_REPO \
    --nogpg --installroot="$INSTALL" \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    install kernel

[[ $OS_COMPS ]] \
    && yum -y --releasever="$RELEASE" --nogpg --installroot="$INSTALL" \
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
    groupinstall $OS_COMPS

yum -y --releasever="$RELEASE" --nogpg --installroot="$INSTALL" \
    --disablerepo='*' \
    --enablerepo=fedora \
    --downloaddir=$STORE/packages \
    -c ${STORE}/installer/yum.conf \
    remove dracut

mkdir -p /mnt/particle/store/packagelist/
rpm --root "$INSTALL" -qa > "/mnt/particle/store/packagelist/$SNAPSHOT_NAME.rpmlist.txt"

for i in proc dev sys run; do
    umount "$INSTALL/$i" || :
done

rsync -Paqorx --delete-after "$INSTALL"/ "$PREPARE"/

sed -i -e 's#^disable.*##g' "$PREPARE"/lib/systemd/system-preset/90-default.preset

rm -f "$PREPARE"/usr/sbin/fsck.btrfs
ln -sfrn "$PREPARE"/usr/bin/true "$PREPARE"/usr/sbin/fsck.btrfs
# set default target
systemctl --root="$PREPARE" set-default multi-user.target

# Copy os-release (should move to /usr and /etc be a symlink)
cp --reflink=always -a $PREPARE/etc/os-release $PREPARE/usr/lib/

# factory directory to populate /etc
cp -n --reflink=always -a $PREPARE/etc $PREPARE/usr/share/factory/

# add dns fallback
sed -i -e 's#^hosts:.*#\0 [NOTFOUND=return] dns#' $PREPARE/usr/share/factory/etc/nsswitch.conf

# shadow utils
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-shadow-utils.conf <<EOF
C /etc/login.defs - - - -
EOF

# man
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-man.conf <<EOF
C /etc/man_db.conf - - - -
EOF

# resolv.conf
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-resolv.conf <<EOF
L /etc/resolv.conf - - - - /run/systemd/resolve/resolv.conf
EOF

# D-Bus
cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-dbus.conf <<EOF
C /etc/dbus-1 - - - -
EOF

cat > "$PREPARE"/usr/lib/tmpfiles.d/factory-security.conf <<EOF
C /etc/security - - - -
EOF

cat > "$PREPARE"/usr/lib/sysusers.d/fedora-workaround.conf <<EOF
u gdm - "GDM User"
g gdm - -
u dbus - "D-Bus Legacy User"
u usbmuxd - -
u colord - -
g colord - -
g kvm - -
u abrt - -
u lp - -
u apache - -
u man - -
g man - -
g openvpn - -
u radvd - -
u polkitd - -
u rtkit - -
u pulse - -
g avahi - -
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
    MACHINE_ID=$(<$PREPARE/usr/share/factory/etc/machine-id)
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
options    quiet raid=noautodetect rw console=ttyS0,115200n81 console=tty0 kdbus selinux=0
linux      /${OS}-${ARCH}/${VERSION}/vmlinuz
initrd     /${OS}-${ARCH}/${VERSION}/initrd
initrd     /${OS}-${ARCH}/${VERSION}/initrd.root
EOF

	touch -r $v/kernel $v/{initrd,initrd.root,vmlinuz,bootloader-${OS}-${ARCH}-${VERSION}.conf}
    done
)

rm -f $PREPARE/usr/lib/systemd/system/sysroot-usr.mount \
    $PREPARE/usr/lib/systemd/system/initrd-fs.target.requires/sysroot-usr.mount \
    $PREPARE/usr/share/factory/etc/machine-id

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

mkdir -p "$PREPARE"/particle.git 
git clone https://github.com/haraldh/particle.git "$PREPARE"/particle.git 
cp "$PREPARE"/particle.git/btrfs-to-gpt-image.sh "$PREPARE"/usr/bin/system-to-gpt-image
cp "$PREPARE"/particle.git/update-usr.sh "$PREPARE"/usr/bin/system-update
chmod 0755 "$PREPARE"/usr/bin/system-to-gpt-image "$PREPARE"/usr/bin/system-update

for i in \
    $PREPARE/usr \
    $PREPARE/usr/bin/system-to-gpt-image \
    $PREPARE/usr/bin/system-update \
    $PREPARE/usr/lib/os-release \
    $PREPARE/usr/lib/rpm/macros.d/macros.rpmdb \
    $PREPARE/usr/lib/rpm/macros.d \
    $PREPARE/usr/lib/rpm \
    $PREPARE/usr/lib/systemd/network/* \
    $PREPARE/usr/lib/systemd/network \
    $PREPARE/usr/lib/tmpfiles.d/factory-*.conf \
    $PREPARE/usr/lib/tmpfiles.d \
    $PREPARE/usr/lib \
    ; do
    [[ -e $i ]] || continue
    touch -r $PREPARE/etc/system-release "$i"
done

find $PREPARE/usr/share/factory -type f -newer "$TMPSTORE"/.in_progress -print0 | xargs -0 touch -r $PREPARE/etc/system-release

touch -r $PREPARE/usr/lib/locale/locale-archive.tmpl $PREPARE/usr/lib/locale/locale-archive

for i in $PREPARE/usr/lib/*/modules/modules.*; do
    [[ -e $i ]] || continue
    touch -r $PREPARE/usr/lib/*/modules/modules.builtin "$i"
done

cd  "$MASTER"

if ! [[ -d "usr:$OS_ARCH" ]]; then
    btrfs subvolume create "usr:$OS_ARCH"
fi

while read a a a g a a a a v; do
    [[ $v ]] || continue
    [[ $v == usr:$OS_ARCH* ]] || continue
    gen="$g"
    vol="$v"
done < <(btrfs subvolume list "usr:$OS_ARCH")

rsync -Pavorxc --inplace --fuzzy --delete-after "$PREPARE"/usr/ "$MASTER"/"usr:$OS_ARCH"/

btrfs subvolume snapshot -r "usr:$OS_ARCH" "$SNAPSHOT_NAME"

#btrfs subvolume find-new | fgrep -m 1 -q inode || exit 0

if [[ $vol != "usr:$OS_ARCH" ]]; then
    btrfs send -c "$vol" "$SNAPSHOT_NAME" -f $TMPSTORE/usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc
    xz -9 -T0 $TMPSTORE/usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc
    f="usr:$OS_ARCH:"${vol##*:}-$VERSION".btrfsinc.xz"
    mv "$TMPSTORE/$f" $STORE/increment/

    ln -sfn "$f" $STORE/increment/usr:$OS_ARCH:"${vol##*:}".btrfsinc.xz

    mktorrent \
	-o $STORE/torrents/increment/"$f".torrent \
	-w "http://particles.surfsite.org/increment/$f" \
	-a 'http://particles.surfsite.org:6969/announce' \
	"$STORE/increment/$f"

    ln -sfn $STORE/torrents/increment/"$f".torrent $STORE/torrents/increment/usr:$OS_ARCH:"${vol##*:}".btrfsinc.xz.torrent

    for i in \
	"$STORE/increment/$f" \
	$STORE/torrents/increment/"$f".torrent \
	$STORE/increment/usr:$OS_ARCH:"${vol##*:}".btrfsinc.xz \
	$STORE/torrents/increment/usr:$OS_ARCH:"${vol##*:}".btrfsinc.xz.torrent \
	; do
	if [ x$HAVE_SELINUX == xyes ]; then 
	    chcon --type=httpd_sys_content_t "$i"
	fi
	chmod a+r "$i"
    done

    transmission-remote -w "$STORE/increment" -a $STORE/torrents/increment/"$f".torrent
fi

LATEST="$STORE/images/usr:$OS_ARCH:latest.btrfs.xz"

if ! [[ -f "$LATEST" ]] || (( ($(date +%s) - $(stat -L --format %Y "$LATEST" )) > (7*24*60*60) )); then
    btrfs send "$SNAPSHOT_NAME" -f "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    xz -9 -T0 "$TMPSTORE/$SNAPSHOT_NAME.btrfs"
    mv "$TMPSTORE/$SNAPSHOT_NAME.btrfs.xz" $STORE/images/

    mktorrent \
	-o $STORE/torrents/images/"$SNAPSHOT_NAME.btrfs.xz".torrent \
	-w "http://particles.surfsite.org/images/$SNAPSHOT_NAME.btrfs.xz" \
	-a 'http://particles.surfsite.org:6969/announce' \
	$STORE/images/"$SNAPSHOT_NAME.btrfs.xz"

    for i in $STORE/images/"$SNAPSHOT_NAME.btrfs.xz" $STORE/torrents/images/"$SNAPSHOT_NAME.btrfs.xz".torrent; do
	if [ x$HAVE_SELINUX == xyes ]; then 
	    chcon --type=httpd_sys_content_t "$i"
	fi
	chmod a+r "$i"
    done

    transmission-remote -w "$STORE/images" -a "$STORE/torrents/images/$SNAPSHOT_NAME.btrfs.xz.torrent"

    ln -sfn "$SNAPSHOT_NAME.btrfs.xz" "$LATEST"
    ln -sfn $STORE/torrents/images/"$SNAPSHOT_NAME.btrfs.xz".torrent "$STORE/torrents/images/usr:$OS_ARCH:latest.btrfs.xz.torrent"
fi

if [ x$HAVE_SELINUX == xyes ]; then 
	chcon -R --type=httpd_sys_content_t $STORE
fi

chmod -R a+r  $STORE
printf "\n### finished\n"
