#!/bin/bash
set -e
set -o pipefail

readonly ROOT="$(mktemp --tmpdir="/run/" -d -t updateusr.XXXXXX)"
readonly USRDIR=$(readlink -f ${1:-/usr})
trap '
    ret=$?;
    rm -f "$ROOT"/update.img "$ROOT"/update.torrent*
    mountpoint -q "$ROOT" && umount "$ROOT"
    rmdir "$ROOT"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

mntp="$USRDIR"

while ! DEV=$(findmnt -e -v -n -o 'SOURCE' --target "$mntp"); do
    mntp=${mntp%/*}
done

mkdir -p "$ROOT"
mount "$DEV" -o subvol=/ "$ROOT"

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
    declare -a vols
    readarray -t vols < <(btrfs_find_usr_os "$1" "$2")

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
        printf -- "btrfs subvolume for $1 not found\n" >&2
        exit 1
    fi

    printf -- "${vols[$maxindex]}\n"
}

currentsubvol=$(btrfs_subvolume_name "$USRDIR")
USRVOL=${currentsubvol##usr:}
USRVOL=${USRVOL%:*}
usrsubvol=$(btrfs_find_newest "$ROOT" "$USRVOL")

clean_vols()
{
    declare -a vols
    readarray -t vols < <(btrfs_find_usr_os "$ROOT" "$USRVOL")

    for (( i=0; i < ${#vols[@]}; i++)); do
        [[ "${vols[$i]}" == "$usrsubvol" ]] && continue
        [[ "${vols[$i]}" == "$currentsubvol" ]] && continue

        printf -- "Removing old volume: %s\n" "${vols[$i]}"

        for kdir in "$ROOT"/"${vols[$i]}"/lib/modules/*; do
            [[ -d $kdir ]] || continue
            (
                cd "$kdir"
                for b in bootloader*.conf; do
                    [[ -f "$b" ]] || continue
                    # copy over the kernel and initrds
                    while read key val; do
                        case "$key" in
                            linux|initrd)
                                # replace \ with /
                                p=${val//\\//}
                                # create the base directory
                                rm -f "/boot/${p%/*}"/$key
                                rmdir "/boot/${p%/*}" &>/dev/null || :
                        esac
                    done < "$b"
                    rm -f /boot/loader/entries/"$b"
                done
            )
        done

        btrfs subvolume delete "$ROOT"/"${vols[$i]}"
    done
}


while true; do
    [[ -d "$ROOT/$usrsubvol" ]] || exit 0

    clean_vols

    if ! curl --head -s --globoff --location --retry 3 --fail --output /dev/null -- \
        "http://particles.surfsite.org/torrents/increment/$usrsubvol.btrfsinc.xz.torrent"; then
        printf -- "No further updates available. Latest is $usrsubvol\n"
        break
    fi

    curl --globoff --location --retry 3 --fail --show-error --output - -- \
        "http://particles.surfsite.org/torrents/increment/$usrsubvol.btrfsinc.xz.torrent" \
        > "$ROOT"/update.torrent

    ctorrent -D 10000000 -e 0 -a -s "$ROOT"/update.img "$ROOT"/update.torrent </dev/null

    oldusrsubvol="$usrsubvol"

    xzcat < "$ROOT"/update.img | btrfs receive "$ROOT"

    rm -f "$ROOT"/update.img "$ROOT"/update.torrent*

    usrsubvol=$(btrfs_find_newest "$ROOT" "$USRVOL")

    [[ $oldusrsubvol == "$usrsubvol" ]] && break

    printf -- "Installed $usrsubvol\n"
done

for kdir in "$ROOT"/"$usrsubvol"/lib/modules/*; do
    [[ -d $kdir ]] || continue
    (
        cd "$kdir"
        for b in bootloader*.conf; do
            [[ -f "$b" ]] || continue
            [[ -f /boot/loader/entries/"$b" ]] && continue
            printf -- "Installing bootloader $b for $usrsubvol\n"

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

exit 0
sync
