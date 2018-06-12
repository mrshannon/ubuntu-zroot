#!/bin/bash


# Default options.  Change in config.sh.
BOOT_TYPE=UEFI
DISK=sda
EFI_PART=1
ROOT_PART=2
RPOOL=rpool
FILESYSTEMS=(local opt)

SOURCE=/source
TARGET=/target
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CHROOT="$DIR/arrowroot/arrowroot"

if [[ -f config.sh ]]; then
    source config.sh
fi


ANSI_RESET="\\e[0m"
_BOLD="\\e[1m"
BOLD_="\\e[22m"
_ITALICS="\\e[3m"
ITALICS_="\\e[23m"
_RED="\\e[31m"
RED_="\\e[39m"
_GREEN="\\e[32m"
GREEN_="\\e[39m"
_YELLOW="\\e[33m"
YELLOW_="\\e[39m"


function cleanup() {
    echo -e "${ANSI_RESET}"
}
trap cleanup EXIT


function msg() {
    echo -e "--> ${_ITALICS}${1}${ITALICS_}"
}


function msg2() {
    echo -e "${_GREEN}${_BOLD}${1}${BOLD_}${GREEN_}"
}


function warning() {
    echo -e "${_YELLOW}${_BOLD}WARNING: ${1}${BOLD_}${YELLOW_}"
}


function error() {
    echo -e "${_RED}${_BOLD}ERROR: ${1}${BOLD_}${RED_}"
}


function die() {
    error "$1"
    error "Migration FAILED"
    exit 1
}


function trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}


function get_disk_id() {
    find /dev/disk/by-id -name '*' \
        -exec echo -n {}" " \; -exec readlink -f {} \; | \
        awk -v sdx="$1" \
        '($2 ~ sdx"$") && ($1 !~ "wwn|eui|ieee"){print $1}' \
        | grep -o '[^\/]*$'
}


# get memory in MiB
function get_ram() {
    free --mebi | awk '$1 ~ "Mem"{print $2}'
}


function recommended_swap() {
    # based on https://askubuntu.com/a/49138
    local mem
    mem=$(get_ram)
    if [[ "$mem" -le 2024 ]]; then
        echo "$((mem*2))M"
    elif [[ "$mem" -le 8192 ]]; then
        echo "$((mem/1024))G"
    elif [[ "$mem" -le 16384 ]]; then
        echo "8G"
    else
        echo "$((mem/2/1024))G"
    fi
}


disk_id=$(get_disk_id "/dev/${DISK}")


# Ensure running as root.
if [[ "$EUID" -ne 0 ]]; then
    die "Must be root to migrate system to ZFS."
fi


echo -en "${_BOLD}"
echo "This script will attempt to migrate the existing Ubuntu installation"
echo "at /dev/${DISK}${ROOT_PART} to a ZFS ROOT filesystem.  The migration"\
    "script is"
echo -e "${_RED}EXPERIMENTAL${RED_}, it may destroy your data.  Make sure "\
    "you have a backup"
echo "before continuing."
echo -en "${_YELLOW}Do you wish to continue (yes/no): ${YELLOW_}${BOLD_}"
read -r yesno
if [[ "$yesno" != "yes" ]]; then
    msg2 "Exiting..."
    exit 0
fi


# TODO: Add check for FS type
if [[ "$BOOT_TYPE" == "UEFI" ]]; then
    if ! [[ -e "/dev/${DISK}${EFI_PART}"  ]]; then
        die "EFI parition /dev/${DISK}${EFI_PART} does not exist."
    fi
fi


if ! [[ -e "/dev/${DISK}${ROOT_PART}"  ]]; then
    die "Root parition /dev/${DISK}${ROOT_PART} does not exist."
fi


# Unmount target filesystem if running directly after new install.
msg2 "Unmounting existing installation..."
swapoff -a 1>&2
if mount | grep "^/dev/${DISK}${ROOT_PART}" >/dev/null; then
    if ! umount "/dev/${DISK}${ROOT_PART}" 1>&2; then
        die "Could not unmount /dev/${DISK}${ROOT_PART}.".
    fi
fi
if [[ "$BOOT_TYPE" == "UEIF" ]]; then
    if mount | grep "^/dev/${DISK}${EFI_PART}" >/dev/null; then
        if ! umount "/dev/${DISK}${EFI_PART}" 1>&2; then
            die "Could not unmount /dev/${DISK}${EFI_PART}."
        fi
    fi
fi


# Install dependencies.
msg2 "Installing dependencies..."
if ! add-apt-repository universe 1>&2; then
    die "Could not add the 'universe' repository."
fi
if ! apt-get update 1>&2; then
    die "Could not update repository database."
fi
if ! apt-get --yes install dosfstools 1>&2; then
    die "Could not install dosfstools."
fi
if ! apt-get --yes install e2fsprogs 1>&2; then
    die "Could not install e2fsprogs."
fi
if ! apt-get --yes install gdisk 1>&2; then
    die "Could not install gdisk."
fi
if ! apt-get --yes install parted 1>&2; then
    die "Could not install parted."
fi
if ! apt-get --yes install zfs-initramfs 1>&2; then
    die "Could not install zfs-initramfs."
fi


# Check for enough free space.
msg2 "Checking available disk space..."
if ! e2fsck -f "/dev/${DISK}${ROOT_PART}"; then
    die "Failed to "
fi
min_blocks=$(resize2fs -P "/dev/${DISK}${ROOT_PART}" |& tail -n 1 | \
    awk -F: '{print $2}' | trim)
total_blocks=$(dumpe2fs -h "/dev/${DISK}${ROOT_PART}" |& \
    awk -F: '$1 ~ "Block count"{print $2}' | trim)
msg "Filesystem is $((min_blocks*100/total_blocks))% full."
if [[ $((min_blocks*100/total_blocks)) -gt 45 ]]; then
    error "Not enough free space on root partition "\
        "(/dev/${DISK}${ROOT_PART}) for migration."
    die "Delete some files, or expand the root partition, and try again."
fi


# Shrink root partition and move to end.
echo -e "${_GREEN}${_BOLD}Shrinking and moving root partition..." \
    "${BOLD_}${GREEN_}"
if ! resize2fs -M "/dev/${DISK}${ROOT_PART}" 1>&2; then
    die "Could not resize old root filesystem."
fi
block_size=$(dumpe2fs -h "/dev/${DISK}${ROOT_PART}" |& \
    awk -F: '/Block size/{print $2}')
new_size=$((block_size*min_blocks/1024/1024))  # in megabytes
if ! sgdisk --delete "${ROOT_PART}" "/dev/${DISK}" 1>&2; then
    die "Could not resize old root filesystem."
fi
if ! sgdisk --new "${ROOT_PART}":0:+$((new_size + 128))M \
    --typecode "${ROOT_PART}":8300 "/dev/${DISK}" 1>&2; then
    die "Could not resize old root filesystem."
fi
new_part=$((1 + $(sgdisk --print "/dev/${DISK}" | tail +12 | \
    awk -v max=0 '{if($1>max)max=$1}END{print max}')))
if ! sgdisk --new "${new_part}":-$((new_size + 128))M:0 \
    --typecode "${new_part}":8300 "/dev/${DISK}" 1>&2; then
    die "Could not resize old root filesystem."
fi
partprobe "/dev/${DISK}" 1>&2
sleep 1
wipefs -a "/dev/${DISK}${new_part}" 1>&2
if ! dd if="/dev/${DISK}${ROOT_PART}" of="/dev/${DISK}${new_part}" bs=64K \
    status=progress 2>1;
then
    die "Could not resize old root filesystem."
fi
if ! sgdisk --delete "${ROOT_PART}" "/dev/${DISK}" 1>&2; then
    die "Could not resize old root filesystem."
fi
partprobe "/dev/${DISK}" 1>&2
sleep 1


# Mount the source filesystem.
msg2 "Mounting source filesystem at ${SOURCE}..."
mkdir -p "${SOURCE}" 1>&2
if ! mount "/dev/${DISK}$new_part" "${SOURCE}" 1>&2; then
    die "Could not mount old root filesystem."
fi


# Create new ROOT pool.
msg2 "Creating new ZFS ROOT pool ($RPOOL)..."
if ! sgdisk --new "${ROOT_PART}":0:0 --typecode "${ROOT_PART}":BF01 \
    "/dev/${DISK}" 1>&2; then
    die "Could not create partition for ROOT pool."
fi
wipefs -a "/dev/${DISK}${ROOT_PART}" 1>&2
mkdir -p "${TARGET}"  1>&2
sleep 1 # make sure partitions have time to be registered before running zpool
        # create
partprobe "/dev/${DISK}" 1>&2
sleep 1
if ! zpool create -f -o ashift=12 \
    -O atime=off -O canmount=off -O compression=lz4 -O normalization=formD \
    -O xattr=sa -O mountpoint=/ -R /target \
    "$RPOOL" "/dev/disk/by-id/${disk_id}-part${ROOT_PART}" 1>&2; then
    die "Could not create root pool ($RPOOL)."
fi
{
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT;
    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu;
    zfs mount rpool/ROOT/ubuntu;
} 1>&2


# Create ZFS filesystems.
msg2 "Creating ZFS filesystes..."
msg "Creating /home..."
zfs create -o setuid=off "${RPOOL}/home" 1>&2
msg "Creating /root..."
zfs create -o mountpoint=/root "${RPOOL}/home/root" 1>&2
zfs create -o canmount=off -o setuid=off -o exec=off "${RPOOL}/var" 1>&2
msg "Creating /var/cache..."
zfs create -o com.sun:auto-snapshot=false "${RPOOL}/var/cache" 1>&2
msg "Creating /var/log..."
zfs create -o acltype=posixacl -o xattr=sa "${RPOOL}/var/log" 1>&2
msg "Creating /var/spool..."
zfs create -o com.sun:auto-snapshot=false "${RPOOL}/var/spool" 1>&2
msg "Creating /var/tmp..."
zfs create -o com.sun:auto-snapshot=false -o exec=on "${RPOOL}/var/tmp" 1>&2
if [[ " ${FILESYSTEMS[*]} " =~ " local " ]]; then
    msg "Creating /usr/local..."
    zfs create -o mountpoint=/usr/local "${RPOOL}/local" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " opt " ]]; then
    msg "Creating /opt..."
    zfs create ${RPOOL}/opt 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " srv " ]]; then
    msg "Creating /srv..."
    zfs create -o exec=off "${RPOOL}/srv" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " games " ]]; then
    msg "Creating /var/games..."
    zfs create -o exec=on "${RPOOL}/var/games" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " libvirt " ]]; then
    msg "Creating /var/lib/libvirt..."
    zfs create -o mountpoint=/var/lib/libvirt "${RPOOL}/var/libvirt" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mongodb " ]]; then
    msg "Creating /var/lib/mongodb..."
    zfs create -o mountpoint=/var/lib/mongodb "${RPOOL}/var/mongodb" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mysql " ]]; then
    msg "Creating /var/lib/mysql..."
    zfs create -o mountpoint=/var/lib/mysql "${RPOOL}/var/mysql" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " postgres " ]]; then
    msg "Creating /var/lib/postgres..."
    zfs create -o mountpoint=/var/lib/postgres "${RPOOL}/var/postgres" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " nfs " ]]; then
    msg "Creating /var/lib/nfs..."
    zfs create -o com.sun:auto-snapshot=false -o mountpoint=/var/lib/nfs \
        "${RPOOL}/var/nfs" 1>&2
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mail " ]]; then
    msg "Creating /var/mail..."
    zfs create ${RPOOL}/var/mail 1>&2
fi
for user in "${SOURCE}/home"/*; do
    if [[ -d "$user" ]]; then
        user=$(echo "$user" | grep -o '[^\/]*$')
        msg "Creating /home/$user..."
        zfs create "${RPOOL}/home/${user}" 1>&2
        chmod --reference="${SOURCE}/home/${user}" "${TARGET}/home/${user}" \
            1>&2
        chown --reference="${SOURCE}/home/${user}" "${TARGET}/home/${user}" \
            1>&2
        if [[ " ${FILESYSTEMS[*]} " =~ " user-cache " ]]; then
            msg "Creating /home/${user}/.cache..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/.cache" 1>&2
            if [[ -f "${TARGET}/home/${user}/.cache" ]]; then
                chmod --reference="${SOURCE}/home/${user}/.cache" \
                    "${TARGET}/home/${user}/.cache" 1>&2
                chown --reference="${SOURCE}/home/${user}/.cache" \
                    "${TARGET}/home/${user}/.cache" 1>&2
            else
                chmod 755 "${TARGET}/home/${user}/.cache" 1>&2
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/.cache" 1>&2
            fi
        fi
        if [[ " ${FILESYSTEMS[*]} " =~ " user-downloads " ]]; then
            msg "Creating /home/${user}/Downloads..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/Downloads" 1>&2
            if [[ -f "${TARGET}/home/${user}/Downloads" ]]; then
                chmod --reference="/${SOURCE}/home/${user}/Downloads" \
                    "${TARGET}/home/${user}/Downloads" 1>&2
                chown --reference="/${SOURCE}/home/${user}/Downloads" \
                    "${TARGET}/home/${user}/Downloads" 1>&2
            else
                chmod 755 "${TARGET}/home/${user}/Downloads" 1>&2
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/Downloads" 1>&2
            fi
        fi
        if [[ " ${FILESYSTEMS[*]} " =~ " user-scratch " ]]; then
            msg "Creating /home/${user}/Scratch..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/Scratch" 1>&2
            if [[ -f "${TARGET}/home/${user}/Scratch" ]]; then
                chmod --reference="${SOURCE}/home/${user}/Scratch" \
                    "${TARGET}/home/${user}/Scratch" 1>&2
                chown --reference="${SOURCE}/home/${user}/Scratch" \
                    "${TARGET}/home/${user}/Scratch" 1>&2
            else
                chmod 755 "${TARGET}/home/${user}/Scratch" 1>&2
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/Scratch" 1>&2
            fi
        fi
    fi
done
msg "Converting /var/log and /var/tmp to legacy mounting..."
zfs set mountpoint=legacy "${RPOOL}/var/log" 1>&2
zfs set mountpoint=legacy "${RPOOL}/var/tmp" 1>&2
mkdir -p "${TARGET}/var/log" 1>&2
mkdir -p "${TARGET}/var/tmp" 1>&2
mount -t zfs "${RPOOL}/var/log" "${TARGET}/var/log" 1>&2
mount -t zfs "${RPOOL}/var/tmp" "${TARGET}/var/tmp" 1>&2


# Clone root filesystem.
msg2 "Cloning existing installation..."
rsync -aX --info=progress2 "${SOURCE}/." "${TARGET}/." 
rm -f "${TARGET}/swapfile" 1>&2


# Prepare new filesystem to be ZFS bootable.
msg2 "Fixing fstab..."
awk '($2 != "/" && $3 != "swap"){print $0}' "${TARGET}/etc/fstab" > \
    "${TARGET}/etc/fstab.tmp" 
mv "${TARGET}/etc/fstab.tmp" "${TARGET}/etc/fstab" 1>&2
echo "${RPOOL}/var/log  /var/log  zfs  defaults  0  0" \
    >>"${TARGET}/etc/fstab"
echo "${RPOOL}/var/tmp  /var/tmp  zfs  defaults  0  0" \
    >>"${TARGET}/etc/fstab"
echo RESUME=none > /etc/initramfs-tools/conf.d/resume


# Install GRUB.
echo -e "${_GREEN}${_BOLD}Installing GRUB...${BOLD_}${GREEN_}"
if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    mount "/dev/${DISK}${EFI_PART}" "${TARGET}/boot/efi"
fi
"${CHROOT}" "${TARGET}" add-apt-repository universe 1>&2
"${CHROOT}" "${TARGET}" apt-get update 1>&2
"${CHROOT}" "${TARGET}" apt-get --yes install \
    zfs-initramfs grub-efi-amd64 zfs-auto-snapshot 1>&2
if ! "${CHROOT}" "${TARGET}" grub-probe / | grep 'zfs' >/dev/null; then
    die "GRUB does not support ZFS booting, migration failed."
fi
if ! "${CHROOT}" "${TARGET}" update-initramfs -c -k all 1>&2; then
    die "Could not build initramfs."
fi
sed -i '/GRUB_HIDDEN_TIMEOUT=/s/^/#/g' "${TARGET}/etc/default/grub" 1>&2
sed -ri '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet\s*|splash\s*//g' \
    ${TARGET}/etc/default/grub 1>&2
sed -i '/GRUB_TERMINAL=console/s/^#//g' "${TARGET}/etc/default/grub" 1>&2
if ! "${CHROOT}" "${TARGET}" update-grub 1>&2; then
    die "Could not generate GRUB configuration file."
fi
if ! "${CHROOT}" "${TARGET}" grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi --bootloader-id=ubuntu \
    --recheck --no-floppy 1>&2;
then
    die "An error occurred during the installation of GRUB."
fi
if ! ls "${TARGET}"/boot/grub/*/zfs.mod 1>&2; then
    die "GRUB does not support ZFS booting."
fi


# Remove old root filesystem.
msg2 "Removing old ROOT filesystem..."
umount "${SOURCE}"
if ! sgdisk --delete "${new_part}" "/dev/${DISK}" 1>&2; then
    die "Could not delete old root partition."
fi
if ! sgdisk --delete "${ROOT_PART}" "/dev/${DISK}" 1>&2; then
    die "Could not expand ZFS ROOT partition."
fi
if ! sgdisk --new "${ROOT_PART}":0:0 --typecode "${ROOT_PART}":BF01 \
    "/dev/${DISK}" 1>&2;
then
    die "Could not expand ZFS ROOT partition."
fi
partprobe "/dev/${DISK}" 1>&2
sleep 1


# Expand ZFS ROOT pool.
echo -e "${_GREEN}${_BOLD}Epanding ZFS ROOT pool...${BOLD_}${GREEN_}"
zpool set autoexpand=on "${RPOOL}" 1>&2
if ! zpool online -e "${RPOOL}" "/dev/disk/by-id/${disk_id}-part${ROOT_PART}" \
    1>&2;
then
    zpool set autoexpand=off "${RPOOL}" 1>&2
    die "Could not expand the ROOT pool."
fi
zpool set autoexpand=off "${RPOOL}" 1>&2


# Create VDEV to use for swap.
if [[ "${SWAP}" == "auto" ]]; then
    SWAP=$(recommended_swap)
fi
if [[ ("${SWAP}" =~ ^[0-9]+M$) || ("${SWAP}" =~ ^[0-9]+G$) ]]; then
    msg2 "Creating ${SWAP} VDEV for swap..."
    if ! zfs create -V 4G -b "$(getconf PAGESIZE)" -o compression=zle \
        -o logbias=throughput -o sync=always \
        -o primarycache=metadata -o secondarycache=none \
        -o com.sun:auto-snapshot=false "${RPOOL}/swap" 1>&2;
    then
        die "Could not create VDEV for swap space."
    fi
    if ! mkswap -f "/dev/zvol/${RPOOL}/swap" 1>&2; then
        die "Could not create swap."
    fi
    echo "/dev/zvol/${RPOOL}/swap"  none  swap  defaults  0  0 >> \
        "$TARGET/etc/fstab"
fi


# Snapshot initial state.
msg2 "Creating initial snapshot of ${RPOOL}/ROOT/ubuntu..."
zfs snapshot -r "${RPOOL}/ROOT/ubuntu@initial"
if [[ " ${FILESYSTEMS[*]} " =~ " local " ]]; then
    msg "Creating initial snapshot of ${RPOOL}/local..."
    zfs snapshot -r "${RPOOL}/local@initial"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " opt " ]]; then
    msg "Creating initial snapshot of ${RPOOL}/opt..."
    zfs snapshot -r "${RPOOL}/opt@initial"
fi


# Unmount ROOT pool.
msg2 "Unmounting ROOT pool..."
if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    umount "${TARGET}/boot/efi"
fi
zpool export "${RPOOL}"
umount "${SOURCE}"


msg2 "Migration complete, you may now reboot into your new ZFS ROOT pool."
