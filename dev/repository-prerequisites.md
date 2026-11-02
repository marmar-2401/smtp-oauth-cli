# Repository prerequisites (researched 2026-11-02)

The installer checks actual installed/available packages before suggesting changes.
These standard repository IDs are defaults, not requirements to replace working
approved mirrors or RHUI/Satellite configurations. All automatic builds/checks in
this release target x86_64. Detection for preinstalled packages remains separate.

| Distribution | Major | Development repository | JSON development dependency |
|---|---|---|---|
| AlmaLinux / Rocky | 8 | `powertools` | `epel` (`epel-release`) |
| AlmaLinux / Rocky | 9 | `crb` | `epel` (`epel-release`) |
| AlmaLinux / Rocky | 10 | `crb` | Already in CRB; no EPEL setup |
| Oracle Linux | 8 / 9 | `olN_codeready_builder` | `olN_developer_EPEL` (`oracle-epel-release-elN`) |
| Oracle Linux | 10 | `ol10_codeready_builder` | Already in CodeReady Builder; no EPEL setup |
| RHEL | 8 / 9 | `codeready-builder-for-rhel-N-x86_64-rpms` | `epel` (Fedora's matching release RPM) |
| RHEL | 10 | `codeready-builder-for-rhel-10-x86_64-rpms` | Already in CodeReady Builder; no EPEL setup |

`N` is the detected major. Standard base repositories are `baseos` / `appstream`
on Alma/Rocky, `olN_baseos_latest` / `olN_appstream` on Oracle, and
`rhel-N-for-x86_64-baseos-rpms` / `rhel-N-for-x86_64-appstream-rpms` on RHEL.
Alma/Rocky's `extras` is considered only to obtain an otherwise unavailable
`epel-release`. No testing, devel, EPEL Next, cross-major, or cross-distro OS
repository is added. Existing definitions are enabled through vendor tools;
missing definitions require administrator repair, except documented EPEL release
package installation. `dnf-plugins-core` is offered only if config-manager is absent.

Direct package requirements stay: gcc-c++, cmake, make, pkgconf-pkg-config,
libcurl-devel, jsoncpp-devel, cyrus-sasl-devel, rpm-build, patch, postfix,
cyrus-sasl, cyrus-sasl-lib, jq, ca-certificates, util-linux, iproute, policycoreutils,
policycoreutils-python-utils, shadow-utils and procps-ng. `curl` is requested only
when its command is absent, preserving systems that already supply curl-minimal.
DNF resolves transitive dependencies at installation; no fixed package versions,
module changes, forced removals, signature bypass, or TLS override are used.

## Official evidence

- [Fedora EPEL setup](https://docs.fedoraproject.org/en-US/epel/getting-started/)
  documents the matching EPEL release RPMs, RHEL CodeReady Builder IDs and the
  CRB/PowerTools prerequisite. [Fedora jsoncpp-devel](https://packages.fedoraproject.org/pkgs/jsoncpp/jsoncpp-devel/)
  lists EPEL 8/9 builds.
- [Rocky repository matrix](https://docs.rockylinux.org/10/teams/rel_eng/repo/)
  explicitly lists 8/9/10 repository IDs. [Alma repository guide](https://wiki.almalinux.org/repos/AlmaLinux.html)
  and [EPEL guide](https://wiki.almalinux.org/repos/Extras.html) cover 8/9;
  [Alma's EL10 change](https://almalinux.org/ta/blog/2025-09-08-enabling-crb-by-default-for-almalinux10/)
  explains that CRB is now enabled by default on updated AlmaLinux 10.
- [Oracle release packages](https://yum.oracle.com/getting-started.html) documents
  oracle-epel-release-el8/9/10. [Oracle upgrade repository mapping](https://docs.oracle.com/en-us/iaas/oracle-linux/leapp-ol9/ol9-leapp-supported-repositories-in-leapp-upgrades.htm)
  confirms the 8/9 CodeReady Builder IDs. The official `oraclelinux:10` image
  (digest `sha256:c45341d07ee8d2397656d34e3e17306bc60c92ac4243da2ecfe8cdee8f25c01e`)
  was inspected offline: it uses DNF 4.20 and `ol10_codeready_builder`, not
  `el10_codeready_builder`. [Oracle's current EL10 package listing](https://yum.oracle.com/repo/OracleLinux/OL10/codeready/builder/x86_64/index.html)
  contains `jsoncpp-devel-1.9.5-9.el10.x86_64`.
- [RHEL 10 package manifest](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/package_manifest/index)
  places jsoncpp-devel in CodeReady Builder and cyrus-sasl-devel in AppStream.
  [RHEL 8 AppStream manifest](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/package_manifest/appstream-repository)
  documents standard development/runtime packages. Live queries, rather than
  assumptions about an enabled repo name, determine availability on each host.
- [Red Hat SCA status explanation](https://access.redhat.com/solutions/7080864)
  establishes that `Overall Status: Disabled` is not an entitlement failure.
  The checker uses identity and separately offered/reachable repository content;
  it never registers or attaches a subscription.
- [DNF commands](https://dnf.readthedocs.io/en/latest/command_ref.html) and
  [configuration](https://dnf.readthedocs.io/en/latest/conf_ref.html) define
  cache-only repolist/repoquery, refresh and skip_if_unavailable. Failed metadata
  refresh is never treated as evidence that a package does not exist.

## Validation and limits

`dev/tests/repositories.sh` mocks all twelve distro/major combinations, missing and
disabled repo definitions, explicit versus installation-only consent, EPEL/helper
setup, approved mirrors, exclusions, missing packages, DNS/TLS/network/403/metadata
failures, and RHEL unregistered/unoffered-content/SCA/RHUI paths. It does not change
real repository settings. The native source tests, deployment regression tests,
ShellCheck and syntax checks also passed in a disposable Ubuntu container.

A second test used real DNF 4.20 in the official Oracle Linux 10 container with
network disabled and a controlled file:// package metadata fixture. Repository
listing, refresh, architecture-filtered query and approved-mirror acceptance passed.
This verifies DNF integration, not availability of a real production mirror or a
successful complete EL installation. No live repository enablement, RHSM
registration, tenant operation or blocked artifact request was performed.

Live EL8/9/10 repository transactions, all twelve booted platforms, direct RHEL,
SELinux, reboot, Microsoft delivery and token renewal still require acceptance.
