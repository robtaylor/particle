#!/bin/bash
set -e

ROOT=/run/root

trap '
    ret=$?;
    rm -f "$ROOT"/update.img
    mountpoint -q "$ROOT" && umount "$ROOT"
    rmdir /run/root
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

DEV=$(findmnt -e -v -n -o 'SOURCE' --target /usr)
[[ /dev/gpt-auto-root -ef $DEV ]]

mkdir -p "$ROOT"
mount "$DEV" -o subvol=/ "$ROOT"

ARCH=$(uname -m)
case "$ARCH" in
    i686|i586|i486|i386)
        ARCH=i686;;
esac

. /usr/lib/os-release

USRVOL="$ID:$ARCH"

vercmp() {
    local _n1=(${1//./ }) _op=$2 _n2=(${3//./ }) _i _res

    for ((_i=0; ; _i++))
    do
        if [[ ! ${_n1[_i]}${_n2[_i]} ]]; then _res=0
        elif ((${_n1[_i]:-0} > ${_n2[_i]:-0})); then _res=1
        elif ((${_n1[_i]:-0} < ${_n2[_i]:-0})); then _res=2
        else continue
        fi
        break
    done

    case $_op in
        gt) ((_res == 1));;
        ge) ((_res != 2));;
        eq) ((_res == 0));;
        le) ((_res != 1));;
        lt) ((_res == 2));;
        ne) ((_res != 0));;
    esac
}

btrfs_subvolume_name() {
    local key value where="$1"
    while read key value; do
        [[ "$key" != "Name:" ]] && continue
        printf -- "%s" "$value"
        return 0
    done < <(btrfs subvolume show "$where")
    return 1
}

btrfs_find_usr_os() {
    local id gen level path where="$1" what="$2"
    while read id gen level path; do
        [[ "$level" != 5 ]] && continue
        [[ "$path" != usr:$what:* ]] && continue
        printf -- "%s\n" "${path##\<FS_TREE\>/}"
    done < <(btrfs subvolume list -at "$where")
    return 0
}

btrfs_find_newest() {
    local ROOT="$1" USRVOL="$2"
    declare -a vols
    readarray -t vols < <(btrfs_find_usr_os "$ROOT" "$USRVOL")

    maxversion=0
    maxindex=-1
    for (( i=0; i < ${#vols[@]}; i++)); do
        IFS=: read -r name os arch version <<<"${vols[$i]}"
        if vercmp $version gt $maxversion; then
            maxindex="$i"
            maxversion="$version"
        fi
    done

    if (( $maxindex == -1 )); then
        printf -- "btrfs /usr subvolume for $root_os:$root_arch not found\n" >&2
        exit 1
    fi

    printf -- "${vols[$maxindex]}\n"
}

usrsubvol=$(btrfs_find_newest "$ROOT" "$USRVOL")

while true; do
    [[ -d "$ROOT/$usrsubvol" ]] || exit 0

    if ! curl --head -s --globoff --location --retry 3 --fail --output /dev/null -- \
        "http://particles.surfsite.org/increment/$usrsubvol.btrfsinc.xz"; then
        printf -- "No further updates available.\n"
        exit 0
    fi

    curl --globoff --location --retry 3 --fail --show-error --output - -- \
        "http://particles.surfsite.org/increment/$usrsubvol.btrfsinc.xz" \
        > "$ROOT"/update.img

    oldusrsubvol="$usrsubvol"
    xzcat < "$ROOT"/update.img | btrfs receive "$ROOT"
    usrsubvol=$(btrfs_find_newest "$ROOT" "$USRVOL")

    [[ $oldusrsubvol == "$usrsubvol" ]] && exit 0

    for kdir in "$ROOT"/"$usrsubvol"/lib/modules/*; do
        [[ -d $kdir ]] || continue
        (
            cd "$kdir"

            for b in bootloader*.conf; do
                # copy over the kernel and initrds
                while read key val; do
                    case "$key" in
                        linux|initrd)
                            # replace \ with /
                            p=${val//\\//}
                            # create the base directory
                            mkdir -p "/boot/${p%/*}"
                            # and copy the file with the same basename
                            cp "${p##*/}" "/boot/$p"
                    esac
                done < "$b"
                cp "$b" /boot/loader/entries
            done
        )
    done
    printf -- "Installed $usrsubvol\n"
done

exit 0
sync
