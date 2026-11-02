#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# AND/OR guards intentionally fail closed; bash -c expands positional arguments in the child.
set +x

VERSION=3.0.0
STATE=/var/lib/smtp-oauth-cli
TOKENDIR=/var/spool/postfix/smtp-oauth-cli
TOKEN=$TOKENDIR/token.json
CONFIG=/etc/sasl-xoauth2.conf
MAP=/etc/postfix/smtp_oauth_cli_sasl
CA=/etc/pki/tls/certs/ca-bundle.crt
MODULE=smtp_oauth_cli
LEGACY_STATE=/var/lib/smtp-oauth-deploy
LOCK=/run/lock/smtp-oauth-cli.lock
MAILLOG=/var/log/maillog
WORK='' TX='' YES=0 BACKEND='' SELINUX=0 PLUGINVIEWER='' CONFIG_TEST=''
declare -A SETTINGS=()
EMAIL_RX='^[A-Za-z0-9._+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
exists() { [[ -e $1 || -L $1 ]]; }
mailbox_ok() { [[ ${#1} -le 254 && $1 =~ $EMAIL_RX && $1 != *..* ]]; }
confirm() {
    local answer
    (( YES )) && return 0
    [[ -t 0 ]] || die 'Use --yes for an unattended change.'
    read -r -p "$1 [y/N] " answer
    [[ $answer == y || $answer == Y ]] || die 'Cancelled.'
}
protected_file() {
    local path=$1 parent mode
    [[ -f $path && ! -L $path ]] || die 'Configuration must be a regular file, not a symlink.'
    [[ $(realpath -ms -- "$path") == "$(realpath -e -- "$path")" ]] || die 'Symlinked configuration paths are not accepted.'
    [[ $(stat -c %u -- "$path") == 0 ]] || die 'Configuration must be owned by root.'
    mode=$(stat -c %a -- "$path")
    (( (8#$mode & 0077) == 0 )) || die 'Configuration must not grant group or other access; use chmod 600.'
    parent=$(dirname -- "$(realpath -e -- "$path")")
    mode=$(stat -c %a -- "$parent")
    if [[ $(stat -c %u -- "$parent") != 0 ]] || (( (8#$mode & 0022) != 0 )); then
        die 'The containing directory must be root-owned and not writable by group/others.'
    fi
    (( $(stat -c %s -- "$path") <= 262144 )) || die 'Configuration is unexpectedly large.'
}
validate_config() {
    protected_file "$1"
    jq -e '
      type == "object" and
      ((keys - ["provider","mailbox","client_id","client_secret","tenant"]) | length == 0) and
      .provider == "m365" and
      ([.mailbox,.client_id,.client_secret,.tenant] | all(type == "string" and length > 0)) and
      ([.mailbox,.client_id,.tenant] | all(test("[\u0000-\u0020\u007f]") | not)) and
      (.client_secret | length <= 8192 and (test("[\u0000-\u001f\u007f]") | not)) and
      ([.client_id,.tenant] | all(test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))) and
      ([.[]] | all(startswith("REPLACE_WITH_") | not))
    ' "$1" >/dev/null 2>&1 || die 'Invalid Microsoft 365 application JSON. Fill the template; use tenant/application GUIDs and the client secret value. Refresh tokens are not supported.'
    provider=m365; relay=smtp.office365.com
    mailbox=$(jq -r .mailbox "$1"); tenant=$(jq -r .tenant "$1")
    mailbox_ok "$mailbox" || die 'Use a plain ASCII mailbox address.'
    endpoint=https://login.microsoftonline.com/$tenant/oauth2/v2.0/token
}
workdir() {
    [[ -n $WORK ]] && return 0
    WORK=$(mktemp -d /var/tmp/smtp-oauth-cli.XXXXXXXX)
    chmod 700 "$WORK"
}
prepare_candidate() {
    workdir
    chgrp postfix "$WORK"; chmod 710 "$WORK"
    mkdir "$WORK/runtime"; chown postfix:postfix "$WORK/runtime"; chmod 700 "$WORK/runtime"
    jq --arg endpoint "$endpoint" --arg ca "$CA" '{client_id,client_secret,grant_type:"client_credentials",token_endpoint:$endpoint,
      ca_bundle_file:$ca,always_log_to_syslog:"no",log_to_syslog_on_failure:"no",log_full_trace_on_failure:"no"}' "$1" >"$WORK/config.json"
    chmod 640 "$WORK/config.json"; chown root:postfix "$WORK/config.json"
    printf '{}\n' >"$WORK/runtime/token.json"
    chmod 600 "$WORK/runtime/token.json"; chown postfix:postfix "$WORK/runtime/token.json"
    if ! timeout 90 runuser -u postfix -- "$CONFIG_TEST" --config "$WORK/config.json" --token "$WORK/runtime/token.json" >"$WORK/helper.log" 2>&1; then
        die 'Application token request failed. Check the approved credential, expiry, tenant, CA trust and HTTPS access. No candidate was activated; raw output is withheld.'
    fi
    say 'Application token request passed. Postfix acquires and caches tokens on demand; test verifies SMTP authorization separately.'
}
platform_values() {
    PLATFORM_ID=$1; PLATFORM_MAJOR=${2%%.*}; PLATFORM_ARCH=$3
    case "$PLATFORM_ID" in almalinux|rocky|rhel|ol) ;; *) die 'Supported distributions: AlmaLinux, Rocky Linux, RHEL and Oracle Linux.' ;; esac
    case "$PLATFORM_MAJOR" in 8|9|10) ;; *) die 'Supported Enterprise Linux major versions: 8, 9 and 10.' ;; esac
    case "$PLATFORM_ARCH" in x86_64|aarch64) ;; *) die 'Use a reviewed matching build for x86_64 or aarch64; other architectures are not supported.' ;; esac
}
detect_platform() {
    local ID='' VERSION_ID='' VERSION=''  # os-release must not replace script VERSION
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
    # This standard root-owned system file supplies distro and version only.
    # shellcheck disable=SC1091
    . /etc/os-release
    platform_values "$ID" "$VERSION_ID" "$(uname -m)"
}
# Release URLs and digests must be populated from independently verified public assets.
# An empty catalog fails before changing the host; never guess a download URL.
declare -A APPROVED_PACKAGE_URLS=() APPROVED_PACKAGE_HASHES=()
select_package_asset() {
    local package_distro=$PLATFORM_ID key
    # Same-major Alma binaries use the RHEL ABI; DNF must resolve every dependency.
    # Never add Alma repositories to RHEL or force an unresolved package transaction.
    [[ $package_distro != rhel ]] || package_distro=almalinux
    key="$package_distro:$PLATFORM_MAJOR:$PLATFORM_ARCH"
    PACKAGE_URL=${APPROVED_PACKAGE_URLS[$key]:-}
    PACKAGE_SHA256=${APPROVED_PACKAGE_HASHES[$key]:-}
    [[ $PLATFORM_ARCH != aarch64 ]] || die 'Automatic aarch64 packages are not available; obtain a matching tested package.'
    [[ -n $PACKAGE_URL && -n $PACKAGE_SHA256 ]] || die "No approved public package is configured for $PLATFORM_ID $PLATFORM_MAJOR $PLATFORM_ARCH. Package publication is pending."
}
bootstrap_install_packages() {
    local path package metadata
    detect_platform
    command -v dnf >/dev/null || die 'DNF is required to install the platform packages.'
    command -v rpm >/dev/null || die 'RPM is required to inspect installed packages.'
    # Already provisioned hosts continue through the existing integrity/capability checks.
    rpm -q sasl-xoauth2-m365-cli >/dev/null 2>&1 && return 0
    rpm -q sasl-xoauth2 >/dev/null 2>&1 && die 'Stock sasl-xoauth2 is installed. Plan its replacement first; no packages were changed.'
    for path in "$STATE" "$LEGACY_STATE" "$TOKENDIR" "$MAP" "$MAP.db" "$MAP.lmdb" "$CONFIG"; do
        exists "$path" && die "Existing relay configuration at $path. Plan migration first; no packages were changed."
    done
    if command -v postconf >/dev/null; then
        [[ -z $(postconf -h relayhost) ]] || die 'Postfix already has a relay configured. Plan migration first; no packages were changed.'
    fi
    protected_file "$INPUT"
    select_package_asset
    [[ $PACKAGE_URL == https://github.com/marmar-2401/smtp-oauth-cli/releases/download/* && $PACKAGE_SHA256 =~ ^[a-f0-9]{64}$ ]] || die 'The approved package catalog is incomplete.'
    say "Detected $PLATFORM_ID $PLATFORM_MAJOR ($PLATFORM_ARCH)."
    say 'Install required OS packages from enabled repositories and the matching OAuth plugin. Packages remain installed if relay setup later fails.'
    confirm 'Install these packages and continue relay setup?'
    dnf --setopt=timeout=30 --setopt=retries=2 install -y ca-certificates jq || die 'Cannot install bootstrap dependencies from the enabled repositories.'
    validate_config "$INPUT"
    if ! command -v curl >/dev/null; then
        dnf --setopt=timeout=30 --setopt=retries=2 install -y curl || die 'Cannot install curl from the enabled repositories.'
    fi
    workdir
    package="$WORK/application-plugin.rpm"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --max-filesize 52428800 --max-redirs 3 \
        --output "$package" "$PACKAGE_URL" || die 'Package download failed. Check HTTPS access and retry.'
    [[ $(sha256sum "$package" | cut -d ' ' -f 1) == "$PACKAGE_SHA256" ]] || die 'Downloaded package failed its automatic integrity check.'
    metadata=$(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}' "$package") || die 'Downloaded file is not a readable RPM.'
    [[ $metadata == "sasl-xoauth2-m365-cli 0.28-1.smtpcli.el$PLATFORM_MAJOR $PLATFORM_ARCH" ]] || die 'Downloaded package does not match this platform.'
    dnf --setopt=timeout=30 --setopt=retries=2 install -y \
        postfix cyrus-sasl cyrus-sasl-lib cyrus-sasl-devel jq ca-certificates \
        util-linux iproute policycoreutils policycoreutils-python-utils "$package" || \
        die 'Package installation failed. Check that approved repositories supply the required dependencies. No repositories were enabled or package removals forced.'
}
prerequisites() {
    local command version
    for command in jq realpath stat flock timeout runuser rpm postconf postmap postfix postqueue systemctl sha256sum getenforce ss; do
        command -v "$command" >/dev/null || die "Missing prerequisite: $command. Install the documented OS packages first."
    done
    detect_platform
    version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' sasl-xoauth2-m365-cli 2>/dev/null) || die 'Install the approved sasl-xoauth2-m365-cli RPM built from dev/packaging/ first.'
    [[ $version == 0.28-1.smtpcli.el"$PLATFORM_MAJOR"* ]] || die 'This deployment requires the reviewed 0.28-1.smtpcli package for this EL major.'
    [[ $(rpm -q --qf '%{ARCH}' sasl-xoauth2-m365-cli) == "$PLATFORM_ARCH" ]] || die 'Installed plugin architecture does not match this host.'
    CONFIG_TEST=$(rpm --eval '%{_libdir}')/sasl-xoauth2/test-config
    [[ -x $CONFIG_TEST ]] || die 'The packaged configuration checker is missing.'
    local binary
    for binary in "$CONFIG_TEST" "$(rpm --eval '%{_libdir}')/sasl2/libsasl-xoauth2.so"; do
        [[ $(rpm -qf --qf '%{NAME}' "$binary") == sasl-xoauth2-m365-cli ]] || die 'Plugin/helper is not owned by the approved application-auth package.'
    done
    rpm -V --nomtime --noconfig sasl-xoauth2-m365-cli >/dev/null 2>&1 || die 'Application-auth package integrity check failed; repair the approved package.'
    [[ $("$CONFIG_TEST" --application-auth-capability) == smtp-oauth-cli-client-credentials-v1 ]] || die 'The installed helper lacks native application authentication.'
    postconf -A | grep -x cyrus >/dev/null || die 'Postfix was not built with Cyrus SASL client support.'
    PLUGINVIEWER=$(command -v pluginviewer || command -v saslpluginviewer) || die 'Install the Cyrus SASL plugin viewer (pluginviewer on Enterprise Linux).'
    "$PLUGINVIEWER" -c 2>/dev/null | grep -i XOAUTH2 >/dev/null || die 'The Cyrus SASL client cannot discover XOAUTH2. Check the packaged plugin and its default /etc/sasl-xoauth2.conf.'
    [[ $(postconf -h config_directory) == /etc/postfix && $(postconf -h queue_directory) == /var/spool/postfix && $(postconf -h mail_owner) == postfix ]] || die 'This release requires the standard /etc/postfix, /var/spool/postfix and postfix service account.'
    [[ -r $CA ]] || die "Missing CA bundle: $CA"
    postconf -F smtp/unix/chroot >/dev/null || die 'The standard smtp/unix transport is missing from master.cf.'
    [[ -z $(postconf -h multi_instance_directories) ]] || die 'Use a dedicated standard Postfix instance; multiple instances require manual integration.'
    for command in transport_maps sender_dependent_relayhost_maps sender_dependent_default_transport_maps; do
        [[ -z $(postconf -h "$command") ]] || die "Existing $command requires manual integration; use a dedicated relay instance."
    done
    [[ $(postconf -h default_transport) == smtp ]] || die 'Custom default transport requires manual integration.'
    case "$(postconf -h relay_transport)" in relay|smtp) ;; *) die 'Custom relay transport requires manual integration.' ;; esac
    local services inet overrides
    services=$(postconf -M)
    inet=$(printf '%s\n' "$services" | awk '$2=="inet" {print}')
    [[ $(printf '%s\n' "$inet" | wc -l) == 1 ]] &&
      [[ $(printf '%s\n' "$inet" | awk '{print $1,$2,$8,NF}') == 'smtp inet smtpd 8' ]] || die 'master.cf must contain only the standard smtp inet smtpd listener, without overrides.'
    [[ $(postconf -M smtp/unix | awk '{print $1,$2,$8,NF}') == 'smtp unix smtp 8' ]] || die 'Custom outbound smtp service/overrides require manual integration.'
    overrides=$(postconf -P) || die 'Cannot inspect master.cf service overrides.'
    if printf '%s\n' "$overrides" | grep -E '^smtp/(inet|unix)/' >/dev/null; then die 'Remove per-service smtp overrides before installing this dedicated relay.'; fi
    if postconf -m | grep -x hash >/dev/null; then BACKEND='hash'
    elif postconf -m | grep -x lmdb >/dev/null; then BACKEND='lmdb'
    else die 'Postfix requires a hash or lmdb map backend.'; fi
    case "$(systemctl is-enabled postfix 2>/dev/null || :)" in enabled|disabled) ;; *) die 'Postfix must have ordinary enabled or disabled service state; unmask/repair it first.' ;; esac
    SELINUX=0
    if [[ $(getenforce) != Disabled ]]; then
        SELINUX=1
        for command in semodule semanage restorecon; do command -v "$command" >/dev/null || die "SELinux requires $command; install the documented packages first."; done
    fi
}
managed_settings() {
    SETTINGS=(
      [relayhost]="[$relay]:587" [inet_interfaces]=127.0.0.1 [inet_protocols]=ipv4
      [mynetworks]='127.0.0.1/32' [smtpd_relay_restrictions]='permit_mynetworks, reject_unauth_destination'
      [smtp_tls_security_level]=verify [smtp_tls_CAfile]="$CA" [smtp_tls_wrappermode]=no
      [smtp_tls_verify_cert_match]=hostname [smtp_tls_policy_maps]=''
      [smtp_sasl_auth_enable]=yes [smtp_sasl_type]=cyrus [smtp_sasl_password_maps]="$BACKEND:$MAP"
      [smtp_sasl_security_options]=noanonymous [smtp_sasl_tls_security_options]=noanonymous
      [smtp_sasl_mechanism_filter]=xoauth2 [smtp_sender_dependent_authentication]=no
      [sender_dependent_relayhost_maps]='' [sender_dependent_default_transport_maps]='' [transport_maps]=''
      [default_transport]=smtp [relay_transport]=smtp
    )
}
load_state() {
    protected_file "$STATE/manifest.json"
    [[ $(stat -c '%u:%a' "$STATE") == 0:700 ]] || die 'The protected state directory must be owned by root with mode 700.'
    
    jq -e --arg version "$VERSION" '(.version == $version or .version == "2.1.0" or .version == "2.0.0" or .version == "2.0.1") and (.status == "installed" or .status == "installing" or .status == "removing") and
      (.backend == "hash" or .backend == "lmdb") and (.active | type == "boolean") and
      (.enabled == "enabled" or .enabled == "disabled") and (.chroot == "n" or .chroot == "y" or .chroot == "-")' "$STATE/manifest.json" >/dev/null || die 'Unknown or damaged recovery manifest; use its matching script and retain the backup.'
    provider=$(jq -r .provider "$STATE/manifest.json"); mailbox=$(jq -r .mailbox "$STATE/manifest.json")
    tenant=$(jq -r .tenant "$STATE/manifest.json"); relay=$(jq -r .relay "$STATE/manifest.json")
    BACKEND=$(jq -r .backend "$STATE/manifest.json")
    case "$provider:$relay" in
        outlook:smtp-mail.outlook.com|m365:smtp.office365.com) ;;
        google:smtp.gmail.com)
            
            case "$(jq -r .version "$STATE/manifest.json")" in
                2.0.0|2.0.1) ;; *) die 'Gmail recovery requires a legacy 2.0.x manifest.' ;;
            esac ;;
        *) die 'Invalid provider in recovery manifest.' ;;
    esac
    mailbox_ok "$mailbox" || die 'Invalid mailbox in recovery manifest.'
    managed_settings
    if [[ $(jq -r .version "$STATE/manifest.json") != "$VERSION" ]]; then
        SETTINGS[inet_interfaces]=loopback-only; SETTINGS[inet_protocols]=all
        SETTINGS[mynetworks]='127.0.0.0/8 [::1]/128'
    fi
}
require_installed() {
    [[ $(jq -r .version "$STATE/manifest.json") == "$VERSION" ]] || die 'Legacy delegated installation: use status/uninstall to recover it before installing application authentication.'
    [[ $(jq -r .status "$STATE/manifest.json") == installed ]] || die 'Installation is incomplete; use uninstall to restore the protected baseline before retrying.'
    [[ ! -f $STATE/import.preparing ]] || die 'Interrupted import preparation: run recover-import.'
    [[ ! -f $STATE/import.pending ]] || die 'An interrupted credential import needs recovery from previous-config.json and previous-token.json first.'
}
state_status() {
    jq --arg status "$1" '.status=$status' "$STATE/manifest.json" >"$STATE/manifest.tmp"
    chmod 600 "$STATE/manifest.tmp"; mv -f "$STATE/manifest.tmp" "$STATE/manifest.json"
}
map_database() { [[ $BACKEND == hash ]] && printf '%s.db' "$MAP" || printf '%s.lmdb' "$MAP"; }
check_paths_new() {
    local path modules contexts
    for path in "$STATE" "$TOKENDIR" "$MAP" "$MAP.db" "$MAP.lmdb"; do
        exists "$path" && die "Existing managed path: $path. Use the installation's own removal procedure first."
    done
    if exists "$CONFIG"; then
        [[ -f $CONFIG && ! -L $CONFIG && $(stat -c %u "$CONFIG") == 0 && $(realpath -e "$CONFIG") == "$CONFIG" ]] || die 'Existing global SASL config must be a root-owned regular file without symlinks.'
        local mode; mode=$(stat -c %a "$CONFIG")
        (( (8#$mode & 0022) == 0 )) || die 'Existing global SASL config must not be writable by group/others.'
    fi
    if (( SELINUX )); then
        modules=$(semodule -l) || die 'Cannot inspect the existing SELinux modules.'
        contexts=$(semanage fcontext -l -C) || die 'Cannot inspect the existing local SELinux contexts.'
        printf '%s\n' "$modules" | awk '{print $1}' | grep -x "$MODULE" >/dev/null && die 'An unmanaged smtp_oauth_cli SELinux module already exists.'
        printf '%s\n' "$contexts" | grep -F "$TOKENDIR" >/dev/null && die 'An existing local SELinux rule owns the token path.'
        printf '%s\n' "$contexts" | grep -F '/etc/sasl-xoauth2' >/dev/null && die 'An existing local SELinux rule owns sasl-xoauth2.conf.'
    fi
    return 0
}
snapshot() {
    local key active=false chroot enabled
    mkdir -m 700 "$STATE"; TX=prepare
    mkdir -m 700 "$STATE/original"
    postconf -n >"$STATE/original/postconf.txt"
    for key in "${!SETTINGS[@]}"; do
        postconf -h "$key" >"$STATE/original/$key.value"
        if grep -q "^$key =" "$STATE/original/postconf.txt"; then : >"$STATE/original/$key.explicit"; fi
    done
    if exists "$CONFIG"; then
        cp -p "$CONFIG" "$STATE/original/oauth.conf"; chmod 600 "$STATE/original/oauth.conf"
        stat -c '%a %u %g' "$CONFIG" >"$STATE/original/oauth.meta"
    fi
    systemctl is-active --quiet postfix && active=true
    enabled=$(systemctl is-enabled postfix 2>/dev/null || :)
    chroot=$(postconf -F smtp/unix/chroot); chroot=${chroot##*=}; chroot=${chroot//[[:space:]]/}
    jq -n --arg version "$VERSION" --arg provider "$provider" --arg mailbox "$mailbox" --arg tenant "$tenant" --arg relay "$relay" \
      --arg backend "$BACKEND" --arg enabled "$enabled" --arg chroot "$chroot" --argjson active "$active" \
      '{version:$version,status:"installing",provider:$provider,mailbox:$mailbox,tenant:$tenant,relay:$relay,
        backend:$backend,active:$active,enabled:$enabled,chroot:$chroot}' >"$STATE/manifest.json"
    chmod -R go-rwx "$STATE"
    TX=install
}
install_policy() {
    (( SELINUX )) || { say 'SELinux disabled: no policy installed. Qualify labels before enabling it.'; return 0; }
    cat >"$STATE/$MODULE.cil" <<'POLICY'
(type smtp_oauth_cli_token_t)
(typeattributeset file_type (smtp_oauth_cli_token_t))
(type smtp_oauth_cli_conf_t)
(typeattributeset file_type (smtp_oauth_cli_conf_t))
(allow postfix_smtp_t smtp_oauth_cli_token_t (dir (getattr search open read write add_name remove_name)))
(allow postfix_smtp_t smtp_oauth_cli_token_t (file (create getattr open read write append setattr rename unlink lock)))
(allow postfix_smtp_t smtp_oauth_cli_conf_t (file (getattr open read)))
(allow postfix_smtp_t http_port_t (tcp_socket (name_connect)))
POLICY
    : >"$STATE/selinux.module"
    semodule -i "$STATE/$MODULE.cil"
    : >"$STATE/selinux.runtime"
    semanage fcontext -a -t smtp_oauth_cli_token_t "$TOKENDIR(/.*)?"
    : >"$STATE/selinux.config"
    semanage fcontext -a -t smtp_oauth_cli_conf_t '/etc/sasl-xoauth2\.conf'
    restorecon -RF "$TOKENDIR" "$CONFIG"
}
label_runtime() {
    [[ -f $STATE/selinux.module ]] || return 0
    restorecon -RF "$TOKENDIR" "$CONFIG"
}
owned_hashes() {
    sha256sum "$CONFIG" "$MAP" "$(map_database)" >"$STATE/managed.sha256.tmp"
    chmod 600 "$STATE/managed.sha256.tmp"; mv -f "$STATE/managed.sha256.tmp" "$STATE/managed.sha256"
}
guard_permissions() {
    local path
    for path in "$CONFIG" "$MAP" "$(map_database)"; do
        [[ $(stat -c '%U:%G:%a' "$path") == root:postfix:640 ]] || die 'Managed configuration/map ownership or permissions changed; restore root:postfix mode 640.'
    done
    [[ $(stat -c '%U:%G:%a' "$TOKENDIR") == postfix:postfix:700 ]] || die 'The runtime directory must be postfix:postfix mode 700.'
    
    case "$(stat -c '%U:%G:%a' "$TOKEN")" in
        postfix:postfix:600) ;;
        postfix:postfix:640|postfix:postfix:644)
            [[ $(jq -r .version "$STATE/manifest.json") != "$VERSION" ]] || die 'Application token cache must have mode 600.' ;;
        *) die 'The token must be owned by postfix:postfix, readable by its owner and not writable/executable by others.' ;;
    esac
}
guard_drift() {
    local key bad=0 path
    for key in "${!SETTINGS[@]}"; do
        if [[ $(postconf -h "$key") != "${SETTINGS[$key]}" ]]; then say "Drift: Postfix $key"; bad=1; fi
    done
    [[ $(postconf -F smtp/unix/chroot) =~ =[[:space:]]*n$ ]] || { say 'Drift: smtp/unix/chroot'; bad=1; }
    for path in "$CONFIG" "$MAP" "$(map_database)" "$TOKEN"; do
        [[ -f $path && ! -L $path ]] || { say "Drift: missing/symlinked $path"; bad=1; }
    done
    [[ -d $TOKENDIR && ! -L $TOKENDIR ]] || { say 'Drift: token directory'; bad=1; }
    sha256sum -c --status "$STATE/managed.sha256" 2>/dev/null || { say 'Drift: managed configuration/map contents'; bad=1; }
    local overrides services
    overrides=$(postconf -P) || die 'Cannot inspect master.cf overrides.'
    if printf '%s\n' "$overrides" | grep -E '^smtp/(inet|unix)/' >/dev/null; then say 'Drift: smtp service overrides'; bad=1; fi
    services=$(postconf -M) || die 'Cannot inspect master.cf.'
    [[ $(printf '%s\n' "$services" | awk '$2=="inet" {print $1,$2,$8,NF}') == 'smtp inet smtpd 8' ]] || { say 'Drift: SMTP listener services'; bad=1; }
    [[ $(postconf -M smtp/unix | awk '{print $1,$2,$8,NF}') == 'smtp unix smtp 8' ]] || { say 'Drift: SMTP transport'; bad=1; }
    (( bad == 0 )) || die 'Managed configuration drift detected. Restore the recorded managed values or review the recovery files before continuing; no force override is provided.'
    guard_permissions
}
verify_listener() {
    local listeners address count=0
    listeners=$(ss -H -ltn 'sport = :25') || die 'Cannot verify the SMTP listeners.'
    while read -r address; do
        case "$address" in '127.0.0.1:25'|'[::1]:25'|'::1:25') ((count+=1)) ;; *) die 'Unexpected SMTP listener. Review master.cf and the local network configuration.' ;; esac
    done < <(printf '%s\n' "$listeners" | awk '{print $4}')
    if [[ ${SETTINGS[inet_protocols]} == ipv4 ]]; then
        (( count == 1 )) && [[ $listeners == *127.0.0.1:25* ]] || die 'Expected only 127.0.0.1:25.'
    else (( count == 2 )) || die 'Expected legacy IPv4 and IPv6 loopback listeners.'; fi
}
activate_files() {
    install -m 640 -o root -g postfix "$WORK/config.json" "$CONFIG.smtp-oauth-new"
    mv -fT "$CONFIG.smtp-oauth-new" "$CONFIG"
    install -m 600 -o postfix -g postfix "$WORK/runtime/token.json" "$TOKENDIR/token.new"
    mv -fT "$TOKENDIR/token.new" "$TOKEN"
}
restore_service() {
    local enabled active
    enabled=$(jq -r .enabled "$STATE/manifest.json") || return 1
    active=$(jq -r .active "$STATE/manifest.json") || return 1
    if [[ $enabled == enabled ]]; then systemctl enable postfix || return 1; else systemctl disable postfix || return 1; fi
    if [[ $active == true ]]; then postfix check && systemctl start postfix || return 1; else systemctl stop postfix || return 1; fi
}
remove_fcontext() {
    local pattern=$1 listing entry rest found=0
    listing=$(semanage fcontext -l -C) || return 1
    while read -r entry rest; do
        [[ $entry != "$pattern" ]] || found=1
    done <<<"$listing"
    if (( found )); then
        semanage fcontext -d "$pattern" || return 1
    fi
}
restore_install() {
    local key mode uid gid chroot modules
    systemctl stop postfix || return 1
    for key in "${!SETTINGS[@]}"; do
        if [[ -f $STATE/original/$key.explicit ]]; then
            postconf -e "$key = $(cat "$STATE/original/$key.value")" || return 1
        else postconf -X "$key" || return 1; fi
    done
    chroot=$(jq -r .chroot "$STATE/manifest.json") || return 1
    postconf -F "smtp/unix/chroot=$chroot" || return 1
    if [[ -f $STATE/original/oauth.meta ]]; then
        read -r mode uid gid <"$STATE/original/oauth.meta" || return 1
        install -m "$mode" -o "$uid" -g "$gid" "$STATE/original/oauth.conf" "$CONFIG" || return 1
    else rm -f -- "$CONFIG" || return 1; fi
    [[ ! -L $TOKENDIR ]] || return 1
    rm -f -- "$MAP" "$MAP.db" "$MAP.lmdb" "$CONFIG.smtp-oauth-new" || return 1
    rm -rf -- "$TOKENDIR" || return 1
    if [[ -f $STATE/selinux.runtime ]]; then remove_fcontext "$TOKENDIR(/.*)?" || return 1; rm "$STATE/selinux.runtime" || return 1; fi
    if [[ -f $STATE/selinux.config ]]; then remove_fcontext '/etc/sasl-xoauth2\.conf' || return 1; rm "$STATE/selinux.config" || return 1; fi
    if [[ -e $CONFIG && -f $STATE/selinux.module ]]; then restorecon -F "$CONFIG" || return 1; fi
    if [[ -f $STATE/selinux.module ]]; then
        if ! semodule -r "$MODULE"; then
            modules=$(semodule -l) || return 1
            if printf '%s\n' "$modules" | awk '{print $1}' | grep -x "$MODULE" >/dev/null; then return 1; fi
        fi
        rm "$STATE/selinux.module" || return 1
    fi
    restore_service || return 1
    rm -rf -- "$STATE"
}
restore_import() {
    systemctl stop postfix || return 1
    install -m 640 -o root -g postfix "$STATE/previous-config.json" "$CONFIG" || return 1
    install -m 600 -o postfix -g postfix "$STATE/previous-token.json" "$TOKEN" || return 1
    cp "$STATE/previous.sha256" "$STATE/managed.sha256" || return 1
    label_runtime || return 1
    # Validate the restored state before allowing any queued mail to leave.
    (guard_drift) || return 1
    postfix check && systemctl start postfix || return 1
    systemctl is-active --quiet postfix || return 1
    (verify_listener) || return 1
    rm -f "$STATE/import.pending" "$STATE/import.preparing"
}
cleanup() {
    local rc=$?
    trap - EXIT; set +e
    if (( rc != 0 )); then
        case "$TX" in
            prepare) rm -rf -- "$STATE" ;;
            install) if restore_install; then say 'Prior Postfix configuration and service state restored.' >&2; else say "Rollback incomplete. Keep $STATE and use uninstall to resume recovery." >&2; fi ;;
            import) if restore_import; then say 'Previous credentials restored; confirm provider authorization still remains valid.' >&2; else say "Credential recovery incomplete. Keep $STATE and recover previous-config.json / previous-token.json before starting Postfix." >&2; fi ;;
            restart) systemctl start postfix && rm -f "$STATE/import.preparing" || say 'Could not restart Postfix after an interrupted credential operation.' >&2 ;;
            force)
                if ! install -m 600 -o postfix -g postfix "$STATE/test-token.previous" "$TOKEN" || ! label_runtime || ! systemctl start postfix; then
                    say 'Could not recover the forced-expiry test; investigate before sending mail.' >&2
                fi ;;
        esac
    fi
    if [[ -n $WORK ]]; then rm -rf -- "$WORK"; fi
    exit "$rc"
}
install_main() {
    prerequisites; validate_config "$INPUT"; managed_settings; check_paths_new
    postqueue -p | grep -q '^Mail queue is empty$' || die 'The existing queue is not empty or cannot be read. Drain it before changing providers.'
    confirm "Install $provider relay for $mailbox, changing the local Postfix settings?"
    prepare_candidate "$INPUT"
    snapshot
    systemctl stop postfix
    postqueue -p | grep -x 'Mail queue is empty' >/dev/null || die 'Mail arrived before cutover. Prior configuration will be restored; pause local application submissions and drain the queue before retrying.'
    install -d -m 700 -o postfix -g postfix "$TOKENDIR"
    activate_files
    printf '[%s]:587 %s:%s\n' "$relay" "$mailbox" "$TOKEN" >"$MAP"
    chmod 640 "$MAP"; chown root:postfix "$MAP"
    postmap "$BACKEND:$MAP"
    chmod 640 "$(map_database)"; chown root:postfix "$(map_database)"
    [[ $(postmap -q "[$relay]:587" "$BACKEND:$MAP") == "$mailbox:$TOKEN" ]] || die 'Postfix could not query the generated credential map.'
    install_policy
    local key
    for key in "${!SETTINGS[@]}"; do postconf -e "$key = ${SETTINGS[$key]}"; done
    postconf -F smtp/unix/chroot=n
    postfix check
    owned_hashes
    systemctl enable postfix; systemctl start postfix
    systemctl is-active --quiet postfix || die 'Postfix did not remain active.'
    verify_listener
    state_status installed; TX=
    say "Installed $VERSION: $mailbox through $relay:587. Run test to prove relay acceptance."
}
import_main() {
    prerequisites; load_state; require_installed; guard_drift
    local old_provider=$provider old_mailbox=$mailbox old_tenant=$tenant
    systemctl is-active --quiet postfix || die 'Start and repair the installed Postfix service before importing credentials.'
    validate_config "$INPUT"
    [[ $provider == "$old_provider" && $mailbox == "$old_mailbox" && $tenant == "$old_tenant" ]] || die 'import-token keeps the same provider, mailbox and tenant. Uninstall before switching providers.'
    confirm "Validate and replace credentials for $mailbox?"
    prepare_candidate "$INPUT"
    : >"$STATE/import.preparing"
    TX=restart
    systemctl stop postfix
    
    cp "$TOKEN" "$STATE/previous-token.json"; chmod 600 "$STATE/previous-token.json"
    cp "$CONFIG" "$STATE/previous-config.json"; chmod 600 "$STATE/previous-config.json"
    cp "$STATE/managed.sha256" "$STATE/previous.sha256"
    : >"$STATE/import.pending"; TX=import
    activate_files; label_runtime; postfix check; owned_hashes
    systemctl start postfix; systemctl is-active --quiet postfix || die 'Postfix did not remain active after importing credentials.'
    verify_listener
    rm -f "$STATE/import.pending" "$STATE/import.preparing"; TX=
    say 'Credentials replaced. The protected state directory retains the previous token for recovery. Run test --force-refresh to verify runtime refresh.'
}
smtp_reply() {
    local expected=$1 line code
    while IFS= read -r -t 10 -u 8 line; do
        line=${line%$'\r'}
        [[ $line =~ ^([0-9]{3})([-\ ]) ]] || return 1
        code=${BASH_REMATCH[1]}
        [[ ${BASH_REMATCH[2]} == ' ' ]] || continue
        [[ " $expected " == *" $code "* ]] || return 1
        SMTP_REPLY=$line
        return 0
    done
    return 1
}
smtp_submit() {
    local from=$1 recipient=$2 ident=$3
    exec 8<>/dev/tcp/127.0.0.1/25 || return 1
    smtp_reply 220 || return 1
    printf 'EHLO localhost\r\n' >&8; smtp_reply 250 || return 1
    printf 'MAIL FROM:<%s>\r\n' "$from" >&8; smtp_reply 250 || return 1
    printf 'RCPT TO:<%s>\r\n' "$recipient" >&8; smtp_reply '250 251' || return 1
    printf 'DATA\r\n' >&8; smtp_reply 354 || return 1
    printf 'From: <%s>\r\nTo: <%s>\r\nDate: %s\r\nMessage-ID: <%s@localhost>\r\nSubject: SMTP OAuth CLI test\r\n\r\nSMTP relay test from the Linux server.\r\n.\r\n' "$from" "$recipient" "$(LC_ALL=C date -R)" "$ident" >&8
    smtp_reply 250 || return 1
    printf '%s\n' "$SMTP_REPLY"
    printf 'QUIT\r\n' >&8
    exec 8>&-
}
test_main() {
    prerequisites; load_state; require_installed; guard_drift
    mailbox_ok "$RECIPIENT" || die '--recipient must be a plain ASCII email address.'
    systemctl is-active --quiet postfix || die 'Postfix is not active.'
    verify_listener
    confirm "Send one actual test message to $RECIPIENT?"
    workdir
    if (( FORCE_REFRESH )); then
        TX=restart
        systemctl stop postfix
        cp "$TOKEN" "$STATE/test-token.previous"; chmod 600 "$STATE/test-token.previous"; TX=force
        jq 'del(.access_token,.expiry)' "$TOKEN" >"$WORK/expired.json"
        install -m 600 -o postfix -g postfix "$WORK/expired.json" "$TOKEN"
        label_runtime; systemctl start postfix; systemctl is-active --quiet postfix || die 'Postfix failed to start for the forced-refresh test.'; TX=
    fi
    local reply qid start deadline log accepted=0 log_identity='' log_offset=0
    if [[ -f $MAILLOG ]]; then log_identity=$(stat -c '%d:%i' "$MAILLOG"); log_offset=$(stat -c %s "$MAILLOG"); fi
    start=$(date +%s)
    
    if ! reply=$(timeout 25 bash -c 'source "$1"; smtp_submit "$2" "$3" "$4"' _ "$SELF" "$mailbox" "$RECIPIENT" "smtp-oauth-cli-$start-$$" 2>"$WORK/smtp.log"); then
        die 'Local SMTP submission failed. Inspect Postfix service/listener logs; no relay acceptance was confirmed.'
    fi
    [[ $reply =~ queued\ as\ ([A-Za-z0-9]+) ]] || die 'Local SMTP did not return a recognizable queue ID; inspect the queue before retrying.'
    qid=${BASH_REMATCH[1]}; say "Local Postfix accepted queue ID $qid. Checking upstream evidence for up to 45 seconds..."
    deadline=$((SECONDS + 45))
    while (( SECONDS < deadline )); do
        log=$(timeout 5 journalctl --since "@$start" -t postfix/smtp --no-pager -o cat 2>/dev/null || :)
        if [[ -n $log_identity && -r $MAILLOG && $(stat -c '%d:%i' "$MAILLOG") == "$log_identity" && $(stat -c %s "$MAILLOG") -ge $log_offset ]]; then
            log+=$'\n'$(tail -c "+$((log_offset + 1))" "$MAILLOG" | tail -c 262144)
        fi
        if printf '%s\n' "$log" | grep -E "(^|[[:space:]])$qid:" | grep -F "relay=${relay}[" | grep 'status=sent' >/dev/null; then accepted=1; break; fi
        if printf '%s\n' "$log" | grep -E "(^|[[:space:]])$qid:" | grep -E 'status=(bounced|deferred)' >/dev/null; then break; fi
        sleep 2
    done
    if (( FORCE_REFRESH )); then
        jq -e --argjson now "$(date +%s)" '(.expiry | tonumber) > $now and (.access_token | type == "string" and length > 0)' "$TOKEN" >/dev/null 2>&1 || die "Postfix did not leave a usable refreshed token. Keep queue ID $qid for investigation; never edit issued credentials."
        say 'Postfix token-file update after forced-expiry test: observed'
        rm -f "$STATE/test-token.previous"
    fi
    (( accepted )) || die "Upstream acceptance was not confirmed for $qid. Inspect its mail logs and postqueue -p; the queue is preserved."
    say "RELAY ACCEPTED: $relay accepted queue ID $qid. Confirm inbox/junk delivery with the recipient."
}
status_main() {
    load_state
    say "Deployment $VERSION | $(jq -r .status "$STATE/manifest.json") | $provider | $mailbox | $relay:587"
    say "Postfix: $(systemctl is-active postfix 2>/dev/null || :) | enabled: $(systemctl is-enabled postfix 2>/dev/null || :)"
    local expiry
    expiry=$(jq -er '(.expiry // 0) | tonumber | floor' "$TOKEN" 2>/dev/null) || die 'Token expiry is unavailable; inspect recovery state.'
    if (( expiry == 0 )); then say 'Access-token cache empty; acquisition occurs on next SMTP authentication.'
    else say "Access-token expiry (UTC): $(date -u -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"; fi
    say 'The plugin refreshes on SMTP authentication. An expiry timestamp alone does not prove refresh.'
    [[ ! -f $STATE/import.preparing ]] || die 'Interrupted import: run recover-import.'
    [[ ! -f $STATE/import.pending ]] || die 'Interrupted credential import: retain previous-config.json and previous-token.json for recovery.'
    guard_drift; say 'Managed configuration drift: none.'
    systemctl is-active --quiet postfix || die 'Postfix is inactive.'
    verify_listener
}
uninstall_main() {
    load_state
    [[ ! -f $STATE/import.pending && ! -f $STATE/import.preparing ]] || die 'Run recover-import before uninstall.'
    if [[ $(jq -r .status "$STATE/manifest.json") == installed ]]; then guard_drift; fi
    confirm 'Restore prior Postfix settings/service and remove this installation, including protected backups?'
    local was_active=0
    systemctl is-active --quiet postfix && was_active=1
    systemctl stop postfix
    if ! postqueue -p | grep -x 'Mail queue is empty' >/dev/null; then
        if (( was_active )); then systemctl start postfix; fi
        die 'Queue is not empty or cannot be read. Drain it with the current relay before uninstall; no settings were restored.'
    fi
    state_status removing
    restore_install || die "Restore incomplete. Keep $STATE and rerun uninstall after correcting the reported problem."
    say 'Removed. Prior settings/service restored. Queue, packages and provider-side consent were preserved.'
}
recover_main() {
    load_state
    if [[ ! -f $STATE/import.pending && -f $STATE/import.preparing ]]; then
        guard_drift
        postfix check; systemctl start postfix; verify_listener
        rm "$STATE/import.preparing"
        say 'Interrupted preparation recovered; active credentials were unchanged.'
        return
    fi
    [[ -f $STATE/import.pending ]] || die 'No interrupted import is recorded.'
    protected_file "$STATE/previous-config.json"
    protected_file "$STATE/previous-token.json"
    protected_file "$STATE/previous.sha256"
    confirm 'Restore credentials saved before the interrupted import and start Postfix?'
    restore_import || die 'Credential recovery incomplete; retain the state directory.'
    guard_drift; verify_listener
    say 'Previous credentials restored. Run status and test.'
}
usage() {
    cat <<'HELP'
SMTP OAuth CLI 3.0.0 — Microsoft 365 application authentication.
  check [--config JSON]
  install --config JSON [--yes]
  status
  test --recipient EMAIL [--force-refresh] [--yes]
  import-token --config JSON [--yes]
  recover-import [--yes]
  uninstall [--yes]
Run as root using Bash 4.4+. Fill the protected client template; see README.md.
No mailbox sign-in, browser, device code or refresh token is used.
HELP
}
main() {
    set -Eeuo pipefail
    umask 077
    export LC_ALL=C
    local cmd=${1:-help} flag
    [[ $cmd != --version ]] || { say "$VERSION"; return; }
    case "$cmd" in help|--help|-h) usage; return ;; esac
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die 'Bash 4.4 or newer is required.'
    (( EUID == 0 )) || die 'Run as root.'
    shift
    INPUT='' RECIPIENT='' FORCE_REFRESH=0
    while (( $# )); do
        flag=$1; shift
        case "$cmd:$flag" in
            check:--config|install:--config|import-token:--config|test:--recipient)
                (( $# )) && [[ $1 != --* ]] || die "Missing value for $flag."
                case "$flag" in --config) INPUT=$1 ;; --recipient) RECIPIENT=$1 ;; esac
                shift ;;
            install:--yes|import-token:--yes|test:--yes|uninstall:--yes|recover-import:--yes) YES=1 ;;
            test:--force-refresh) FORCE_REFRESH=1 ;;
            *) die "Unsupported option: $flag (use --help)." ;;
        esac
    done
    case "$cmd" in check|install|status|test|import-token|uninstall|recover-import) ;; *) die 'Unknown command; use --help.' ;; esac
    exists "$LEGACY_STATE" && die 'An older smtp-oauth-deploy installation/recovery path exists. Use its original script to uninstall it first; this release will not overwrite it.'
    [[ ! -L $LOCK ]] || die 'Lock path is a symlink.'
    if exists "$LOCK"; then
        [[ -f $LOCK && $(stat -c %u "$LOCK") == 0 ]] || die 'The existing lock must be a root-owned regular file.'
    fi
    exec 9>"$LOCK"; flock -n 9 || die 'Another SMTP OAuth operation is running.'
    SELF=$(realpath -e -- "${BASH_SOURCE[0]}")
    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    if [[ $cmd == install ]]; then
        [[ -n $INPUT ]] || die '--config is required.'
        bootstrap_install_packages
    fi
    command -v jq >/dev/null || die 'Install jq before using this script.'
    case "$cmd" in
        recover-import) recover_main ;;
        check) prerequisites; if [[ -n $INPUT ]]; then validate_config "$INPUT"; say "Credential structure passed for $provider / $mailbox."; fi
               say 'Local prerequisites passed. install validates the application token request; test verifies relay acceptance.' ;;
        install) [[ -n $INPUT ]] || die '--config is required.'; install_main ;;
        import-token) [[ -n $INPUT ]] || die '--config is required.'; import_main ;;
        status) status_main ;;
        test) [[ -n $RECIPIENT ]] || die '--recipient is required.'; test_main ;;
        uninstall) uninstall_main ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
