# Build the nfs-sync .deb.
#
# Usage:
#   make deb                  # build .deb locally (needs dpkg-buildpackage)
#   make deb-debian12         # build inside Debian 12 sbuild chroot
#   make deb-debian13
#   make deb-ubuntu22
#   make deb-ubuntu24
#   make deb-ubuntu26
#   make clean

NAME    := nfs-sync
VERSION := 1.0.0
SRCDIR  := $(CURDIR)/../../rclone
WORKDIR := $(CURDIR)/_build

# Files staged into the source tree at debian-package-build time.
PKG_FILES := \
    nfs-sync.sh \
    sync-bench.sh \
    nfs-sync.defaults \
    nfs-sync.logrotate \
    rclone.conf

.PHONY: all deb stage clean deb-debian12 deb-debian13 deb-ubuntu22 deb-ubuntu24 deb-ubuntu26

all: deb

stage:
	rm -rf $(WORKDIR)
	mkdir -p $(WORKDIR)/$(NAME)-$(VERSION)
	# Copy upstream source files
	for f in $(PKG_FILES); do cp $(SRCDIR)/$$f $(WORKDIR)/$(NAME)-$(VERSION)/; done
	# Copy debian/
	cp -r $(CURDIR)/debian $(WORKDIR)/$(NAME)-$(VERSION)/

deb: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && dpkg-buildpackage -us -uc -b
	@echo "==> .deb at $(WORKDIR)/"
	@ls -1 $(WORKDIR)/*.deb

# sbuild builds — require: apt install sbuild; sbuild-update + chroot setup
deb-debian12: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && sbuild -d bookworm

deb-debian13: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && sbuild -d trixie

deb-ubuntu22: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && sbuild -d jammy

deb-ubuntu24: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && sbuild -d noble

deb-ubuntu26: stage
	cd $(WORKDIR)/$(NAME)-$(VERSION) && sbuild -d resolute

clean:
	rm -rf $(WORKDIR)
