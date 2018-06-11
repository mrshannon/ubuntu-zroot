#!/bin/bash


BOOT_TYPE=UEFI # UEFI or BIOS
DISK=sda
EFI_PART=1  # ignored if BOOT_TYPE is BIOS
ROOT_PART=2
RPOOL=rpool  # name of the root pool
# Specify which paths should be thier own ZFS filesystems.
# Comment out those you do not want.
FILESYSTEMS=(
    local           # /usr/local
    opt             # /opt
    # srv             # /srv - noexec
    # games           # /var/games
    # mysql           # /var/lib/mysql
    # postgres        # /var/lib/postgres
    # mongodb         # /var/lib/mongodb
    # libvirt         # /var/lib/libvirt
    # nfs \           # /var/lib/nfs - no snapshots
    # mail            # /var/mail
    # user-cache      # /home/USER/.cache - no snapshots
    # user-downloads  # /home/USER/Downloads - no snapshots
    # user-scratch    # /home/USER/Scratch - no snapshosts
    )

SOURCE=/source
TARGET=/target

if [[ -f config.sh ]]; then
    source config.sh
fi


ANSI_RESET="\\e[0m"
_BOLD="\\e[1m"
BOLD_="\\e[22m"
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


function trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}


function get_disk_id() {
    find /dev/disk/by-id -name '*' \
        -exec echo -n {}" " \; -exec readlink -f {} \; | \
        awk -v sdx="$1" \
        '($2 ~ sdx"$") && ($1 !~ "wwn|eui|ieee"){print $1}' \
        | grep  '[^\/]*$'
}


# print memory in MiB
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


# Parse inputs.
disk_id=$(get_disk_id "/dev/${DISK}")


# Ensure running as root.
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${_RED}${_BOLD}Must be root to migrate system to ZFS." \
        "${BOLD_}${RED_}"
    exit 1
fi


echo -en "${_BOLD}"
echo "This script will attempt to migrate the existing Ubuntu installation"
echo "at /dev/${DISK}${ROOT_PART} to a ZFS ROOT filesystem.  The migration"\
    "script is"
echo -e "${_RED}EXPERIMENTAL${RED_}, it may destroy your data.  Make sure" \
    "you have a backup"
echo "before continuing."
echo -en "${_YELLOW}Do you wish to continue (yes/no): ${YELLOW_}${BOLD_}"
read -r yesno
if [[ "$yesno" != "yes" ]]; then
    exit 0
fi


# Unmount target filesystem if running directly after new install.
echo -e "${_GREEN}${_BOLD}Unmounting existing installation...${BOLD_}${GREEN_}"
swapoff -a
if mount | grep "^/dev/${DISK}${ROOT_PART}" >/dev/null; then
    umount "/dev/${DISK}${ROOT_PART}"
fi
if [[ "$BOOT_TYPE" == "UEIF" ]]; then
    if mount | grep "^/dev/${DISK}${EFI_PART}" >/dev/null; then
        umount "/dev/${DISK}${EFI_PART}"
    fi
fi


# Install dependencies.
echo -e "${_GREEN}${_BOLD}Installing dependencies...${BOLD_}${GREEN_}"
add-apt-repository universe
apt-get --yes install gdisk parted dosfstools zfs-initramfs


# Check for enough free space.
echo -e "${_GREEN}${_BOLD}Checking available disk space...${BOLD_}${GREEN_}"
e2fsck -f "/dev/${DISK}${ROOT_PART}"
min_blocks=$(resize2fs -P "/dev/${DISK}${ROOT_PART}" |& tail -n 1 | \
    awk -F: '{print $2}' | trim)
total_blocks=$(dumpe2fs -h "/dev/${DISK}${ROOT_PART}" |& \
    awk -F: '$1 ~ "Block count"{print $2}' | trim)
echo "Filesystem is $((min_blocks*100/total_blocks))% full."
if [[ $((min_blocks*100/total_blocks)) -gt 45 ]]; then
    echo -e "${_RED}${_BOLD}Not enough free space on root partition " \
        "(/dev/${DISK}${ROOT_PART}) for migration."
    echo "Delete some files, or expand the root partition, and try again."
    echo -e "${BOLD_}${RED_}"
    exit 1
fi


# Shrink root partition and move to end.
echo -e "${_GREEN}${_BOLD}Shrinking and moving root partition..." \
    "${BOLD_}${GREEN_}"
reisze2fs -M "/dev/${DISK}${ROOT_PART}"
block_size=$(dumpe2fs -h "/dev/${DISK}${ROOT_PART}" |& \
    awk -F: '/Block size/{print $2}')
new_size=$((block_size*min_blocks/1024/1024))  # in megabytes
sgdisk --delete "${ROOT_PART}" "/dev/${DISK}"
sgdisk --new "${ROOT_PART}":0:+$((new_size + 128))M \
    --typecode "${ROOT_PART}":8300 "/dev/${DISK}"
new_part=$((1 + $(sgdisk --print "/dev/${DISK}" | tail +12 | \
    awk -v max=0 '{if($1>max)max=$1}END{print max}')))
sgdisk --new "${new_part}":-$((new_size + 128))M:0 \
    --typecode "${new_part}":8300 "/dev/${DISK}"
dd if="/dev/${DISK}${ROOT_PART}" of="/dev/${DISK}${new_part}" bs=64K \
    status=progress
sgdisk --delete "${ROOT_PART}" "/dev/${DISK}"
partprobe "/dev/${DISK}"


# Mount the source filesystem.
echo -e "${_GREEN}${_BOLD}Mounting source filesystem at ${SOURCE}..." \
    "${BOLD_}${GREEN_}"
partprobe "/dev/${DISK}"
mkdir -p "${SOURCE}"
mount "/dev/${DISK}$new_part" "${SOURCE}"


# Create new ROOT pool.
echo -e "${_GREEN}${_BOLD}Creating new ZFS ROOT pool ($RPOOL)..." \
    "${BOLD_}${GREEN_}"
sgdisk --new "${ROOT_PART}":0:0 --typecode "${ROOT_PART}":BF01 \
    "/dev/${DISK}"
mkdir /target
partprobe "/dev/${DISK}"
zpool create -f -o ashift=12 \
    -O atime=off -O canmount=off -O compression=lz4 -O normalization=formD \
    -O xattr=sa -O mountpoint=/ -R /target \
    "$RPOOL" "/dev/disk/by-id/${disk_id}-part${ROOT_PART}"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu


# Create ZFS filesystems.
echo -e "${_GREEN}${_BOLD}Creating ZFS filesystes...${BOLD_}${GREEN_}"
echo "Creating /home..."
zfs create -o setuid=off "${RPOOL}/home"
echo "Creating /root..."
zfs create -o mountpoint=/root "${RPOOL}/home/root"
zfs create -o canmount=off -o setuid=off -o exec=off "${RPOOL}/var"
echo "Creating /var/cache..."
zfs create -o com.sun:auto-snapshot=false "${RPOOL}/var/cache"
echo "Creating /var/log..."
zfs create -o acltype=posixacl -o xattr=sa "${RPOOL}/var/log"
echo "Creating /var/spool..."
zfs create "${RPOOL}/var/spool"
echo "Creating /var/tmp..."
zfs create -o com.sun:auto-snapshot=false -o exec=on "${RPOOL}/var/tmp"
if [[ " ${FILESYSTEMS[*]} " =~ " local " ]]; then
    echo "Creating /usr/local..."
    zfs create -o mountpoint=/usr/local "${RPOOL}/local"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " opt " ]]; then
    echo "Creating /opt..."
    zfs create ${RPOOL}/opt
fi
if [[ " ${FILESYSTEMS[*]} " =~ " srv " ]]; then
    echo "Creating /srv..."
    zfs create -o exec=off "${RPOOL}/srv"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " games " ]]; then
    echo "Creating /var/games..."
    zfs create -o exec=on "${RPOOL}/var/games"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " libvirt " ]]; then
    echo "Creating /var/lib/libvirt..."
    zfs create -o mountpoint=/var/lib/libvirt "${RPOOL}/var/libvirt"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mongodb " ]]; then
    echo "Creating /var/lib/mongodb..."
    zfs create -o mountpoint=/var/lib/mongodb "${RPOOL}/var/mongodb"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mysql " ]]; then
    echo "Creating /var/lib/mysql..."
    zfs create -o mountpoint=/var/lib/mysql "${RPOOL}/var/mysql"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " postgres " ]]; then
    echo "Creating /var/lib/postgres..."
    zfs create -o mountpoint=/var/lib/postgres "${RPOOL}/var/postgres"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " nfs " ]]; then
    echo "Creating /var/lib/nfs..."
    zfs create -o com.sun:auto-snapshot=false -o mountpoint=/var/lib/nfs \
        "${RPOOL}/var/nfs"
fi
if [[ " ${FILESYSTEMS[*]} " =~ " mail " ]]; then
    echo "Creating /var/mail..."
    zfs create ${RPOOL}/var/mail
fi
for user in "/${SOURCE}/home"/*; do
    if [[ -d "$user" ]]; then
        user=$(echo "$user" | grep '[^\/]*$')
        echo "Creating /home/$user..."
        zfs create "${RPOOL}/home/${user}"
        chmod --reference="${SOURCE}/home/${user}" "${TARGET}/home/${user}"
        chown --reference="${SOURCE}/home/${user}" "${TARGET}/home/${user}"
        if [[ " ${FILESYSTEMS[*]} " =~ " user-cache " ]]; then
            echo "Creating /home/${user}/.cache..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/.cache"
            if [[ -f "${TARGET}/home/${user}/.cache" ]]; then
                chmod --reference="${SOURCE}/home/${user}/.cache" \
                    "${TARGET}/home/${user}/.cache"
                chown --reference="${SOURCE}/home/${user}/.cache" \
                    "${TARGET}/home/${user}/.cache"
            else
                chmod 755 "${TARGET}/home/${user}/.cache"
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/.cache"
            fi
        fi
        if [[ " ${FILESYSTEMS[*]} " =~ " user-downloads " ]]; then
            echo "Creating /home/${user}/Downloads..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/Downloads"
            if [[ -f "${TARGET}/home/${user}/Downloads" ]]; then
                chmod --reference="/${SOURCE}/home/${user}/Downloads" \
                    "${TARGET}/home/${user}/Downloads"
                chown --reference="/${SOURCE}/home/${user}/Downloads" \
                    "${TARGET}/home/${user}/Downloads"
            else
                chmod 755 "${TARGET}/home/${user}/Downloads"
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/Downloads"
            fi
        fi
        if [[ " ${FILESYSTEMS[*]} " =~ " user-scratch " ]]; then
            echo "Creating /home/${user}/Scratch..."
            zfs create -o com.sun:auto-snapshot=false \
                "rpool/home/${user}/Scratch"
            if [[ -f "${TARGET}/home/${user}/Scratch" ]]; then
                chmod --reference="${SOURCE}/home/${user}/Scratch" \
                    "${TARGET}/home/${user}/Scratch"
                chown --reference="${SOURCE}/home/${user}/Scratch" \
                    "${TARGET}/home/${user}/Scratch"
            else
                chmod 755 "${TARGET}/home/${user}/Scratch"
                chown --reference="${SOURCE}/home/${user}" \
                    "${TARGET}/home/${user}/Scratch"
            fi
        fi
    fi
done
zfs set mountpoint=legacy "${RPOOL}/var/log"
zfs set mountpoint=legacy "${RPOOL}/var/tmp"
mkdir -p "${TARGET}/var/log"
mkdir -p "${TARGET}/var/tmp"
mount -t zfs "${RPOOL}/var/log" "${TARGET}/var/log"
mount -t zfs "${RPOOL}/var/tmp" "${TARGET}/var/tmp"


# Clone root filesystem.
echo -e "${_GREEN}${_BOLD}Cloning existing installation...${BOLD_}${GREEN_}"
rsync -aX --info=progress2 "${SOURCE}/." "${TARGET}/."
rm "${TARGET}/swapfile"


# Prepare new filesystem to be ZFS bootable.
echo -e "${_GREEN}${_BOLD}Fixing fstab...${BOLD_}${GREEN_}"
awk '($2 != "/" && $3 != "swap"){print $0}' > "${TARGET}/etc/fstab.tmp"
mv "${TARGET}/etc/fstab.tmp" "${TARGET}/etc/fstab"
echo "${RPOOL}/var/log  /var/log  zfs  defaults  0  0" >> /${TARGET}/etc/fstab
echo "${RPOOL}/var/tmp  /var/tmp  zfs  defaults  0  0" >> /${TARGET}/etc/fstab
echo RESUME=none > /etc/initramfs-tools/conf.d/resume


# Install GRUB.
echo -e "${_GREEN}${_BOLD}Installing GRUB...${BOLD_}${GREEN_}"
if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    mount "/dev/${DISK}${EFI_PART}" "${TARGET}/boot/efi"
fi
./ubuntu-chroot.sh "${TARGET}" apt-get --yes install zfs-initramfs grub-efi-amd64
if ! ./ubuntu-chroot.sh /${TARGET} grub-probe | grep 'zfs' >/dev/null; then
    echo -e "${_RED}${_BOLD}GRUB does not support ZFS booting," \
        "migration failed.${BOLD_}${RED_}"
    exit 1
fi
./ubuntu-chroot.sh "${TARGET}" update-initramfs -c -k all
sed -i '/GRUB_HIDDEN_TIMEOUT=/s/^/#/g' "${TARGET}/etc/default/grub"
sed -ri '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet\s*|splash\s*//g' \
    ${TARGET}/etc/default/grub
sed -i '/GRUB_TERMINAL=console/s/^#//g' "${TARGET}/etc/default/grub"
./ubuntu-chroot.sh "${TARGET}" update-grub
./ubuntu-chroot.sh "${TARGET}" grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
if ! ls "${TARGET}"/boot/grub/*/zfs.mod; then
    echo -e "${_RED}${_BOLD}GRUB does not support ZFS booting," \
        "migration failed.${BOLD_}${RED_}"
    exit 1
fi


# Remove old root filesystem.
echo -e "${_GREEN}${_BOLD}Removing old ROOT filesystem...${BOLD_}${GREEN_}"
sgdisk --delete "${new_part}" "/dev/${DISK}"
sgdisk --delete "${ROOT_PART}" "/dev/${DISK}"
sgdisk --new "${ROOT_PART}":0:0 --typecode "${ROOT_PART}":BF01 "/dev/${DISK}"
partprobe "/dev/${DISK}"


# Expand ZFS ROOT pool.
echo -e "${_GREEN}${_BOLD}Epanding ZFS ROOT pool...${BOLD_}${GREEN_}"
partprobe "/dev/${DISK}"
zfs list
zpool set autoexpand=on "${RPOOL}"
zpool online -e "${RPOOL}" "/dev/disk/bi-id/${disk_id}-part${ROOT_PART}"
zpool set autoexpand=off "${RPOOL}"
zfs list


# Create VDEV to use for swap.
if [[ "${SWAP}" == "auto" ]]; then
    SWAP=$(recommended_swap)
fi
if [[ ("${SWAP}" =~ ^[0-9]+M$) || ("${SWAP}" =~ ^[0-9]+G$) ]]; then
    echo -e "${_GREEN}${_BOLD}Creating ${SWAP} VDEV for swap..." \
        "${BOLD_}${GREEN_}"
    zfs create -V 4G -b "$(getconf PAGESIZE)" -o compression=zle \
        -o logbias=throughput -o sync=always \
        -o primarycache=metadata -o secondarycache=none \
        -o com.sun:auto-snapshot=false "${RPOOL}/swap"
    mkswap -f "/dev/zvol/${RPOOL}/swap"
    echo "/dev/zvol/${RPOOL}/swap"  none  swap  defaults  0  0 >> \
        "$TARGET/etc/fstab"
fi


# Unmount ROOT pool.
echo -e "${_GREEN}${_BOLD}Unmounting ROOT pool...${BOLD_}${GREEN_}"
if [[ "${BOOT_TYPE}" == "UEFI" ]]; then
    umount "${TARGET}/boot/efi"
fi
zpool export "${RPOOL}"
umount "${SOURCE}"


echo -e "${_GREEN}${_BOLD}Migration complete, you may now reboot into your" \
    "new ZFS ROOT pool.${BOLD_}${GREEN_}"
