#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source smtp-oauth-cli/smtp-oauth-deploy.sh
# os-release defines VERSION too; detection must preserve deployment schema version.
(
    platform_values() { :; }
    detect_platform
    [[ $VERSION == 3.0.0 ]]
)
for distro in almalinux rocky rhel ol; do
    for major in 8 9 10; do
        for arch in x86_64 aarch64; do
            platform_values "$distro" "$major.1" "$arch"
            [[ $PLATFORM_ID == "$distro" && $PLATFORM_MAJOR == "$major" && $PLATFORM_ARCH == "$arch" ]]
        done
    done
done
for args in 'debian 9 x86_64' 'rocky 7 x86_64' 'ol 10 s390x'; do
    # Intentional splitting of fixed test inputs.
    # shellcheck disable=SC2086
    if (platform_values $args) >/dev/null 2>&1; then exit 1; fi
done
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
chmod 700 "$sandbox"
STATE=$sandbox/state; mkdir -m 700 "$STATE"
GUID=11111111-1111-1111-1111-111111111111
jq -n --arg guid "$GUID" '{provider:"m365", mailbox:"relay@example.com", tenant:$guid,client_id:$guid,client_secret:"a+&%= /secret"}' > "$sandbox/client.json"
chmod 600 "$sandbox/client.json"
validate_config "$sandbox/client.json"
[[ $endpoint == "https://login.microsoftonline.com/$GUID/oauth2/v2.0/token" ]]
for filter in '.provider="outlook"' '.tenant="common"' '.refresh_token="unwanted"' '.client_secret="bad\nsecret"' '.client_id="bad"'; do
  jq "$filter" "$sandbox/client.json" > "$sandbox/bad.json"; chmod 600 "$sandbox/bad.json"
  if (validate_config "$sandbox/bad.json") > /dev/null 2>&1; then echo "Unexpected validation success: $filter"; exit 1; fi
done
chmod 644 "$sandbox/client.json"
if (validate_config "$sandbox/client.json") > /dev/null 2>&1; then exit 1; fi
BACKEND=hash; relay=smtp.office365.com; managed_settings
[[ ${SETTINGS[inet_interfaces]} == 127.0.0.1 && ${SETTINGS[inet_protocols]} == ipv4 ]]
ss() { printf 'LISTEN 0 100 %s 0.0.0.0:*\n' "${LISTENER:-127.0.0.1:25}"; }
verify_listener
if (LISTENER=0.0.0.0:25; verify_listener) >/dev/null 2>&1; then exit 1; fi
# Reach the master.cf drift check with all file/hash prerequisites satisfied.
CONFIG=$sandbox/config; MAP=$sandbox/map; TOKENDIR=$sandbox/runtime; TOKEN=$TOKENDIR/token.json
mkdir -m 700 "$TOKENDIR"
printf '{}\n' > "$CONFIG"; touch "$MAP" "$MAP.db"; printf '{}\n' > "$TOKEN"
owned_hashes
postconf() {
  case "$1" in
    -h) printf '%s\n' "${SETTINGS[$2]}" ;;
    -F) echo 'smtp/unix/chroot = n' ;;
    -P) printf '%s' "${OVERRIDE:-}" ;;
    -M) if [[ ${2:-} == smtp/unix ]]; then echo 'smtp unix - - n - - smtp'; else echo 'smtp inet n - n - - smtpd'; fi ;;
  esac
}
guard_permissions() { :; }
guard_drift
if (OVERRIDE='smtp/unix/smtp_tls_security_level=none'; guard_drift) >/dev/null 2>&1; then exit 1; fi
# Status must fail when service is inactive even when configuration is correct.
load_state() { :; }
systemctl() { [[ $1 != is-active ]]; }
printf '{"status":"installed"}' > "$STATE/manifest.json"
if (status_main) >/dev/null 2>&1; then exit 1; fi
# Recovery failure keeps its marker; success removes it only after restart.
cp "$CONFIG" "$STATE/previous-config.json"; cp "$TOKEN" "$STATE/previous-token.json"
cp "$STATE/managed.sha256" "$STATE/previous.sha256"
touch "$STATE/import.pending"
install() { cp "${@: -2:1}" "${@: -1}"; }
label_runtime() { :; }
postfix() { return 1; }
if restore_import >/dev/null 2>&1; then exit 1; fi
[[ -f $STATE/import.pending ]]
postfix() { :; }
systemctl() { if [[ $1 == start ]]; then touch "$sandbox/started"; fi; }
OVERRIDE='smtp/unix/smtp_tls_security_level=none'
if restore_import >/dev/null 2>&1; then exit 1; fi
[[ -f $STATE/import.pending && ! -e $sandbox/started ]]
OVERRIDE=''
restore_import
[[ ! -f $STATE/import.pending ]]
# Uninstall refuses a queued message before changing recovery state/settings.
confirm() { :; }
postqueue() { echo 'QUEUED'; }
state_status() { touch "$sandbox/should-not-change"; }
if (uninstall_main) >/dev/null 2>&1; then exit 1; fi
[[ ! -e $sandbox/should-not-change ]]
printf 'Deployment tests passed.\n'
