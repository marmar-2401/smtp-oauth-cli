#!/usr/bin/env bash
set +x

VERSION=2.1.0
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
    local placeholders
    protected_file "$1"
    jq empty "$1" >/dev/null 2>&1 || die 'Cannot parse credential JSON. Save the file as UTF-8, use straight double quotes and remove trailing commas. Do not save as UTF-16.'
    jq -e '
      type == "object" and
      ((keys - ["provider","mailbox","client_id","client_secret","refresh_token","tenant"]) | length == 0) and
      ([.provider,.mailbox,.client_id,.refresh_token] | all(type == "string" and length > 0)) and
      ((has("client_secret") | not) or (.client_secret | type == "string")) and
      ((has("tenant") | not) or (.tenant | type == "string")) and
      ([.provider,.mailbox,.client_id,(.client_secret // ""),.refresh_token,(.tenant // "")] |
        all(test("[\u0000-\u0020\u007f]") | not)) and
      (.client_id | length <= 4096) and ((.client_secret // "") | length <= 8192) and
      (.refresh_token | length <= 65536) and
      ([.client_id,(.client_secret // ""),.refresh_token] | all(test("[&+%]") | not))
    ' "$1" >/dev/null 2>&1 || die 'Invalid credential JSON: check required strings, allowed fields, whitespace and lengths. This sasl-xoauth2 workflow cannot accept &, + or % in OAuth credentials; never edit issued credentials.'
    placeholders=$(jq -r '[to_entries[] | select(.value | type == "string") |
      select(.value | test("^(REPLACE_WITH_[A-Z0-9_]+|YOUR_[A-Z0-9_]+)$")) | .key] | join(", ")' "$1")
    [[ -z $placeholders ]] || die "Unfilled template fields: $placeholders. Replace every placeholder with the actual approved value before continuing."
    provider=$(jq -r .provider "$1")
    mailbox=$(jq -r .mailbox "$1")
    tenant=$(jq -r '.tenant // ""' "$1")
    mailbox_ok "$mailbox" || die 'Use a plain ASCII mailbox address (letters, numbers, dot, underscore, plus or hyphen).'
    case "$provider" in
        outlook)
            [[ -z $tenant ]] || die 'Use outlook without a tenant for a personal Microsoft account.'
            relay=smtp-mail.outlook.com; endpoint=https://login.microsoftonline.com/consumers/oauth2/v2.0/token ;;
        m365)
            [[ $tenant =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || die 'm365 requires the actual tenant GUID.'
            relay=smtp.office365.com; endpoint=https://login.microsoftonline.com/$tenant/oauth2/v2.0/token ;;
        *) die 'Provider must be outlook or m365.' ;;
    esac
}
workdir() {
    [[ -n $WORK ]] && return 0
    WORK=$(mktemp -d /var/tmp/smtp-oauth-cli.XXXXXXXX)
    chmod 700 "$WORK"
}
helper_refresh() {
    local token=$1 config=$2 http error_class error_codes target
    say 'Validating XOAUTH2 configuration, then the OAuth refresh exchange...'
    if ! timeout 90 runuser -u postfix -- "$CONFIG_TEST" --config "$config" >"$WORK/helper.log" 2>&1; then
        die 'XOAUTH2 configuration validation failed. Check the installed helper and protected configuration; raw helper output is withheld.'
    fi
    
    jq -nj --slurpfile config "$config" --slurpfile token "$token" '
      $config[0] as $c | $token[0] as $t |
      (["grant_type=refresh_token", "client_id="+($c.client_id|@uri), "refresh_token="+($t.refresh_token|@uri)] +
       (if $c.client_secret == "" then [] else ["client_secret="+($c.client_secret|@uri)] end)) | join("&")
    ' >"$WORK/form"
    target=$(jq -r .token_endpoint "$config")
    if ! http=$(curl --disable --silent --show-error --proto '=https' --tlsv1.2 --cacert "$CA" \
      --connect-timeout 10 --max-time 60 --max-filesize 262144 --request POST \
      --header 'Content-Type: application/x-www-form-urlencoded' --data-binary "@$WORK/form" \
      --output "$WORK/response.json" --write-out '%{http_code}' "$target" 2>"$WORK/curl.log"); then
        die 'OAuth HTTPS request failed. Check clock, CA trust, DNS and HTTPS access; raw output is withheld.'
    fi
    if [[ $http != 200 ]]; then
        error_class=$(jq -r '.error // "request_failed"' "$WORK/response.json" 2>/dev/null || :)
        case "$error_class" in invalid_grant|invalid_client|unauthorized_client|invalid_scope|interaction_required|consent_required|temporarily_unavailable|invalid_request|access_denied) ;; *) error_class=request_failed ;; esac
        error_codes=$(jq -r 'if (.error_codes? | type) == "array" then
          [.error_codes[] | select(type == "number") |
           select(. > 0 and . < 10000000000 and . == floor) | "AADSTS" + tostring] |
          unique | .[:5] | join(", ") else "" end' "$WORK/response.json" 2>/dev/null || :)
        [[ -z $error_codes ]] || error_class+="; $error_codes"
        die "OAuth refresh failed (HTTP $http; $error_class). Check client credentials, grant consent and provider policy."
    fi
    jq -e '
      type == "object" and (.access_token | type == "string" and length > 0 and length <= 65536 and
        (test("[\u0000-\u0020\u007f]") | not)) and
      ((.token_type | ascii_downcase) == "bearer") and
      ((.expires_in | tonumber) as $expiry | $expiry > 0 and $expiry == ($expiry | floor)) and
      ((has("refresh_token") | not) or (.refresh_token | type == "string" and length > 0 and length <= 65536 and
        (test("[\u0000-\u0020\u007f]") | not)))
    ' "$WORK/response.json" >/dev/null 2>&1 || die 'The provider did not return a complete usable token response; no candidate was activated.'
    jq -n --slurpfile old "$token" --slurpfile response "$WORK/response.json" --argjson now "$(date +%s)" '
      $response[0] as $r | {access_token:$r.access_token,refresh_token:($r.refresh_token // $old[0].refresh_token),
      expiry:(($now + ($r.expires_in | tonumber)) | floor | tostring)}
    ' >"$WORK/refreshed.json" 2>/dev/null || die 'Unable to create the protected candidate token.'
    jq -e --argjson now "$(date +%s)" '
      (.expiry | tonumber) as $expiry | ($expiry == ($expiry | floor) and $expiry > $now) and
      (.refresh_token | test("[&+%]") | not)
    ' "$WORK/refreshed.json" >/dev/null 2>&1 || die 'The refreshed token has invalid expiry or an unsupported rotated refresh token. Never edit the issued token.'
    install -m 600 -o postfix -g postfix "$WORK/refreshed.json" "$token"
    say 'Refresh exchange passed. SMTP delivery is verified separately with test.'
}
prepare_candidate() {
    workdir
    chgrp postfix "$WORK"; chmod 710 "$WORK"
    mkdir "$WORK/runtime"; chown postfix:postfix "$WORK/runtime"; chmod 700 "$WORK/runtime"
    jq --arg endpoint "$endpoint" --arg ca "$CA" '{client_id,client_secret:(.client_secret // ""),token_endpoint:$endpoint,
      ca_bundle_file:$ca,always_log_to_syslog:"no",log_to_syslog_on_failure:"no",log_full_trace_on_failure:"no"}' "$1" >"$WORK/config.json"
    chmod 640 "$WORK/config.json"; chown root:postfix "$WORK/config.json"
    jq '{refresh_token}' "$1" >"$WORK/runtime/token.json"
    chmod 600 "$WORK/runtime/token.json"; chown postfix:postfix "$WORK/runtime/token.json"
    helper_refresh "$WORK/runtime/token.json" "$WORK/config.json"
    jq --slurpfile token "$WORK/runtime/token.json" '.refresh_token=$token[0].refresh_token' "$1" >"$WORK/recovery.json"
    chmod 600 "$WORK/recovery.json"
}
prerequisites() {
    local command version rhel
    for command in jq realpath stat flock timeout runuser curl rpm postconf postmap postfix postqueue systemctl sha256sum getenforce ss; do
        command -v "$command" >/dev/null || die "Missing prerequisite: $command. Install the documented OS packages first."
    done
    rhel=$(rpm -E '%{rhel}')
    [[ $rhel == 8 || $rhel == 9 || $rhel == 10 ]] || die 'This release targets Enterprise Linux 8, 9 and 10 only; qualify the actual host with the supplied lab.'
    version=$(rpm -q --qf '%{VERSION}' sasl-xoauth2 2>/dev/null) || die 'Install the sasl-xoauth2 RPM from an approved repository.'
    [[ $(printf '%s\n' 0.24 "$version" | sort -V | head -n 1) == 0.24 ]] || die 'sasl-xoauth2 0.24 or newer is required; qualify its helper behavior before use.'
    CONFIG_TEST=$(rpm --eval '%{_libdir}')/sasl-xoauth2/test-config
    [[ -x $CONFIG_TEST ]] || die 'The sasl-xoauth2 RPM compiled configuration checker is missing; repair the package before deployment.'
    postconf -A | grep -x cyrus >/dev/null || die 'Postfix was not built with Cyrus SASL client support.'
    PLUGINVIEWER=$(command -v pluginviewer || command -v saslpluginviewer) || die 'Install the Cyrus SASL plugin viewer (pluginviewer on Enterprise Linux).'
    "$PLUGINVIEWER" -c 2>/dev/null | grep -i XOAUTH2 >/dev/null || die 'The Cyrus SASL client cannot discover XOAUTH2. Check the packaged plugin and its default /etc/sasl-xoauth2.conf.'
    [[ $(postconf -h config_directory) == /etc/postfix && $(postconf -h queue_directory) == /var/spool/postfix && $(postconf -h mail_owner) == postfix ]] || die 'This release requires the standard /etc/postfix, /var/spool/postfix and postfix service account.'
    [[ -r $CA ]] || die "Missing CA bundle: $CA"
    if [[ ! -r /proc/net/if_inet6 ]] || ! grep -q ' lo$' /proc/net/if_inet6; then
        die 'Enable IPv6 loopback as well as IPv4 before installing this localhost-only listener.'
    fi
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
      [relayhost]="[$relay]:587" [inet_interfaces]=loopback-only [inet_protocols]=all
      [mynetworks]='127.0.0.0/8 [::1]/128' [smtpd_relay_restrictions]='permit_mynetworks, reject_unauth_destination'
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
    
    jq -e --arg version "$VERSION" '(.version == $version or .version == "2.0.0" or .version == "2.0.1") and (.status == "installed" or .status == "installing" or .status == "removing") and
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
}
require_installed() {
    [[ $provider != google ]] || die 'Gmail support has been removed. Use status or uninstall for this legacy installation, then install Outlook or Microsoft 365.'
    [[ $(jq -r .status "$STATE/manifest.json") == installed ]] || die 'Installation is incomplete; use uninstall to restore the protected baseline before retrying.'
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
        postfix:postfix:600|postfix:postfix:640|postfix:postfix:644) ;;
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
    (( bad == 0 )) || die 'Managed configuration drift detected. Restore the recorded managed values or review the recovery files before continuing; no force override is provided.'
    guard_permissions
}
verify_listener() {
    local listeners address count=0
    listeners=$(ss -H -ltn 'sport = :25') || die 'Cannot verify the SMTP listeners.'
    while read -r address; do
        case "$address" in '127.0.0.1:25'|'[::1]:25'|'::1:25') ((count+=1)) ;; *) die 'Unexpected SMTP listener. Review master.cf and the local network configuration.' ;; esac
    done < <(printf '%s\n' "$listeners" | awk '{print $4}')
    (( count == 2 )) || die 'Expected both loopback IPv4 and IPv6 SMTP listeners.'
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
    postfix check && systemctl start postfix || return 1
    rm -f "$STATE/import.pending"
}
cleanup() {
    local rc=$?
    trap - EXIT; set +e
    if (( rc != 0 )); then
        case "$TX" in
            prepare) rm -rf -- "$STATE" ;;
            install) if restore_install; then say 'Prior Postfix configuration and service state restored.' >&2; else say "Rollback incomplete. Keep $STATE and use uninstall to resume recovery." >&2; fi ;;
            import) if restore_import; then say 'Previous credentials restored; confirm provider authorization still remains valid.' >&2; else say "Credential recovery incomplete. Keep $STATE and recover previous-config.json / previous-token.json before starting Postfix." >&2; fi ;;
            restart) systemctl start postfix || say 'Could not restart Postfix after an interrupted credential operation.' >&2 ;;
            force)
                if ! install -m 600 -o postfix -g postfix "$STATE/test-token.previous" "$TOKEN" || ! label_runtime || ! systemctl start postfix; then
                    say 'Could not recover the forced-expiry test; investigate before sending mail.' >&2
                fi ;;
        esac
    fi
    if [[ -n $WORK ]]; then
        if (( rc != 0 )) && [[ -s $WORK/recovery.json ]]; then
            chown root:root "$WORK"; chmod 700 "$WORK"
            say "The provider may have rotated the grant. Latest validated credentials retained at $WORK/recovery.json (root-only); secure or remove this recovery file after resolution." >&2
        else rm -rf -- "$WORK"; fi
    fi
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
    TX=restart
    systemctl stop postfix
    
    cp "$TOKEN" "$STATE/previous-token.json"; chmod 600 "$STATE/previous-token.json"
    cp "$CONFIG" "$STATE/previous-config.json"; chmod 600 "$STATE/previous-config.json"
    cp "$STATE/managed.sha256" "$STATE/previous.sha256"
    : >"$STATE/import.pending"; TX=import
    activate_files; label_runtime; postfix check; owned_hashes
    systemctl start postfix; systemctl is-active --quiet postfix || die 'Postfix did not remain active after importing credentials.'
    verify_listener
    rm "$STATE/import.pending"; TX=
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
        jq '.expiry="0"' "$TOKEN" >"$WORK/expired.json"
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
        jq -e --argjson now "$(date +%s)" '(.expiry | tonumber) > $now and (.access_token | type == "string" and length > 0) and
          (.refresh_token | type == "string" and length > 0 and (test("[&+%\u0000-\u0020\u007f]") | not))' "$TOKEN" >/dev/null 2>&1 || die "Postfix did not leave a usable refreshed token. Keep queue ID $qid for investigation; never edit issued credentials."
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
    expiry=$(jq -er '.expiry | tonumber | floor' "$TOKEN" 2>/dev/null) || die 'Token expiry is unavailable; inspect recovery state.'
    say "Access-token expiry (UTC): $(date -u -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"
    say 'The plugin refreshes on SMTP authentication. An expiry timestamp alone does not prove refresh.'
    [[ ! -f $STATE/import.pending ]] || die 'Interrupted credential import: retain previous-config.json and previous-token.json for recovery.'
    guard_drift; say 'Managed configuration drift: none. Listener configuration: loopback IPv4 and IPv6.'
    if systemctl is-active --quiet postfix; then verify_listener; fi
}
uninstall_main() {
    load_state
    if [[ $(jq -r .status "$STATE/manifest.json") == installed ]]; then guard_drift; fi
    confirm 'Restore prior Postfix settings/service and remove this installation, including protected backups?'
    state_status removing
    restore_install || die "Restore incomplete. Keep $STATE and rerun uninstall after correcting the reported problem."
    say 'Removed. Prior settings/service restored. Queue, packages and provider-side consent were preserved.'
}
init_main() {
    local parent mode secret client rt
    [[ $PROVIDER == outlook || $PROVIDER == m365 ]] || die 'Provider must be outlook or m365.'
    [[ -t 0 ]] || die 'init requires a terminal for hidden secret entry; alternatively create the documented protected JSON file.'
    [[ -n $PROVIDER && -n $MAILBOX && -n $OUTPUT ]] || die 'init requires --provider, --mailbox and --output.'
    exists "$OUTPUT" && die '--output must name a new file.'
    parent=$(dirname -- "$(realpath -ms -- "$OUTPUT")")
    [[ -d $parent && $(realpath -e -- "$parent") == "$parent" && $(stat -c %u "$parent") == 0 ]] || die 'Choose an existing root-owned output directory without symlinks.'
    mode=$(stat -c %a "$parent"); (( (8#$mode & 0022) == 0 )) || die 'The output directory must not be writable by group/others.'
    read -r -p 'Client ID: ' client
    read -r -s -p 'Client secret (Enter for a Microsoft public client): ' secret; printf '\n'
    read -r -s -p 'Refresh token: ' rt; printf '\n'
    workdir
    printf '%s' "$client" >"$WORK/client"; printf '%s' "$secret" >"$WORK/secret"; printf '%s' "$rt" >"$WORK/refresh"
    unset secret rt client
    jq -n --arg provider "$PROVIDER" --arg mailbox "$MAILBOX" --arg tenant "$TENANT" \
      --rawfile client_id "$WORK/client" --rawfile client_secret "$WORK/secret" --rawfile refresh_token "$WORK/refresh" \
      '{provider:$provider,mailbox:$mailbox,client_id:$client_id,client_secret:$client_secret,refresh_token:$refresh_token} +
        (if $tenant == "" then {} else {tenant:$tenant} end)' >"$WORK/input.json"
    validate_config "$WORK/input.json"
    (set -o noclobber; cat "$WORK/input.json" >"$OUTPUT") || die 'Could not create new output file.'
    chmod 600 "$OUTPUT"; say "Protected configuration created: $OUTPUT"
}
authorize_main() (
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION=2.1.0
WORK=''
PROVIDER=''
CLIENT_ID=''
MAILBOX=''
TENANT=''
OUTPUT=''
HTTP=''
EMAIL_RX='^[A-Za-z0-9._+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
GUID_RX='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z $WORK ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'HELP'
Microsoft public-client authorization 2.1.0 (Bash, curl and jq).

  bash smtp-oauth-deploy.sh authorize --provider outlook --output /root/smtp-oauth-microsoft/client.json
  bash smtp-oauth-deploy.sh authorize --provider m365 --output /root/smtp-oauth-microsoft/client.json

Prompts for the application client ID, sending mailbox and (m365) tenant GUID.
Optional flags: --client-id GUID --mailbox EMAIL --tenant GUID
The output must be a NEW file in an existing root-owned private directory.

Register a public-client app first using README.txt.
Run authorize in the Linux terminal. Open the displayed Microsoft URL
on your own PC and sign in as the sending mailbox. The Linux host needs no GUI.
This one-time sign-in creates a delegated refresh grant; it does not bypass MFA.
No client secret is used in this lab flow. No Postfix configuration is changed.
Existing client-supplied JSON files do not need authorize.
HELP
}

prompt_value() {
    local name=$1 label=$2
    [[ -n ${!name} ]] && return 0
    [[ -t 0 ]] || die "Supply $label with its command option, or run in a terminal."
    read -r -p "$label: " "$name" || die 'Input cancelled.'
}

post_form() {
    local endpoint=$1 form=$2 response=$3
    if ! HTTP=$(curl --disable --silent --show-error --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 --max-filesize 262144 \
        --request POST --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary "@$form" --output "$response" --write-out '%{http_code}' \
        "$endpoint" 2>"$WORK/curl-error.txt"); then
        die 'Microsoft HTTPS request failed. Check DNS, time, CA trust and outbound TCP 443. No credentials were printed.'
    fi
    jq -e 'type == "object"' "$response" >/dev/null 2>&1 || \
        die "Microsoft returned a non-JSON response (HTTP $HTTP). Check the proxy or service availability."
}

provider_error() {
    local response=$1 error codes
    error=$(jq -r '.error // "request_failed"' "$response")
    case "$error" in
        invalid_client|unauthorized_client|invalid_scope|invalid_request|invalid_grant|access_denied|authorization_declined|expired_token|bad_verification_code|interaction_required|consent_required|temporarily_unavailable) ;;
        *) error=request_failed ;;
    esac
    codes=$(jq -r 'if (.error_codes | type) == "array" then
        [.error_codes[] | select(type == "number" and . > 0 and . < 1000000000 and . == floor) |
         "AADSTS" + tostring] | unique | .[:5] | join(", ") else "" end' "$response")
    say "Microsoft authorization failed (HTTP $HTTP; $error${codes:+; $codes})." >&2
    case "$error" in
        authorization_declined|access_denied) say 'Consent was declined or policy blocked sign-in. Ask the tenant administrator to inspect the sign-in result.' >&2 ;;
        expired_token|bad_verification_code) say 'Run authorize again for a fresh device code; complete the browser steps while the terminal remains open.' >&2 ;;
        invalid_client|unauthorized_client) say 'Check the application client ID, supported account type, tenant and Allow public client flows = Yes. Authorize uses no client secret.' >&2 ;;
        invalid_scope|consent_required) say 'Check delegated SMTP.Send and consent for the registered application; Graph Mail.Send is a different permission.' >&2 ;;
        *) say 'Use the displayed error code and README.txt. Raw responses are withheld because they can contain credentials.' >&2 ;;
    esac
    exit 1
}

while (( $# )); do
    flag=$1; shift
    case "$flag" in
        --help|-h) usage; exit 0 ;;
        --version) say "$VERSION"; exit 0 ;;
        --provider|--output|--client-id|--mailbox|--tenant)
            (( $# )) && [[ $1 != --* ]] || die "Missing value for $flag."
            case "$flag" in
                --provider) PROVIDER=$1 ;; --output) OUTPUT=$1 ;; --client-id) CLIENT_ID=$1 ;;
                --mailbox) MAILBOX=$1 ;; --tenant) TENANT=$1 ;;
            esac
            shift ;;
        *) die "Unknown option: $flag. Use --help." ;;
    esac
done

(( EUID == 0 )) || die 'Run as root on the Linux host.'
for prerequisite in curl jq realpath stat mktemp ln date sleep; do
    command -v "$prerequisite" >/dev/null || die "Missing $prerequisite. Complete README.txt first."
done
[[ $PROVIDER == outlook || $PROVIDER == m365 ]] || die '--provider must be outlook or m365.'
[[ $OUTPUT == /* ]] || die '--output must be an absolute path to a new JSON file.'
[[ ! -e $OUTPUT && ! -L $OUTPUT ]] || die 'Output already exists. Keep it and use a new name, such as replacement.json.'
parent=$(dirname -- "$OUTPUT")
[[ -d $parent && $(realpath -ms -- "$parent") == "$(realpath -e -- "$parent")" ]] || \
    die 'Use an existing output directory without symlinks.'
mode=$(stat -c %a -- "$parent")
[[ $(stat -c %u -- "$parent") == 0 ]] && (( (8#$mode & 0077) == 0 )) || \
    die 'Output directory must be root-owned with mode 700. Use /root/smtp-oauth-microsoft after README.txt preparation.'

prompt_value CLIENT_ID 'Application (client) ID'
prompt_value MAILBOX 'Exact sending mailbox address'
[[ $CLIENT_ID =~ $GUID_RX ]] || die 'Client ID must be the application GUID from App registrations > Overview.'
[[ ${#MAILBOX} -le 254 && $MAILBOX =~ $EMAIL_RX && $MAILBOX != *..* ]] || die 'Enter a plain email address without spaces.'
if [[ $PROVIDER == m365 ]]; then
    prompt_value TENANT 'Directory (tenant) ID'
    [[ $TENANT =~ $GUID_RX ]] || die 'Use the tenant GUID, not the client ID, subscription ID or domain.'
    authority=$TENANT
else
    [[ -z $TENANT ]] || die 'Personal Outlook uses consumers; omit --tenant.'
    authority=consumers
fi

WORK=$(mktemp -d "$parent/.smtp-oauth-authorize.XXXXXXXX")
endpoint="https://login.microsoftonline.com/$authority/oauth2/v2.0"
jq -nj --arg client "$CLIENT_ID" --arg scope 'offline_access https://outlook.office.com/SMTP.Send' \
    '"client_id=" + ($client|@uri) + "&scope=" + ($scope|@uri)' >"$WORK/device.form"
started=$(date +%s)
post_form "$endpoint/devicecode" "$WORK/device.form" "$WORK/device.json"
[[ $HTTP == 200 ]] || provider_error "$WORK/device.json"
jq -e '
    (.device_code | type == "string" and length > 0 and length <= 65536) and
    (.user_code | type == "string" and test("^[A-Za-z0-9-]{4,40}$")) and
    (.verification_uri | type == "string" and test("^https://(www\\.)?microsoft\\.com/(devicelogin|link)/?$")) and
    (.expires_in | type == "number" and . > 0 and . <= 86400 and . == floor) and
    ((.interval // 5) | type == "number" and . > 0 and . <= 60 and . == floor)
' "$WORK/device.json" >/dev/null 2>&1 || die 'Microsoft returned an unexpected device-code response. No grant was saved.'

interval=$(jq -r '.interval // 5' "$WORK/device.json")
deadline=$((started + $(jq -r '.expires_in' "$WORK/device.json")))
say ''
say 'Leave this terminal open. On your own PC, open:'
jq -r .verification_uri "$WORK/device.json"
say "Enter this one-time code: $(jq -r .user_code "$WORK/device.json")"
say "Sign in as: $MAILBOX"
say 'Complete consent and MFA. Use another account if the browser selects the wrong mailbox.'
say "Waiting for Microsoft authorization (up to $(jq -r .expires_in "$WORK/device.json") seconds)."
say 'Do not send this device code to anyone else.'

jq -nj --arg client "$CLIENT_ID" --slurpfile device "$WORK/device.json" \
    '"grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id=" + ($client|@uri) +
     "&device_code=" + ($device[0].device_code|@uri)' >"$WORK/token.form"
authorized=0
while (( $(date +%s) < deadline )); do
    remaining=$interval
    while (( remaining > 0 )); do
        pause=$remaining; (( pause <= 30 )) || pause=30
        sleep "$pause"
        remaining=$((remaining - pause))
    done
    (( $(date +%s) < deadline )) || break
    post_form "$endpoint/token" "$WORK/token.form" "$WORK/token.json"
    if [[ $HTTP == 200 ]]; then authorized=1; break; fi
    case "$(jq -r '.error // ""' "$WORK/token.json")" in
        authorization_pending) ;;
        slow_down) interval=$((interval + 5)) ;;
        *) provider_error "$WORK/token.json" ;;
    esac
done
(( authorized )) || die 'Device code expired. Run authorize again and finish sign-in before the new code expires.'
jq -e '
    (.token_type | type == "string" and ascii_downcase == "bearer") and
    (.access_token | type == "string" and length > 0) and
    (.refresh_token | type == "string" and length > 0 and length <= 65536 and
     (test("[\u0000-\u0020\u007f]") | not)) and
    ((has("scope") | not) or (.scope | type == "string" and (split(" ") | any(. == "SMTP.Send" or
      . == "https://outlook.office.com/SMTP.Send" or . == "https://outlook.office365.com/SMTP.Send"))))
' "$WORK/token.json" >/dev/null 2>&1 || die 'Authorization did not return a usable SMTP refresh grant. Check SMTP.Send and offline_access; no output file was created.'

jq --arg provider "$PROVIDER" --arg mailbox "$MAILBOX" --arg client "$CLIENT_ID" --arg tenant "$TENANT" \
    '{provider:$provider,mailbox:$mailbox,client_id:$client,client_secret:"",refresh_token:.refresh_token} +
     (if $provider == "m365" then {tenant:$tenant} else {} end)' "$WORK/token.json" >"$WORK/client.json"
chmod 600 "$WORK/client.json"

ln -T -- "$WORK/client.json" "$OUTPUT" || die 'Could not publish the new output file. Existing files were preserved.'
say "Created protected configuration: $OUTPUT"
if ! jq -e '.refresh_token | test("[&+%]") | not' "$OUTPUT" >/dev/null; then
    say 'The grant is saved, but its characters are incompatible with the reviewed sasl-xoauth2 build.'
    say 'Stop before installing. See README.txt; never edit an issued token.'
    exit 1
fi
say 'Next: run bash smtp-oauth-deploy.sh check --config with this file, then follow README.txt.'
say 'Authorization is complete. Run the SMTP tests in README.txt to verify delivery and automatic refresh.'

)
usage() {
    cat <<'HELP'
SMTP OAuth CLI 2.1.0 — Outlook / Microsoft 365; one delegated mailbox.
  authorize --provider outlook|m365 --output NEW_JSON
  init --provider outlook|m365 --mailbox EMAIL [--tenant GUID] --output NEW_JSON
  check [--config JSON]
  install --config JSON [--yes]
  status
  test --recipient EMAIL [--force-refresh] [--yes]
  import-token --config JSON [--yes]
  uninstall [--yes]
Run as root using Bash 4.4+. Secrets are read from a root-owned private JSON file.
Already have a client-supplied JSON? Go straight to check and install.
For initial authorization, authorize displays a code to approve on your own PC.
The Linux host needs no browser. See README.txt for the complete setup.
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
    if [[ $cmd == authorize ]]; then
        shift
        authorize_main "$@"
        return
    fi
    (( EUID == 0 )) || die 'Run as root.'
    shift
    INPUT='' PROVIDER='' MAILBOX='' TENANT='' OUTPUT='' RECIPIENT='' FORCE_REFRESH=0
    while (( $# )); do
        flag=$1; shift
        case "$cmd:$flag" in
            init:--provider|init:--mailbox|init:--tenant|init:--output|check:--config|install:--config|import-token:--config|test:--recipient)
                (( $# )) && [[ $1 != --* ]] || die "Missing value for $flag."
                case "$flag" in --provider) PROVIDER=$1 ;; --mailbox) MAILBOX=$1 ;; --tenant) TENANT=$1 ;; --output) OUTPUT=$1 ;; --config) INPUT=$1 ;; --recipient) RECIPIENT=$1 ;; esac
                shift ;;
            install:--yes|import-token:--yes|test:--yes|uninstall:--yes) YES=1 ;;
            test:--force-refresh) FORCE_REFRESH=1 ;;
            *) die "Unsupported option: $flag (use --help)." ;;
        esac
    done
    case "$cmd" in init|check|install|status|test|import-token|uninstall) ;; *) die 'Unknown command; use --help.' ;; esac
    command -v jq >/dev/null || die 'Install jq before using this script.'
    exists "$LEGACY_STATE" && die 'An older smtp-oauth-deploy installation/recovery path exists. Use its original script to uninstall it first; this release will not overwrite it.'
    [[ ! -L $LOCK ]] || die 'Lock path is a symlink.'
    if exists "$LOCK"; then
        [[ -f $LOCK && $(stat -c %u "$LOCK") == 0 ]] || die 'The existing lock must be a root-owned regular file.'
    fi
    exec 9>"$LOCK"; flock -n 9 || die 'Another SMTP OAuth operation is running.'
    SELF=$(realpath -e -- "${BASH_SOURCE[0]}")
    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    case "$cmd" in
        init) init_main ;;
        check) prerequisites; if [[ -n $INPUT ]]; then validate_config "$INPUT"; say "Credential structure passed for $provider / $mailbox."; fi
               say 'Local prerequisites passed. install validates the refresh exchange; test verifies relay acceptance.' ;;
        install) [[ -n $INPUT ]] || die '--config is required.'; install_main ;;
        import-token) [[ -n $INPUT ]] || die '--config is required.'; import_main ;;
        status) status_main ;;
        test) [[ -n $RECIPIENT ]] || die '--recipient is required.'; test_main ;;
        uninstall) uninstall_main ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
