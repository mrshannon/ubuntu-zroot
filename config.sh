

BOOT_TYPE=UEFI # UEFI or BIOS
DISK=sda
EFI_PART=1  # ignored if BOOT_TYPE is BIOS
ROOT_PART=2
RPOOL=rpool  # name of the root pool
# Specify which paths should be thier own ZFS filesystems.
# Comment out those you do not want.
SWAP=auto
FILESYSTEMS=(
    local           # /usr/local
    opt             # /opt
    srv             # /srv - noexec
    games           # /var/games
    mysql           # /var/lib/mysql
    postgres        # /var/lib/postgres
    mongodb         # /var/lib/mongodb
    libvirt         # /var/lib/libvirt
    nfs \           # /var/lib/nfs - no snapshots
    mail            # /var/mail
    user-cache      # /home/USER/.cache - no snapshots
    user-downloads  # /home/USER/Downloads - no snapshots
    user-scratch    # /home/USER/Scratch - no snapshosts
    )
