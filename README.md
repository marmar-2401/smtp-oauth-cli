# Microsoft 365 SMTP OAuth from a Linux server

Applications submit email to `127.0.0.1:25`. Postfix relays it through
`smtp.office365.com:587` using verified TLS and OAuth 2.0 application authentication.
The Linux server uses an Entra application ID and client secret to obtain access
tokens. No browser, mailbox password, interactive mailbox login, device code, or
delegated refresh token is used.

This guide matches the supplied **3.0.0 script that retains `transport_maps`**.
Use one sending mailbox per installation. Run the commands as **root**, invoking
the script with `bash`, even when the login shell is `ksh`.

## Choose the workflow

| Situation | Start here |
|---|---|
| First installation on a server | [Fresh installation](#fresh-installation) |
| Add a second application server | [Second server: manual JSON copy and paste](#second-server-manual-json-copy-and-paste) |
| Existing SPN or other recipient-specific mail routes | [Existing transport maps](#existing-transport-maps), before installing |
| Install failed before credential activation | [Retry a failed installation](#retry-a-failed-installation) |
| Check credentials after the prerequisites are installed | [Validate the candidate JSON](#retry-a-failed-installation) |
| Rotate a secret on an installed server | [Replace application credentials](#replace-application-credentials) |
| Inspect service, token expiry, and managed settings | [Routine checks and reboot verification](#routine-checks-and-reboot-verification) |
| Credential import was interrupted | [Recover an interrupted import](#recover-an-interrupted-import) |
| Change mailbox or tenant, or remove the deployment | [Uninstall or migrate](#uninstall-or-migrate) |

`install` creates an installation. `import-token` updates application credentials
on an existing installation. Despite its name, `import-token` takes the application
JSON described below; it does not import a delegated refresh token.

## Files, paths, and script revision

All examples use the same working directory and input file:

```text
/root/smtp-oauth-cli/smtp-oauth-deploy.sh
/root/smtp-oauth-cli/m365-client-template.json
```

Each workflow starts in `/root/smtp-oauth-cli`, so `--config m365-client-template.json`
always identifies that file. If an existing deployment keeps its input JSON
elsewhere, keep it there and use its exact absolute path for every `--config`
argument, edit, permission change, backup, and restore. Moving or renaming it is
not required.

The completed JSON must be a root-owned regular file with no group/other access
(`chmod 600`), in a root-owned directory that is not writable by group or others.
Symlinked input paths are rejected. The distributed template contains placeholders;
once completed, it contains credentials. Keep completed files and their backups
out of commits, public repositories, and support logs.

**Keep the deployment script and this guide together.** Earlier scripts also report
`3.0.0` but reject or clear `transport_maps`. The version number alone does not
identify that behavior. A fresh clone may differ from the working server's local
script. Retain the reviewed script revision for installation, status, credential
updates, tests, and removal.

| Installed path | Purpose |
|---|---|
| `/etc/sasl-xoauth2.conf` | Active application credentials and token endpoint; contains the client secret |
| `/var/spool/postfix/smtp-oauth-cli/token.json` | Local access-token cache, maintained by the plugin |
| `/etc/postfix/smtp_oauth_cli_sasl` | Postfix credential lookup map pointing to the local token file |
| `/var/lib/smtp-oauth-cli` | Installation manifest, original settings, and recovery material |
| `/var/lib/smtp-oauth-cli-builds` | Successful native build records, source RPM, and provenance |

The operator input JSON and the installed SASL configuration have different
schemas. Editing the input JSON alone does not update an already installed server;
use `import-token`.

## Before setup

### Email administrator information

Obtain the sending mailbox, tenant GUID, application GUID, client-secret **Value**,
approved test recipient, secret expiration date, and named renewal contact.
The email administrator must authorize app-only SMTP and mailbox access using
one of the [Microsoft authorization routes](#email-administrator-microsoft-authorization).

Suggested request:

> Please provide the approved sending mailbox and a completed
> `m365-client-template.json` through our secure channel. This deployment uses
> Microsoft 365 app-only SMTP with an Entra application and client secret, without
> a browser or mailbox login on Linux. Please confirm the application has access
> to the intended mailbox, supply an approved test recipient, and identify the
> contact responsible for providing a replacement secret before its expiration.
> The email team owns Microsoft permissions and secret renewal; the Linux operator
> installs the supplied credentials and verifies delivery.

Copy credential text directly from the approved source. Uppercase `I`, lowercase
`l`, digit `1`, uppercase `O`, and digit `0` are different characters. Reconstructing
a secret from an image can produce valid JSON with an invalid secret.

### Linux and network requirements

The script targets AlmaLinux, Rocky Linux, RHEL, and Oracle Linux **8, 9, and 10**
with Bash 4.4 or newer and standard Postfix paths. Automatic native builds support
**x86_64**. The platform gate also accepts **aarch64** with a separately qualified
matching package, but there is no automatic build path for it. Other architectures
are rejected.

Required connectivity includes:

| Destination | Purpose |
|---|---|
| Approved OS repositories | Install dependencies and the local RPM |
| `github.com` | Clone the repository, when that distribution method is used |
| `raw.githubusercontent.com` and `codeload.github.com`, HTTPS | Obtain pinned build inputs on the first installation |
| `login.microsoftonline.com`, TCP 443 | Request application access tokens |
| `smtp.office365.com`, TCP 587 | Submit mail with STARTTLS and OAuth |
| Existing custom relay destinations | Continue delivering mail covered by retained transport entries |

Working DNS, correct system time, and trusted CA certificates are required.
The script configures an IPv4 loopback listener; other servers cannot use it as a
network SMTP relay without a separately reviewed design.

## Fresh installation

### 1. Obtain the matching files

If Git is not installed, install it through the approved OS repositories:

```bash
dnf install git -y
```

For a new checkout:

```bash
git clone https://github.com/marmar-2401/smtp-oauth-cli.git /root/smtp-oauth-cli
cd /root/smtp-oauth-cli
hostname
```

If that directory already exists, enter it instead of cloning over it. When using
a locally maintained deployment script, place the reviewed revision in this
directory before continuing. For a server with existing routes, verify that it is
the revision described in [Existing transport maps](#existing-transport-maps).

### 2. Complete the JSON

```bash
cd /root/smtp-oauth-cli
umask 077
vi m365-client-template.json
```

Paste the completed JSON supplied by the email administrator, or replace the
placeholders in this exact five-field format:

```json
{
  "provider": "m365",
  "mailbox": "REPLACE_WITH_SENDING_MAILBOX",
  "tenant": "REPLACE_WITH_TENANT_GUID",
  "client_id": "REPLACE_WITH_APPLICATION_GUID",
  "client_secret": "REPLACE_WITH_SECRET_VALUE"
}
```

To edit the existing placeholder values in `vi`, press `i`. To replace the entire
file with completed JSON instead, press `Esc`, type `:%d`, press Enter, then press
`i` and paste the full JSON. Save with `Esc`, `:wq`, and Enter. Keep quotes and
commas intact. Use the secret Value, not its ID. The installer rejects placeholders,
unknown fields, invalid tenant/application GUIDs, and unsupported providers.

```bash
chown root:root m365-client-template.json
chmod 600 m365-client-template.json
```

On a retry, edit the existing completed file. Do not overwrite it with the original
placeholder template.

### 3. Review repositories and any existing mail configuration

This checks repository metadata and dependency availability without installing
packages or enabling repositories:

```bash
bash smtp-oauth-deploy.sh repos
```

If repositories need configuration, review the proposal:

```bash
bash smtp-oauth-deploy.sh repos --setup
```

`repos --setup --yes` accepts the repository changes for unattended use after
they have been approved. **`install --yes` does not accept repository changes**;
it can still prompt for them on a terminal or refuse them in an unattended run.

If Postfix already exists, review its current relay, transport rules, and queue
before cutover. Use the [existing-routes workflow](#existing-transport-maps).
Pause application submissions and let existing mail finish delivery: install
requires an empty queue before and again during cutover. Deleting queued messages
is not a prerequisite or a standard installation step.

`check --config` is useful once the custom plugin and other prerequisites exist.
It does not install those prerequisites on a clean server; `install` performs that
bootstrap.

### 4. Install

```bash
cd /root/smtp-oauth-cli
bash smtp-oauth-deploy.sh install --config m365-client-template.json --yes &&
bash smtp-oauth-deploy.sh status
```

On the first installation, the script installs dependencies, builds the custom
`sasl-xoauth2-m365-cli` RPM as a temporary unprivileged user from pinned,
hash-checked inputs, and installs the resulting local package. No GitHub login,
Actions artifact, or separate manual compilation step is required.

An already installed matching custom RPM skips compilation and must pass the
script's integrity/capability checks. Stock `sasl-xoauth2` is not interchangeable.
An existing stock plugin, previous managed installation, or pre-existing relay
configuration requires migration review rather than forcing a fresh installation.

Repository changes, compiler/development packages, and successful build records
remain after uninstall. Local RPMs are unsigned; installations requiring signed
local packages need their approved signing process. Package-signature checks are
not disabled. A failed build may leave dependencies installed without changing
the relay configuration.

Expected successful milestones include:

```text
Application token request passed. Postfix acquires and caches tokens on demand; test verifies SMTP authorization separately.
Installed 3.0.0: sender@example.com through smtp.office365.com:587. Run test to prove relay acceptance.
```

During cutover, the installer deliberately stops Postfix and checks the queue.
`postqueue: warning: Mail system is down -- accessing queue directly` can appear
at that point in an otherwise successful installation. Afterward, `status` must
succeed. The same warning during normal operation requires checking the service.

### 5. Prove delivery acceptance and token refresh

Replace `operator@example.com` with an approved test recipient whose address will
route through Microsoft 365, rather than a custom transport exception. Each command
sends one real email. The forced-refresh test briefly restarts Postfix.

```bash
bash smtp-oauth-deploy.sh test --recipient operator@example.com --yes &&
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh --yes &&
bash smtp-oauth-deploy.sh status
postqueue -p
```

| Output | What it establishes |
|---|---|
| `Application token request passed` | The native helper obtained an application token |
| `Installed 3.0.0` | Local installation completed |
| `Local Postfix accepted queue ID ...` | The local SMTP service queued the test message |
| `Postfix token-file update after forced-expiry test: observed` | The forced-expiry test left a usable updated access-token cache |
| `RELAY ACCEPTED: smtp.office365.com accepted queue ID ...` | The script found Microsoft 365 delivery-acceptance evidence for that queue ID |

Both send tests should report `RELAY ACCEPTED`. The recipient must separately
confirm inbox or junk-folder receipt. Relay acceptance does not prove final inbox
placement or delivery through a different preserved route.

### 6. Configure the local application

| Setting | Value |
|---|---|
| SMTP server | `127.0.0.1` |
| Port | `25` |
| SMTP username/password for local submission | None |
| From address | The configured sending mailbox |

Use the authorized mailbox as both envelope sender and message From address unless
the email administrator has explicitly authorized another sender. The script does
not add a general sender-rewriting map. Postfix handles verified TLS and OAuth for
the upstream Microsoft 365 connection.

The local host is the submission trust boundary: any local process that can reach
the loopback SMTP listener can submit mail. This setup does not provide separate
SMTP authentication or isolation for different applications on the same host.

After the Microsoft 365 tests and any applicable retained-route tests succeed,
resume application submissions and verify an actual application-generated message.

## Second server: manual JSON copy and paste

Use this workflow when the email administrator authorizes the same application
credentials and mailbox on another server. Each server runs its own installation
and maintains its own local access-token cache.

### SOURCE: the working server

Confirm the hostname before reading credentials:

```bash
hostname
cat /root/smtp-oauth-cli/m365-client-template.json
```

Copy the complete JSON as text. If the working server keeps its operator JSON at
another path, use that actual path. If the file might no longer match the active
installation, inspect the installed values on this **working source server**:

```bash
jq '{client_id, client_secret, token_endpoint}' /etc/sasl-xoauth2.conf
jq '{provider, mailbox, tenant}' /var/lib/smtp-oauth-cli/manifest.json
```

These commands display credentials for local operator use. The tenant is recorded
in the manifest and also appears in the token endpoint. Use these values to correct
the five-field input JSON; do not paste the installed SASL configuration wholesale
into the operator JSON because its schema differs.

The destination's default SASL configuration is not a source of working credentials
before installation succeeds. Attempting to split a missing `token_endpoint` there
can produce `jq: split input and separator must be strings`.

### DESTINATION: the new server

Obtain the same reviewed deployment-script revision and review this server's own
repositories, queue, and existing routes. Then:

```bash
hostname
cd /root/smtp-oauth-cli
umask 077
vi m365-client-template.json
```

Replace the file contents with the source server's complete, approved JSON text,
using the replace-entire-file editor sequence above. Save and exit, then run:

```bash
chown root:root m365-client-template.json
chmod 600 m365-client-template.json
bash smtp-oauth-deploy.sh install --config m365-client-template.json --yes
```

After installation succeeds, perform the [delivery and refresh tests](#5-prove-delivery-acceptance-and-token-refresh)
on the destination. Copying JSON does not perform that installation or test.
Runtime token caches, mail queues, and `/var/lib/smtp-oauth-cli` belong to their
individual servers and are not transferred as part of this workflow.

## Existing transport maps

The supplied script leaves `transport_maps` and its existing map files in place.
It still rejects nonempty `sender_dependent_relayhost_maps` and
`sender_dependent_default_transport_maps`. Multiple Postfix instances, custom
default transports, and custom standard SMTP service overrides also require
separate integration; retaining recipient transport maps does not remove those
restrictions.

Before installation, record the current settings:

```bash
postconf relayhost transport_maps sender_dependent_relayhost_maps sender_dependent_default_transport_maps
postconf default_transport relay_transport smtp_tls_security_level smtp_tls_policy_maps
postconf smtp_sasl_auth_enable smtp_sasl_password_maps smtp_sasl_mechanism_filter smtp_sender_dependent_authentication
postqueue -p
```

Inspect the maps actually named by `transport_maps`. For example, if it names
`hash:/etc/postfix/transport`, inspect the text file:

```bash
cat /etc/postfix/transport
```

**Retaining a routing table does not retain every setting used by that route.**
The installer changes global outgoing SMTP settings, including:

| Setting | Installed behavior |
|---|---|
| `relayhost` | `[smtp.office365.com]:587` |
| `smtp_tls_security_level` | `verify` |
| `smtp_tls_policy_maps` | Cleared |
| `smtp_sasl_password_maps` | Replaced with this deployment's Microsoft 365 credential map |
| `smtp_sasl_mechanism_filter` | `xoauth2` |
| `smtp_sender_dependent_authentication` | `no` |

An existing route using the standard SMTP transport can inherit these changes.
Review whether it relies on different credentials, authentication mechanisms, or
destination-specific TLS policies. Resolve such dependencies before installation;
this script does not automatically merge them. Retained maps are also outside
the script's managed-setting drift checks.

After installation, compare `postconf transport_maps` and the map contents with
the baseline. Send an approved application/SPN test through each retained route,
check its actual relay and `status=sent` in the mail logs, and confirm receipt with
that route's recipient. The script's `test` command specifically checks
`smtp.office365.com`; it is not an acceptance test for an unrelated SPN relay.

If a script reports `Existing transport_maps requires manual integration`, inspect
its revision. Older versions both reject that setting and later clear it. Use the
reviewed transport-preserving script; removing only the rejection is insufficient.
Do not clear a working transport map to pass the installer.

## Retry a failed installation

Use the stage reported by the script to select the next action. When candidate
token validation reports `No candidate was activated`, the new credentials have
not replaced the active relay credentials. Packages may already be installed.

After correcting the cause, retry with the same completed JSON and path:

```bash
cd /root/smtp-oauth-cli
chmod 600 m365-client-template.json
bash smtp-oauth-deploy.sh install --config m365-client-template.json --yes
```

If the custom plugin and prerequisites are already installed, this validates
the candidate without changing active Postfix settings:

```bash
bash smtp-oauth-deploy.sh check --config m365-client-template.json
```

`check --config` obtains a candidate token; bare `check` only checks prerequisites.
Neither sends mail or establishes SMTP mailbox authorization. If installation
already completed successfully, use `import-token`
for credential changes. If a failed cutover reports incomplete rollback, retain
the state directory and follow the recovery error rather than deleting managed
files and retrying over them.

## Troubleshooting by stage

| Message or symptom | Next action |
|---|---|
| DNF `Could not resolve host` / Curl error 6 | Check the repository hostname, DNS, and repository URL; repair that before retrying package installation |
| Invalid application JSON or file-permission error | Check the five fields, actual file path, root ownership, mode 600, protected parent directory, and absence of symlinked paths |
| `AUTH-LOCAL-ACCESS` | Check the staged files, postfix user's access, cache-directory permissions, and relevant SELinux events |
| `AUTH-HELPER-CONFIG` | Check native helper execution, libraries, package integrity, and its local configuration; this fails before a token request |
| `AUTH-DNS`, `AUTH-NETWORK`, or `AUTH-TLS` | Check token-endpoint DNS, HTTPS routing/proxy access, time, and CA trust; retain TLS verification |
| `AADSTS7000215` | Compare the exact secret Value and tenant/application pairing with the approved source; check case, similar-looking characters, and unintended whitespace |
| `AADSTS7000222` | The secret is reported expired; obtain and deploy its replacement |
| `AADSTS700016` or `AADSTS90002` | Verify the application ID and tenant ID with the email administrator |
| `AUTH-HELPER` after a separate successful token POST | Investigate the native helper/cache/runtime or SELinux; that result does not identify a bad secret |
| Token succeeds but SMTP returns a permission/policy error | Have the email administrator check the selected authorization route, mailbox access, sender, and effective SMTP AUTH policy |
| Local queue ID appears, but relay acceptance is unconfirmed | Inspect that queue ID and the mail logs; a queued message may still be delivered later, so repeated tests can create duplicates |
| `Managed configuration drift detected` | Compare the recorded managed settings with current configuration and use the matching script; review the change before continuing |
| `Existing managed path` | Determine whether installation already exists or recovery is pending; use its status/import/recovery workflow |
| `jq: split input and separator must be strings` during credential inspection | Confirm the hostname and use the working server's installed configuration; a default/absent endpoint is not a credential source |

### Rejected secret

For `AADSTS7000215`, first correct the submitted secret or application pairing.
The code alone does not establish that the secret expired or that a new app
registration is needed. Use exact text from the approved credential source or
the [working server's active configuration](#source-the-working-server). Do not
guess character substitutions from a screenshot. See Microsoft's
[confidential-client troubleshooting](https://learn.microsoft.com/en-us/entra/msal/dotnet/advanced/exceptions/confidential-client-troubleshoot)
and [error-code reference](https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes).

### Repository or token-network failures

Useful initial checks include:

```bash
dnf --refresh makecache
getent hosts login.microsoftonline.com
getent hosts smtp.office365.com
timedatectl status
```

For an Oracle Cloud repository failure, review the configured repository URL and
the server's `ociregion`/`ocidomain` variables against the approved configuration
for its region. A malformed repository hostname can look like a DNS failure.
Use the [Oracle repository guidance](https://yum.oracle.com/getting-started.html);
do not apply another deployment's regional hostname blindly.

A successful website request or HTTP HEAD request does not test the OAuth token
POST. When appropriate, the script performs one bounded diagnostic POST after a
native token request fails and reports recognized errors without printing raw
tokens, secrets, or server responses.

### Queued or deferred test message

```bash
postqueue -p
journalctl -t postfix/smtp --since '15 minutes ago' --no-pager
```

If the system writes `/var/log/maillog`, inspect that as well. Match the actual
queue ID, recipient, next-hop relay, and delivery status. The test waits for
upstream evidence for up to 45 seconds and preserves the queue on failure.

After resolving the reported delivery problem, `postqueue -f` requests another
delivery attempt for queued mail. Use it when appropriate for the queued messages;
it is not a credential repair and it is not needed after every successful send.

## Replace application credentials

Access tokens renew on SMTP authentication. **The client secret does not renew
itself.** The email administrator tracks its expiration and supplies a replacement
before expiry. The script neither discovers the secret expiration date nor
schedules secret rotation.

For normal rotation, keep the same tenant, application ID, and mailbox. The
administrator adds a replacement secret to the existing app and keeps the old
one valid until all authorized consumers have been updated and tested. Use its
Value, not the secret ID; follow Microsoft's
[application-credential instructions](https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-credentials).

On each installed server, start with an input JSON that matches the active
credentials. Make the protected backup once before editing:

```bash
cd /root/smtp-oauth-cli
install -m 600 m365-client-template.json m365-client-previous.json
vi m365-client-template.json
```

Replace `client_secret`, save, and run:

```bash
chmod 600 m365-client-template.json
bash smtp-oauth-deploy.sh import-token --config m365-client-template.json --yes &&
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh --yes &&
bash smtp-oauth-deploy.sh status
```

Replace the example recipient first. The `&&` chain runs the send test only after
import succeeds and runs status only after the send test succeeds. Require the
`Credentials replaced` message: a failed import preserves the old credentials, so
a separately run successful send could otherwise test the old secret.

Import validates the candidate before
activation, briefly restarts Postfix, and records the previous credentials for
recovery. The importer requires the same provider, mailbox, and tenant. It can
accept a different client ID, but that application's authorization must be reviewed;
ordinary secret rotation does not require changing the application ID.

If a completed import passes token validation but fails the SMTP test, resolve
the reported issue or re-import the previous approved JSON while its secret is
still active:

```bash
install -m 600 m365-client-previous.json m365-client-template.json &&
bash smtp-oauth-deploy.sh import-token --config m365-client-template.json --yes &&
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh --yes
```

Import completes before the later SMTP test. `recover-import` does not undo a
completed import. Retire the old Entra secret only after every consumer passes
testing and recipients confirm delivery. Handle obsolete operator backups through
the organization's credential-retention procedure. Successful import also retains
`previous-config.json` and `previous-token.json` inside the root-only state
directory; these include the previous secret and token. Removing only the operator
backup does not remove those copies. Retain required recovery material and apply
the approved retention procedure after acceptance.

## Routine checks and reboot verification

```bash
cd /root/smtp-oauth-cli
bash smtp-oauth-deploy.sh status
systemctl is-active postfix
systemctl is-enabled postfix
ss -ltn 'sport = :25'
postqueue -p
```

For this deployment, the SMTP listener should be `127.0.0.1:25`. `status` checks
the installation, service/listener, managed settings, and file protections. It
reports token expiry but does not acquire a token or send an email. An empty cache
is acquired on the next SMTP authentication; an expiry timestamp alone is not
proof that refresh works.

After a planned reboot, repeat those checks and the approved forced-refresh send
test. Repeat any separate preserved-route tests. The plugin refreshes access
tokens on demand during SMTP authentication; this deployment does not need a
separate cron job to edit or copy access tokens.

Use normal service/queue monitoring to detect an inactive Postfix service or
persistently deferred mail, and assign an owner to secret-expiry reminders.
`status` is a manual check, not a continuous monitoring service. An old token-expiry
timestamp on an idle server does not by itself show that on-demand refresh is broken.

## Recover an interrupted import

Use this only when the script records an interrupted import:

```bash
cd /root/smtp-oauth-cli
bash smtp-oauth-deploy.sh recover-import --yes &&
bash smtp-oauth-deploy.sh status &&
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh --yes
```

It either completes recovery from an interrupted preparation or restores the
credentials saved before the pending import. If recovery fails, retain
`/var/lib/smtp-oauth-cli` and resolve the reported error. A normal, completed
credential change is reversed by re-importing the prior approved JSON instead.

## Uninstall or migrate

The importer cannot change the configured mailbox or tenant. Plan such a migration
with the email administrator, including authorization and a drained-queue cutover.

For removal, pause application submissions and let the queue drain with the current
relay. Once it is empty:

```bash
cd /root/smtp-oauth-cli
postqueue -p
bash smtp-oauth-deploy.sh uninstall
```

The command asks before restoring the recorded pre-install settings/service state
and removing this deployment's managed credentials and recovery state. It stops
Postfix and checks the queue again before restoring anything. A nonempty queue
blocks removal. Recover a pending credential import first.

Packages, build records, repository changes, and Microsoft-side permissions remain.
Retained transport-map files remain outside the deployment's managed files. Resolve
any reported incomplete restore using the retained state and matching script.

## Command reference

These are the options accepted by this script:

```text
bash smtp-oauth-deploy.sh repos [--setup [--yes]]
bash smtp-oauth-deploy.sh check [--config JSON]
bash smtp-oauth-deploy.sh install --config JSON [--yes]
bash smtp-oauth-deploy.sh status
bash smtp-oauth-deploy.sh test --recipient EMAIL [--force-refresh] [--yes]
bash smtp-oauth-deploy.sh import-token --config JSON [--yes]
bash smtp-oauth-deploy.sh recover-import [--yes]
bash smtp-oauth-deploy.sh uninstall [--yes]
bash smtp-oauth-deploy.sh --version
bash smtp-oauth-deploy.sh --help
```

`check` and `status` do not accept `--yes`. `repos --yes` requires `--setup`.
`--yes` skips the supported operation's confirmation; it does not bypass failed
validation, queue, drift, permission, or architecture checks.

## Email administrator: Microsoft authorization

The email administrator performs this work using approved Microsoft administration
tools. The Linux operator needs the completed JSON and confirmation of authorization.

Register the application, create the client secret, record its Value and expiration,
and register the service principal in Exchange. Use the **Enterprise Application's
service-principal object ID**, which differs from the App Registration object ID.
Choose the authorization model for the deployment and follow its Microsoft procedure:

| Route | Administrator procedure |
|---|---|
| Entra application permission | Configure Exchange Online `SMTP.SendAsApp`, tenant admin consent, the Exchange service principal, and the intended mailbox permissions. Follow the SMTP/SendAs requirements in Microsoft's [client-credentials instructions](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth). FullAccess and SendAs are not interchangeable. |
| Exchange Application RBAC | Assign `Application SMTP.SendAsApp` with the intended mailbox resource scope using Microsoft's [SMTP App RBAC onboarding](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding). That procedure does not require mailbox permissions and says to omit the Entra `SMTP.SendAsApp` claim, which would trigger an additional mailbox-permission check. |

Review effective access, including any separate Entra grants: RBAC scopes do not
restrict those independent grants. Microsoft's [Application RBAC reference](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)
also explains the limits of its authorization test.

Verify the mailbox's effective [SMTP AUTH policy](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission).
SMTP AUTH can use OAuth; it is not synonymous with password-based authentication.
Token acquisition alone does not establish mailbox SMTP authorization. If tenant
policy prohibits this flow, agree an approved alternative; Linux setup commands
should not weaken tenant-wide policy to make a test pass.

The token request uses `https://outlook.office365.com/.default`. This implementation
accepts a client secret only. Microsoft recommends certificates or federated
credentials over client secrets for production; those authentication methods would
require implementation changes, rather than extra fields in this JSON.

## Validation and handover

The supplied deployment results demonstrate installation, application-token
acquisition, forced runtime token refresh, and Microsoft 365 relay acceptance on
the tested Oracle Linux 8 deployment.

Those logs do not establish every distribution/architecture combination, every
tenant, reboot recovery, final inbox placement, or the behavior of separate SPN
routes. The custom plugin and on-server build path require qualification for each
supported deployment environment; version/source pins are not vendor certification
or a promise of byte-identical RPMs.

Record the following at handover:

- OS, architecture, package versions, and the exact reviewed deployment-script revision.
- Normal and forced-refresh test queue IDs, relay-acceptance results, and recipient confirmation.
- Separate tests for existing custom routes, where present.
- Service/listener and send-test results after a planned reboot.
- Mailbox, application/tenant identifiers, secret-expiry owner, and renewal process, without publishing secret values.

Use a disposable lab for failure tests: rejected credential import should preserve
working sending; a network outage should leave mail queued; interrupted import
recovery should restore sending; and uninstall with an empty queue should restore
the prior settings/service. Include SELinux-enforcing validation and check that
operational logs do not disclose credentials. Retain the test results with the
deployment record rather than treating this checklist as evidence of completion.

For a trial tenant, follow Microsoft's current [trial and billing guidance](https://learn.microsoft.com/en-gb/microsoft-365/commerce/try-or-buy-microsoft-365?view=o365-worldwide),
record its expiry/renewal settings, and verify that tenant policy permits the SMTP
flow before relying on it. A trial subscription by itself does not establish SMTP
authorization.

## Maintainer resources

The operator distribution consists of this guide, the matching deployment script,
and the placeholder JSON template. The separately maintained
[plugin source, license, and build material](https://github.com/marmar-2401/smtp-oauth-cli/tree/maintenance/m365-build)
support the native package. Keep credentials and completed operator JSON files
out of the repository when publishing updates.
