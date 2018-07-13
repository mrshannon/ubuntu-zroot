#!/bin/bash

sed -i '/GRUB_HIDDEN_TIMEOUT=/s/^/#/g' "/target/etc/default/grub" 1>&2
sed -ri '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet\s*|splash\s*//g' \
    /target/etc/default/grub 1>&2
sed -i '/GRUB_TERMINAL=console/s/^#//g' "/target/etc/default/grub" 1>&2

