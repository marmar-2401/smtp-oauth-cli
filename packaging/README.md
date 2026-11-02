# Build the application-authentication RPM

Upstream: tarickb/sasl-xoauth2 `release-0.28`, commit
`35c732eca1eb67de04d417e77848a3326626fab2`. The tag was verified against GitHub.
This includes upstream curl lifetime fix `456c907bbc1a431af2726c1aac61bb6921c2e561`.
`application-auth.patch` is our independent implementation, not PR 123.
Upstream and this patch use Apache-2.0; see `UPSTREAM-LICENSE`.

Build on an isolated **matching EL major version and architecture**, not on clients.
Enable your organization's approved repositories providing jsoncpp-devel and the
other build dependencies. As root on the builder:

```bash
dnf install -y gcc-c++ cmake make pkgconf-pkg-config libcurl-devel jsoncpp-devel cyrus-sasl-devel rpm-build /usr/bin/curl patch
bash packaging/build-rpm.sh /root/smtp-rpm-build
```

The directory must not exist. The script downloads only the pinned source, verifies
its SHA-256, applies the checked-in patch, runs tests in `%check`, and emits binary
and source RPMs. These are reproducible **source inputs**; byte-identical RPMs also
require a pinned toolchain/build environment. Use your signing/release process to
approve artifacts. Do not use `--nodeps` or overwrite a stock plugin manually.

The distinct package `sasl-xoauth2-m365-cli` explicitly conflicts with stock
`sasl-xoauth2`, because Cyrus discovers the module at the same path. Replacement is
an operator-reviewed package transaction. The client deployment does no compilation,
package removal or network source download.

The default upstream grant stays delegated. Explicit `grant_type=client_credentials`
selects a separate native path with tenant endpoint validation, encoded form values,
HTTPS only, TLS verification, no redirects, 10/45 second connection/total timeouts,
256 KiB response bound, real expiry minus 60-second renewal margin, a bounded stable
file lock, and atomic mode-600 cache replacement. No refresh-token field is used.
Shared SASL token/request/response trace logging is redacted for both modes.

Local tests: `bash tests/run.sh /absolute/path/to/pinned-source-archive.tar.gz` requires
cmake, C++17, pkg-config, curl/jsoncpp/Cyrus development packages, jq and ShellCheck.
Deployment tests run as root in an isolated container and mock host commands.
CI builds/testing do not deploy or send mail. The managed workspace cannot fetch
mirrors.almalinux.org, so the EL build matrix runs on GitHub-hosted runners. Check
the exact commit’s Actions results; container build success does not establish
live EL/SELinux/Microsoft acceptance, which remains a release gate.
