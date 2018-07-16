migrate | Convert a Ubuntu install to a ZFS root install
================================================================

The included migration script will convert a Ubuntu installation of 16.04 or
later to a ZFS root installation.

The migration script has been tested on the following distributions:

* Ubuntu 18.04

*If you have succefully tested the migration script on a Ubuntu based
distribution please make a pull request to update this list.*

The installation to migrate must be a UEFI install with the ESP at
/root/efi/ESP with a single main / partition with the ext4 fileystem.


Downloading the Script
----------------------

Because *arrowroot* is a dependency you must download with submodules:

```
# git clone --recurse-submodules https://github.com/mrshannon/ubuntu-zroot
```

Migrating an Install
--------------------

From a live CD/USB run the migration script:

```
$ ./migrate sdX
```
where `X` is replaced by the drive letter.

To get help with additional options use:

```
# ./migrate -h
```
