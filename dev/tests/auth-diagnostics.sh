#!/bin/bash
# shellcheck disable=SC1090,SC2034,SC2317
# Installer globals are consumed by sourced functions; native mode is disposable-only.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "${SCRIPT_UNDER_TEST:-$repo/smtp-oauth-deploy.sh}"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
secret='SECRET_CANARY_DO_NOT_PRINT'
response=$sandbox/response
assert_output(){
 local expected=$1 rc=$2 http=$3
 classify_token_response "$rc" "$http" "$response" > "$sandbox/out"
 grep -q "$expected" "$sandbox/out"
 if grep -Eq 'SECRET_CANARY|TOKEN_CANARY|evil@example' "$sandbox/out"; then exit 1; fi
}
printf '{"access_token":"TOKEN_CANARY","token_type":"Bearer","expires_in":3600}' > "$response"
assert_output AUTH-HELPER 0 200
for spec in '6 AUTH-DNS' '28 AUTH-NETWORK' '60 AUTH-TLS' '23 AUTH-LOCAL-IO' '124 AUTH-TIMEOUT' '1 AUTH-TRANSPORT'; do
 read -r rc expected <<< "$spec"; assert_output "$expected" "$rc" 000
done
for code in 7000215 7000222 700016 90002 7000218 700027 500011; do
 printf '{"error_codes":[%s],"error_description":"SECRET_CANARY evil@example.com","access_token":"TOKEN_CANARY"}' "$code" > "$response"
 assert_output "AADSTS$code" 0 400
done
printf '{"error_codes":"SECRET_CANARY","error":"SECRET_CANARY","error_description":"TOKEN_CANARY"}' > "$response"
for http in 400 401 403 429 500 302; do assert_output "AUTH-HTTP $http" 0 "$http"; done
printf '{"access_token":"TOKEN_CANARY","token_type":"Bearer","expires_in":"SECRET_CANARY"}' > "$response"
assert_output AUTH-RESPONSE 0 200
printf '<html>SECRET_CANARY</html>' > "$response"
assert_output AUTH-HTTP 0 400
if [[ -n ${NATIVE_HELPER:-} ]]; then
 [[ ${SMTP_DISPOSABLE_TEST:-0} == 1 && -f /.dockerenv ]] || { echo "Native integration requires an explicitly disposable container"; exit 1; }
 # Disposable container only: an actual non-root helper must load staged config
 # while the parent is in mode-700 /root. HTTPS is mocked; no credentials leave.
 id postfix >/dev/null 2>&1 || useradd --system postfix
 install -m 755 "$NATIVE_HELPER" /usr/local/bin/smtp-test-config
 install -m 755 "${NATIVE_HTTP_SHIM:?Set the compiled no-network shim path}" /usr/local/lib/smtp-no-network.so
 cat > /usr/local/bin/curl <<'CURL'
#!/bin/bash
# shellcheck disable=SC1090,SC2034,SC2317
# Installer globals are consumed by sourced functions; native mode is disposable-only.
set -eu
[[ $(id -un) == postfix && $PWD == / ]]
output='' form=''
while (($#)); do
 [[ $1 != *SECRET_CANARY* && $1 != *TOKEN_CANARY* ]]
 case "$1" in --output) output=$2; shift;; --data-binary) form=${2#@}; shift;; esac
 shift
done
[[ -r $form ]]
grep -q 'grant_type=client_credentials&client_id=' "$form"
grep -q 'client_secret=SECRET_CANARY_DO_NOT_PRINT&scope=https%3A%2F%2Foutlook.office365.com%2F.default' "$form"
printf '{"error_codes":[7000215],"error_description":"SECRET_CANARY_DO_NOT_PRINT","access_token":"TOKEN_CANARY"}' > "$output"
printf 400
CURL
 chmod 755 /usr/local/bin/curl
 client=$sandbox/client.json
 printf '{"client_id":"11111111-1111-1111-1111-111111111111","client_secret":"%s"}' "$secret" > "$client"
 CA=/etc/ssl/certs/ca-certificates.crt
 CONFIG_TEST=/usr/local/bin/smtp-test-config
 endpoint=https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/token
 # Native helper config loading, no network. A token-phase failure is injected.
 eval "$(declare -f candidate_helper | sed '1s/candidate_helper/native_candidate_helper/')"
 candidate_helper(){
  if [[ " $* " == *' --token '* ]]; then
   if runuser -u postfix -- env LD_PRELOAD=/usr/local/lib/smtp-no-network.so "$CONFIG_TEST" "$@" > "$WORK/native-probe.log" 2>&1; then exit 1; fi
   grep -q NETWORK_STAGE_REACHED "$WORK/native-probe.log" || { echo 'Native helper did not reach HTTP stage'; exit 1; }
   touch "$sandbox/network-reached"
   return 1
  fi
  timeout 15 runuser -u postfix -- "$CONFIG_TEST" "$@" > /dev/null
  native_candidate_helper "$@"
 }
 ausearch(){ return 1; }
 old_cwd=$PWD; cd /root; chmod 700 /root
 if (WORK=''; trap cleanup EXIT; prepare_candidate "$client") > "$sandbox/integration" 2>&1; then exit 1; fi
 cd "$old_cwd"
 grep -q 'AADSTS7000215' "$sandbox/integration"
 [[ -f $sandbox/network-reached ]]
 if grep -Eq 'SECRET_CANARY|TOKEN_CANARY' "$sandbox/integration"; then exit 1; fi
 if compgen -G '/var/tmp/smtp-oauth-cli.*' >/dev/null; then echo 'Staged files leaked'; exit 1; fi
 # Failed install must stop before snapshot/cutover and preserve prior credentials.
 INPUT=$client; provider=m365; mailbox=relay@example.com
 CONFIG=$sandbox/active-config; printf 'existing-credential' > "$CONFIG"
 prerequisites(){ :; }; validate_config(){ :; }; managed_settings(){ :; }; check_paths_new(){ :; }
 postqueue(){ echo 'Mail queue is empty'; }; confirm(){ :; }
 snapshot(){ touch "$sandbox/cutover"; }
 if (WORK=''; trap cleanup EXIT; install_main) > "$sandbox/install" 2>&1; then exit 1; fi
 [[ ! -e $sandbox/cutover && $(cat "$CONFIG") == existing-credential ]]
 # Non-readable CA must fail before helper execution/diagnostic POST.
 CA=$sandbox/unreadable-ca; printf private > "$CA"; chmod 600 "$CA"
 if (WORK=''; trap cleanup EXIT; prepare_candidate "$client") > "$sandbox/access" 2>&1; then exit 1; fi
 grep -q AUTH-LOCAL-ACCESS "$sandbox/access"
 if grep -q 'Native token helper failed' "$sandbox/access"; then exit 1; fi
 CA=/etc/ssl/certs/ca-certificates.crt
 candidate_helper(){ return 126; }
 if (WORK=''; trap cleanup EXIT; prepare_candidate "$client") > "$sandbox/config" 2>&1; then exit 1; fi
 grep -q 'AUTH-HELPER-CONFIG.*exit 126' "$sandbox/config"
 ausearch(){ echo SECRET_CANARY; return 0; }
 if (WORK=$(mktemp -d); trap cleanup EXIT; auth_failure 'AUTH-LOCAL-ACCESS') > "$sandbox/avc" 2>&1; then exit 1; fi
 grep -q 'not proof' "$sandbox/avc"
 if grep -q SECRET_CANARY "$sandbox/avc"; then exit 1; fi
 echo 'Real unprivileged native config under /root, redacted mock POST, access/exec failures and cleanup passed'
fi
echo 'Safe token classification and adversarial secret/token redaction tests passed'
