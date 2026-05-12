Name:           nfs-sync
Version:        1.0.0
Release:        1%{?dist}
Summary:        Periodic NFS → Azure Blob sync via rclone
License:        Apache-2.0
URL:            https://example.invalid/nfs-sync
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  systemd-rpm-macros

Requires:       rclone >= 1.58
Requires:       bash
Requires:       util-linux
Requires:       coreutils
Requires:       systemd
Requires(pre):  shadow-utils
%{?systemd_requires}

%description
Hardened, idempotent one-shot sync from an NFS mount to an Azure Blob
container using rclone. Ships systemd .service + .timer units, a
benchmark helper, and a sample rclone configuration.

Designed for high-volume NFS workloads on the order of 1M+ files. The
periodic timer runs as a dedicated system user, with flock-based
overlap protection and quiescence filtering to avoid uploading files
that are still being written.

See /usr/share/doc/%{name}/ for setup notes; run nfs-sync-bench(1)
before enabling the timer.

%prep
%setup -q

%build
# No build step — shell + config files only.

%install
rm -rf %{buildroot}

# Executables
install -d -m 0755 %{buildroot}%{_bindir}
install -m 0755 nfs-sync.sh   %{buildroot}%{_bindir}/nfs-sync
install -m 0755 sync-bench.sh %{buildroot}%{_bindir}/nfs-sync-bench

# systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 nfs-sync.service         %{buildroot}%{_unitdir}/nfs-sync.service
install -m 0644 nfs-sync-failure.service %{buildroot}%{_unitdir}/nfs-sync-failure.service
install -m 0644 nfs-sync.timer           %{buildroot}%{_unitdir}/nfs-sync.timer

# Config (templates marked %config(noreplace) so upgrades don't clobber)
install -d -m 0755 %{buildroot}%{_sysconfdir}/rclone
install -m 0600 rclone.conf %{buildroot}%{_sysconfdir}/rclone/rclone.conf

install -d -m 0755 %{buildroot}%{_sysconfdir}/default
install -m 0644 nfs-sync.defaults %{buildroot}%{_sysconfdir}/default/nfs-sync

install -d -m 0755 %{buildroot}%{_sysconfdir}/logrotate.d
install -m 0644 nfs-sync.logrotate %{buildroot}%{_sysconfdir}/logrotate.d/nfs-sync

# Log dir
install -d -m 0750 %{buildroot}%{_localstatedir}/log/nfs-sync

%pre
getent group nfs-sync >/dev/null || groupadd --system nfs-sync
getent passwd nfs-sync >/dev/null || \
    useradd --system --gid nfs-sync --no-create-home \
            --home-dir /nonexistent --shell /sbin/nologin \
            --comment "nfs-sync service" nfs-sync
exit 0

%post
%systemd_post nfs-sync.service nfs-sync.timer

%preun
%systemd_preun nfs-sync.service nfs-sync.timer

%postun
%systemd_postun_with_restart nfs-sync.service nfs-sync.timer

%files
%{_bindir}/nfs-sync
%{_bindir}/nfs-sync-bench
%{_unitdir}/nfs-sync.service
%{_unitdir}/nfs-sync-failure.service
%{_unitdir}/nfs-sync.timer
%config(noreplace) %attr(0600,root,root) %{_sysconfdir}/rclone/rclone.conf
%config(noreplace) %{_sysconfdir}/default/nfs-sync
%config(noreplace) %{_sysconfdir}/logrotate.d/nfs-sync
%attr(0750,nfs-sync,nfs-sync) %dir %{_localstatedir}/log/nfs-sync

%changelog
* Tue May 12 2026 Build Bot <noreply@example.invalid> - 1.0.0-1
- Initial package: nfs-sync.sh, sync-bench.sh, systemd units, config templates.
