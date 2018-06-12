all: ubuntu-chroot/ubuntu-chroot

check:
	@shellcheck -x ./migrate.sh

migrate: all
	sudo ./migrate.sh

ubuntu-chroot/ubuntu-chroot:
	git submodule update --init --recursive


.PHONY: all check migrate