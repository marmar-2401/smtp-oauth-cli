#!/bin/bash
# shellcheck disable=SC1090,SC2034
# The sourced installer consumes the platform/consent globals in these fixtures.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "${SCRIPT_UNDER_TEST:-$repo/smtp-oauth-deploy.sh}"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
WORK=$sandbox/work; mkdir "$WORK"
export LC_ALL=C
declare -A fixture=()
actions=$sandbox/actions
identity=registered; entitlement=yes; metadata_error=''; absent_package=''; manager=yes; QUERY_FAIL=0
reset_fixture(){
 repository_profile
 fixture=(["$BASE_REPO"]=enabled ["$APP_REPO"]=enabled ["$DEV_REPO"]=disabled [extras]=enabled)
 [[ $PLATFORM_MAJOR == 10 ]] || fixture["$EPEL_REPO"]=missing
 identity=registered; entitlement=yes; metadata_error=''; absent_package=''; manager=yes; QUERY_FAIL=0
 REPO_SETUP=1 YES=1
 : > "$actions"
}
detect_platform(){ :; }
rpm(){ return 1; }
subscription-manager(){
 case "$1" in
 identity) [[ $identity != unregistered ]] || { echo 'This system is not yet registered.'; return 1; }; return 0;;
 repos)
  if [[ $2 == --list ]]; then
   [[ $entitlement != yes ]] || printf 'Repo ID: %s\n' "$DEV_REPO" "$BASE_REPO" "$APP_REPO"
  else fixture["$3"]=enabled; echo "rhsm enable $3" >> "$actions"; fi;;
 esac
}
dnf(){
 local args=" $* " id p ready=1
 case "$args" in
 *' repolist '*)
  echo 'repo id repo name status'
  for id in "${!fixture[@]}"; do [[ ${fixture[$id]} == missing ]] || echo "$id Vendor repository ${fixture[$id]}"; done;;
 *' makecache '*) [[ -z $metadata_error ]] || { echo "$metadata_error"; return 1; };;
 *' repoquery '*)
  (( QUERY_FAIL == 0 )) || { echo 'invalid metadata' >&2; return 1; }
  if [[ $args == *' epel-release '* ]]; then
   [[ ${fixture[extras]} != enabled ]] || echo epel-release
   return 0
  fi
  [[ ${fixture[$DEV_REPO]:-missing} == enabled ]] || ready=0
  if [[ $PLATFORM_MAJOR != 10 && ${fixture[$EPEL_REPO]:-missing} != enabled ]]; then ready=0; fi
  for p in "${DEPENDENCY_PACKAGES[@]}"; do
   [[ $p != jsoncpp-devel || $ready == 1 ]] || continue
   [[ $p != "$absent_package" ]] || continue
   [[ $p != jq || ${base_gated:-0} != 1 || ${fixture[$APP_REPO]:-missing} == enabled ]] || continue
   echo "$p"
  done;;
 *' config-manager --help '*) [[ $manager == yes ]];;
 *' config-manager --set-enabled '*) id=${*: -1}; fixture["$id"]=enabled; echo "enable $id" >> "$actions";;
 *' install '*)
  echo "install ${*: -1}" >> "$actions"
  if [[ $args == *dnf-plugins-core* ]]; then manager=yes
  elif [[ $args == *epel-release* ]]; then fixture["$EPEL_REPO"]=enabled
  else return 99; fi;;
 *) echo "Unexpected DNF command: $*" >&2; return 99;;
 esac
}
# Every distro-major combination: diagnostics are read-only; explicit setup fixes only the matching repos.
for PLATFORM_ID in almalinux rocky rhel ol; do
 for PLATFORM_MAJOR in 8 9 10; do
  PLATFORM_ARCH=x86_64
  reset_fixture
  if (repository_preflight check) > "$sandbox/log" 2>&1; then echo 'Expected missing JSON dependency'; exit 1; fi
  [[ ! -s $actions ]]
  grep -q 'Unavailable.*jsoncpp-devel' "$sandbox/log"
  repository_preflight setup > "$sandbox/log" 2>&1
  [[ ${fixture[$DEV_REPO]} == enabled ]]
  if [[ $PLATFORM_MAJOR == 10 ]]; then if grep -qi epel "$actions"; then exit 1; fi; else [[ ${fixture[$EPEL_REPO]} == enabled ]]; fi
  # Existing approved mirrors satisfy dependencies even without the standard repo IDs.
  fixture=([approved-mirror]=enabled)
  dnf_saved=$(declare -f dnf)
  dnf(){ if [[ " $* " == *' repoquery '* ]]; then printf '%s\n' "${DEPENDENCY_PACKAGES[@]}"; elif [[ " $* " == *' repolist '* ]]; then echo 'approved-mirror Vendor enabled'; else :; fi; }
  : > "$actions"; repository_preflight setup > "$sandbox/log" 2>&1
  [[ ! -s $actions ]]
  eval "$dnf_saved"
 done
done
PLATFORM_ID=rocky PLATFORM_MAJOR=9 PLATFORM_ARCH=x86_64
reset_fixture
# DNS, TLS, authorization, timeout and generic metadata failures must stop before package classification/setup.
for metadata_error in 'Curl error (6): Could not resolve host' 'Curl error (60): SSL certificate problem' 'Status code: 403' 'Curl error (28): timed out' 'repomd checksum mismatch'; do
 if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
 [[ ! -s $actions ]]
 if grep -q '^Unavailable' "$sandbox/log"; then exit 1; fi
done
reset_fixture; QUERY_FAIL=1
if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
[[ ! -s $actions ]]; grep -q 'metadata/configuration failed' "$sandbox/log"
# Missing vendor definition is not invented; rejected consent never enables a repository.
reset_fixture; fixture["$DEV_REPO"]=missing
if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
[[ ! -s $actions ]]; grep -q 'no guessed repository URL' "$sandbox/log"
reset_fixture; REPO_SETUP=0; YES=1
if (repository_preflight setup) </dev/null > "$sandbox/log" 2>&1; then exit 1; fi
[[ ! -s $actions ]]; grep -q 'separate consent' "$sandbox/log"
# Missing helper is installed only following consent; extras is enabled only to obtain the release RPM.
reset_fixture; manager=no; fixture[extras]=disabled
repository_preflight setup > "$sandbox/log" 2>&1
grep -q 'install dnf-plugins-core' "$actions"; grep -q 'enable extras' "$actions"
# Already configured disabled EPEL: enable it, never reinstall its release package.
reset_fixture; fixture["$EPEL_REPO"]=disabled
repository_preflight setup > "$sandbox/log" 2>&1
grep -q 'enable epel' "$actions"; if grep -q 'install.*epel' "$actions"; then exit 1; fi
# Genuine remaining package absence is reported, with no unrelated repos added.
reset_fixture; fixture["$DEV_REPO"]=enabled; fixture["$EPEL_REPO"]=enabled; absent_package=jq
if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
[[ ! -s $actions ]]; grep -q 'Unavailable.*jq' "$sandbox/log"
# Disabled default base repositories can be restored with separate consent.
reset_fixture; fixture["$BASE_REPO"]=disabled; fixture["$APP_REPO"]=disabled; base_gated=1
repository_preflight setup > "$sandbox/log" 2>&1
grep -q "enable $BASE_REPO" "$actions"; grep -q "enable $APP_REPO" "$actions"
base_gated=0
# Packages excluded even after setup do not cause additional repositories to be invented.
reset_fixture; fixture["$DEV_REPO"]=enabled; fixture["$EPEL_REPO"]=enabled; absent_package=jsoncpp-devel
if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
[[ ! -s $actions ]]; grep -q 'version locks, exclusions' "$sandbox/log"
# RHSM registration and offered content are distinct. SCA registered identity is accepted.
PLATFORM_ID=rhel
for PLATFORM_MAJOR in 8 9 10; do
 reset_fixture; identity=unregistered
 if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
 [[ ! -s $actions ]]; grep -q 'registration could not be confirmed' "$sandbox/log"
 reset_fixture; entitlement=no
 if (repository_preflight setup) > "$sandbox/log" 2>&1; then exit 1; fi
 [[ ! -s $actions ]]; grep -q 'content entitlement' "$sandbox/log"
 reset_fixture; identity=sca
 repository_preflight setup > "$sandbox/log" 2>&1
 grep -q 'SCA Disabled is not an error' "$sandbox/log"
done
# RHUI/mirrors with usable content do not require installing or registering RHSM.
reset_fixture; fixture["$DEV_REPO"]=enabled
(
 unset -f subscription-manager
 repository_preflight check
) > "$sandbox/log" 2>&1
grep -q 'RHSM is unavailable' "$sandbox/log"
[[ ! -s $actions ]]
PLATFORM_ARCH=aarch64
if (repository_preflight check) > "$sandbox/log" 2>&1; then exit 1; fi
grep -q 'x86_64 only' "$sandbox/log"
echo 'Repository matrix, consent, mirrors, missing definitions/packages, metadata/DNS/TLS/access, helper/EPEL setup and RHEL identity/content checks passed'
