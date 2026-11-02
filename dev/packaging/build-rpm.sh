#!/usr/bin/env bash
# Build on an isolated EL builder of the SAME major version/architecture as clients.
set -Eeuo pipefail
umask 022
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${1:?Usage: bash dev/packaging/build-rpm.sh /absolute/NEW-build-directory}
[[ $root == /* && ! -e $root ]] || { echo 'Use a new absolute output directory.' >&2; exit 1; }
mkdir -p "$root"/{SOURCES,SPECS,BUILD,RPMS,SRPMS,BUILDROOT}
commit=35c732eca1eb67de04d417e77848a3326626fab2
archive=sasl-xoauth2-$commit.tar.gz
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 120 "https://codeload.github.com/tarickb/sasl-xoauth2/tar.gz/$commit" -o "$root/SOURCES/$archive"
printf '%s  %s\n' a7ca803a2f7fb40befa7e208886911d139c643f1a50031eabc0b78cac47dad33 "$root/SOURCES/$archive" | sha256sum -c -
cp "$here/application-auth.patch" "$root/SOURCES/"
cp "$here/sasl-xoauth2-m365-cli.spec" "$root/SPECS/"
rpmbuild --define "_topdir $root" -ba "$root/SPECS/sasl-xoauth2-m365-cli.spec"
