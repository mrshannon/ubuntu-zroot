#!/bin/bash


PREFIX=""


__ubuntu_chroot_cleanup() {
    if [[ "$PREFIX" != "" ]]; then
        mount | tac | awk '{print $3}' | grep "$PREFIX/dev" | \
            xargs -i{} umount -lf {}
        mount | tac | awk '{print $3}' | grep "$PREFIX/dev" | \
            xargs -i{} umount -lf {}
        mount | tac | awk '{print $3}' | grep "$PREFIX/dev" | \
            xargs -i{} umount -lf {}
        umount -lf "$(readlink -f "/$PREFIX/etc/resolv.conf")"
    fi
}
trap __ubuntu_chroot_cleanup EXIT


function __ubuntu_chroot_usage() {
    echo "usage: ${0} chroot-dir [command]"
    echo ""
    echo "  -h, --help    show this message"
    echo ""
    echo "If 'command' is unspecified, ubuntu-chroot will launch /bin/bash."

}


function __ubuntu_chroot() {
    if [[ $# -lt 1 ]] || [[ "${1}" = "-h" ]] || [[ "${1}" = "--help" ]]; then
        __ubuntu_chroot_usage
        exit 1
    fi

    PREFIX="$1"
    mount --bind "$(readlink -f /etc/resolv.conf)" \
        "$(readlink -f "/$prefix/etc/resolv.conf")"
    mount --rbind /dev  "/$prefix/dev"
    mount --rbind /proc "/$prefix/proc"
    mount --rbind /sys  "/$prefix/sys"

    if [[ $# -le 1 ]]; then
        chroot "$1" /bin/bash
    else
        chroot "$@"
    fi

    __ubuntu_chroot_cleanup
}


# Call directly if run as script
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    __ubuntu_chroot "$@"
# Export function if sourced.
else
    function ubuntu-chroot() {
        __ubuntu_chroot "$@"
    }
fi
