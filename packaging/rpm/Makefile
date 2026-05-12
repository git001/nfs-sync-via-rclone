# Build the nfs-sync RPM.
#
# Usage:
#   make srpm                 # build source RPM only (portable to mock/copr)
#   make rpm                  # build binary RPM locally (needs rpmbuild)
#   make rpm-el8              # build inside RHEL 8 mock chroot
#   make rpm-el9              # build inside RHEL 9 mock chroot
#   make rpm-el10             # build inside RHEL 10 mock chroot
#   make clean

NAME    := nfs-sync
VERSION := 1.0.0
TOPDIR  := $(CURDIR)/_build
SRCDIR  := $(CURDIR)/../../rclone
TARBALL := $(TOPDIR)/SOURCES/$(NAME)-$(VERSION).tar.gz
SPEC    := $(CURDIR)/$(NAME).spec

# Files that go into the source tarball.
SOURCES := \
    nfs-sync.sh \
    sync-bench.sh \
    nfs-sync.service \
    nfs-sync-failure.service \
    nfs-sync.timer \
    nfs-sync.defaults \
    nfs-sync.logrotate \
    rclone.conf

.PHONY: all srpm rpm clean tarball rpm-el8 rpm-el9 rpm-el10

all: rpm

tarball: $(TARBALL)

$(TARBALL):
	mkdir -p $(TOPDIR)/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	tmpdir=$$(mktemp -d) && \
	mkdir -p $$tmpdir/$(NAME)-$(VERSION) && \
	for f in $(SOURCES); do cp $(SRCDIR)/$$f $$tmpdir/$(NAME)-$(VERSION)/; done && \
	tar -C $$tmpdir -czf $@ $(NAME)-$(VERSION) && \
	rm -rf $$tmpdir

srpm: tarball
	rpmbuild --define "_topdir $(TOPDIR)" -bs $(SPEC)
	@echo "==> SRPM at $(TOPDIR)/SRPMS/"
	@ls -1 $(TOPDIR)/SRPMS/

rpm: tarball
	rpmbuild --define "_topdir $(TOPDIR)" -ba $(SPEC)
	@echo "==> RPM at $(TOPDIR)/RPMS/noarch/"
	@ls -1 $(TOPDIR)/RPMS/noarch/

# Mock builds — require: dnf install mock; usermod -aG mock $USER
rpm-el8: srpm
	mock -r rocky-8-x86_64 --rebuild $(TOPDIR)/SRPMS/$(NAME)-$(VERSION)-*.src.rpm

rpm-el9: srpm
	mock -r rocky-9-x86_64 --rebuild $(TOPDIR)/SRPMS/$(NAME)-$(VERSION)-*.src.rpm

rpm-el10: srpm
	mock -r rocky-10-x86_64 --rebuild $(TOPDIR)/SRPMS/$(NAME)-$(VERSION)-*.src.rpm

clean:
	rm -rf $(TOPDIR)
