Name: sasl-xoauth2-m365-cli
Version: 0.28
Release: 1.smtpcli%{?dist}
Summary: Cyrus XOAUTH2 with native Microsoft 365 application credentials
License: Apache-2.0
URL: https://github.com/tarickb/sasl-xoauth2
Source0: https://codeload.github.com/tarickb/sasl-xoauth2/tar.gz/35c732eca1eb67de04d417e77848a3326626fab2#/sasl-xoauth2-35c732eca1eb67de04d417e77848a3326626fab2.tar.gz
Patch0: application-auth.patch
BuildRequires: gcc-c++, cmake, make, pkgconfig, libcurl-devel, jsoncpp-devel, cyrus-sasl-devel
Requires: cyrus-sasl-lib
Conflicts: sasl-xoauth2
Provides: smtp-oauth-cli-application-auth = 1

%description
Pinned sasl-xoauth2 release-0.28 plus the separately reviewed smtp-oauth-cli
application authentication patch. Native on-demand client credentials; no daemon.
Conflicts explicitly with the stock plugin because the Cyrus module path is shared.

%prep
%setup -q -n sasl-xoauth2-35c732eca1eb67de04d417e77848a3326626fab2
%patch -P 0 -p1

%build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=%{_lib} -DCMAKE_INSTALL_SYSCONFDIR=/etc -DBuildDocumentation=OFF
cmake --build build --parallel 2

%check
cd build
ctest --output-on-failure

%install
install -D -m 0755 build/src/libsasl-xoauth2.so %{buildroot}%{_libdir}/sasl2/libsasl-xoauth2.so
install -D -m 0755 build/src/test-config %{buildroot}%{_libdir}/sasl-xoauth2/test-config
install -D -m 0644 src/sasl-xoauth2.conf %{buildroot}%{_sysconfdir}/sasl-xoauth2.conf

%files
%license COPYING
%config(noreplace) %{_sysconfdir}/sasl-xoauth2.conf
%{_libdir}/sasl2/libsasl-xoauth2.so
%dir %{_libdir}/sasl-xoauth2
%{_libdir}/sasl-xoauth2/test-config
