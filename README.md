# Microsoft 365 SMTP relay — CLI only

Start with `smtp-oauth-deploy.sh` and `m365-client-template.json` beside this guide.
`dev/` contains maintainer-only build recipes and tests; `.github/` runs CI.

Postfix accepts application mail at **127.0.0.1:25** and sends it through
`smtp.office365.com:587` with verified TLS and application-only OAuth.
This application-only workflow needs no mailbox login, device code, browser,
user refresh token or token daemon. Configure the tenant ID, application ID,
client secret and one sending mailbox for each deployment. The tenant's
administrator must approve the application and mailbox scope.

Scope: **commercial Microsoft 365**, client-secret authentication and one mailbox
per dedicated Postfix instance. Certificate credentials, sovereign clouds, personal
Outlook.com, Gmail and other providers are outside this release. The original 2.1.0
delegated workflow remains in Git at commit `4a3fbbd84a6b213a5c1fc4470580cd4a0da5798f`.

**QA candidate; live qualification pending:** target platforms are AlmaLinux, Rocky Linux,
Red Hat Enterprise Linux and Oracle Linux, each at major 8/9/10. Native tests and container package builds do not certify
live systems, SELinux or a tenant's authorization policy. Centrally managed tenants
may require approval from their service provider. Complete [administrator and QA instructions below](#administrator-setup-and-release-qualification)
before production. It includes the Business Basic one-month trial lab; activate
the trial after the matching package is ready.

## Client intake — copy into a new setup task

```text
CLIENT OAUTH 2.0 EMAIL SETUP QUESTIONS

Please have your email administrator complete this before we schedule setup.

1. Which email service will we connect to?
Microsoft 365, a centrally managed service, or another provider? Provide the
approved SMTP hostname, port and any integration documentation.

2. Who is the email administrator for this request?
Provide their name, contact details and availability for setup/testing.
Does a separate service provider need to approve the integration?

3. Which sending mailbox should the application use?
Provide its address, whether it is a user or shared mailbox, and any additional
From addresses required.

4. Which authentication method is approved?
Can we use application-only OAuth (client credentials) without mailbox sign-in?
If not, is delegated OAuth required, or is sending only allowed through Graph?

5. Has the application been authorized to send as this mailbox?
Confirm the approved SMTP application permissions/mailbox scope and whether
SMTP AUTH is allowed under tenant policy. Do not change security policies
solely to complete this questionnaire.

6. What application configuration is available?
Provide the tenant ID and application/client ID. Confirm whether authentication
requires a client secret or certificate, its expiry date and the renewal owner.
Do not include the secret, private key or tokens in your response.

7. Which Linux server and applications will send mail?
Provide hostname, distribution/version and architecture. Do applications run
on that server, or submit from other systems? Does Postfix use another relay?

8. Is the required outbound network access available?
Confirm DNS and HTTPS access to the approved Microsoft token endpoint, plus
SMTP access to the approved relay (normally TCP 443 and 587 for standard
Microsoft 365). Note proxy, TLS inspection and firewall restrictions.

9. What must the email service handle?
Internal recipients, external recipients, or both? Include daily/peak volume,
attachment sizes, and delivery or encryption requirements.

10. How should we test and hand over?
Provide an approved test recipient, change window, delivery-confirmation
contact and approved secure method for transferring credentials. Use test
messages without patient or other sensitive data.

Do not paste passwords, client secrets, private keys or access/refresh tokens
into this task. Transfer credentials only through the agreed secure channel.
```

**Operator go/no-go:** the current script handles commercial Microsoft 365,
application-only OAuth with a client secret, one approved sending mailbox and local
submission at `127.0.0.1:25`. Delegated-only, Graph-only, certificate-only, unsupported
clouds, additional sending identities or remote submission require a separate
review/design. Collecting those requirements does not mean this script supports them.
Proceed only after the responsible administrator approves the applicable SMTP route
and credentials can be transferred securely.

## 1. Obtain the approved package and configuration

Have the administrator complete [administrator and QA instructions below](#administrator-setup-and-release-qualification) and securely supply the tenant
ID, application ID, sending mailbox and **secret value**, with its expiration date.
The separate `sasl-xoauth2-m365-cli` RPM is required: stock sasl-xoauth2 cannot do
this flow. Clients do not compile the plugin. Use an approved signed production
RPM, or a matching **unsigned QA bundle** on a disposable lab host only.

For QA, open this repository's **Actions > Local validation**, select a successful
run for the exact commit you intend to test, and download the matching `qa-DISTRO-elMAJOR-x86_64` bundle
(`DISTRO` is `alma`, `rocky` or `oracle`; `MAJOR` is 8, 9 or 10) under **Artifacts**. GitHub sign-in may be required;
use your workstation browser, not the Linux server. Alternatively, on a workstation
with GitHub CLI authenticated (replace `RUN_ID` and select the correct EL major):

```bash
gh run download RUN_ID --repo marmar-2401/smtp-oauth-cli --name qa-alma-el9-x86_64 --dir qa-el9
cd qa-el9
cat PROVENANCE.txt
sha256sum -c SHA256SUMS
scp -r . root@YOUR_LAB_HOST:/root/smtp-qa/
```

Match `distribution` and `el_major` to `/etc/os-release`, architecture to `uname -m`,
and source_commit
to the selected successful run. Checksums detect corruption; **they are not package
signatures or production approval**. Artifacts expire after 30 days. Current CI artifacts are x86_64 only. For aarch64,
obtain a separately built and tested matching package; never install an x86_64 RPM.
RHEL requires an approved subscription-backed build/validation; no RHEL-certified
binary is claimed from another distribution's container. The bundle
contains the matching deployment script, template, documentation, binary RPM and
source RPM. On the lab host, run `cd /root/smtp-qa`, repeat `sha256sum -c SHA256SUMS`,
then continue with prerequisites below. Install only the matching binary RPM,
never the `.src.rpm`.

For a controlled rebuild or production signing, use [dev/README.md](dev/README.md)
in the approved source checkout. Use immutable reviewed inputs; do not download and
execute mutable `main` as root. Verify production package signatures through your
release process. QA success is not production certification.

All following commands run as **root**, from the approved repository or QA bundle directory.
Install OS prerequisites from your approved repositories:

```bash
dnf install -y postfix cyrus-sasl cyrus-sasl-lib cyrus-sasl-devel jq ca-certificates util-linux iproute policycoreutils policycoreutils-python-utils
```

On an existing delegated installation, first pause submissions, drain its queue and
follow recovery below **before changing plugin packages**. The application RPM
conflicts explicitly with stock `sasl-xoauth2`; review the package replacement
transaction, including any dependents. This installer never removes packages.
Install the matching RPM (EL9 QA example below; select EL8/10 as appropriate, or
substitute the approved signed production RPM path):

```bash
dnf install packages/sasl-xoauth2-m365-cli-0.28-1.smtpcli.el9.x86_64.rpm
install -d -m 700 /root/smtp-oauth
install -m 600 m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh status
```

Keep JSON private and root-owned. Enter credentials in the file, never in shell
arguments or tickets. The installer checks the application token exchange; this
alone does not prove mailbox authorization. It snapshots existing Postfix settings,
checks the queue, and rolls back failed activation. Use a dedicated standard Postfix
instance without custom transports or SMTP service overrides. It installs a narrow
SELinux policy when SELinux is enabled; it does not change firewall or tenant policy.

## 2. Verify delivery

These commands each send one actual message. Replace the recipient and approve the
prompt. `--force-refresh` clears the cached token and proves native acquisition:

```bash
bash smtp-oauth-deploy.sh test --recipient operator@example.com
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Success requires queue-ID-matched upstream `status=sent`, not just local acceptance.
Confirm receipt separately. Configure your application to use **127.0.0.1, port 25**,
with the approved mailbox as sender. Local submissions need no SMTP credentials.
Other local users can also submit mail; use a dedicated trusted server.

## 3. Replace an expiring secret or recover

Before expiry, obtain an approved replacement secret, update the protected JSON,
then run:

```bash
bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Keep the previous secret valid until verification succeeds. The application obtains
new access tokens on demand; Postfix retains failed mail for its ordinary queue retry.
No timer is required. Monitor the queue, service health and **client secret expiry**.

```bash
bash smtp-oauth-deploy.sh status
postqueue -p
bash smtp-oauth-deploy.sh recover-import
```

`recover-import` is only for an interrupted import. It restores the protected prior
credentials or resumes after interrupted preparation. Never print runtime token
files. If a crash leaves `token.json.new`, stop Postfix, remove only that temporary
file, then start Postfix; the old atomic cache remains intact:

```bash
systemctl stop postfix
rm -f /var/spool/postfix/smtp-oauth-cli/token.json.new
systemctl start postfix
```

For failed installation or removal, retain `/var/lib/smtp-oauth-cli` and rerun
uninstall after correcting the reported error. Configuration drift blocks destructive
recovery: review and restore the recorded settings first. Versions 2.0.0/2.0.1/2.1.0
are accepted for status/removal only; retain their original script and credential
backups, particularly if a delegated grant had rotated during a failed import.
This release cannot recover a refresh grant that an older script already deleted.
The older `/var/lib/smtp-oauth-deploy` layout requires its original removal script.

```bash
bash smtp-oauth-deploy.sh uninstall
```

Uninstall restores prior managed settings and service state; it preserves packages,
the mail queue and tenant authorization. Pause submissions and drain the queue before
migration/removal so queued mail is not sent using restored settings. Review retained
private backups and revoke unused secrets through the administrator after success.

## Administrator setup and release qualification

Obtain the responsible tenant administrator's approval for application-only SMTP
and the mailbox scope before running these commands. A local administrator in a
centrally managed tenant may need the service provider to register the application
and grant access. This guide targets commercial Microsoft 365; approval in one
tenant does not establish compatibility with every managed service or cloud.
If only Graph or delegated SMTP is approved, choose an appropriate separate design;
do not silently substitute either into this application-only SMTP workflow.

For a tenant that approves this route, use **Exchange Application RBAC only**. Do not add the Entra
`SMTP.SendAsApp` API permission/claim or combine this with classic mailbox permission
grants. Microsoft documents that the claim activates a different permission check.
The administrator signs in using an approved management workstation; there is no
mailbox sign-in or browser on the Linux relay.

1. Register a single-tenant Entra application. Record its application/client ID and
   tenant GUID. Create a client secret and record its **value** and expiration.
   Do not enable public-client flows or add delegated permissions.
2. Record the **Enterprise Application service principal object ID**. This is not
   the App Registration object ID.
3. In an authorized Exchange Online PowerShell session, replace the example values
   and register the service principal. Scope access to the one mailbox:

```powershell
$AppId = 'REPLACE_WITH_APPLICATION_GUID'
$EnterpriseObjectId = 'REPLACE_WITH_ENTERPRISE_APPLICATION_OBJECT_GUID'
$Mailbox = 'relay@example.com'
New-ServicePrincipal -AppId $AppId -ObjectId $EnterpriseObjectId -DisplayName 'SMTP relay'
New-ManagementScope -Name 'SMTP relay mailbox' -RecipientRestrictionFilter "PrimarySmtpAddress -eq '$Mailbox'"
New-ManagementRoleAssignment -Name 'SMTP relay send' -Role 'Application SMTP.SendAsApp' -App $AppId -CustomResourceScope 'SMTP relay mailbox'
Test-ServicePrincipalAuthorization -Identity $AppId -Resource $Mailbox
```

Check that the authorized mailbox is in scope and a different mailbox is out of
scope. Resolve existing application grants before reuse; a fresh dedicated application
avoids broader inherited access. Allow policy propagation before SMTP testing.

SMTP AUTH must be permitted under the tenant’s approved policy for this mailbox.
Review its effective settings and authentication policy; **do not disable Security
Defaults or weaken tenant-wide controls to make this script work**. If the security
baseline forbids SMTP AUTH, this relay design requires an administrator-approved
alternative. The script performs no tenant changes.

Deliver the five-field JSON through a secure channel and record the secret renewal
owner/date. The native plugin requests the tenant-specific v2 endpoint using
`client_credentials`, scope `https://outlook.office365.com/.default`. SMTP identity
is the configured sending mailbox. Access-token acquisition does not establish
Exchange authorization; run the delivery tests.

Sources: [Microsoft SMTP App RBAC onboarding](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding),
[SMTP OAuth and application tokens](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth).
Verified against these pages on 2026-11-02.

## Release gate — still required

For each AlmaLinux, Rocky Linux, RHEL and Oracle Linux major 8/9/10 and intended
architecture, build the matching RPM and
run native/deployment tests. In disposable VMs with SELinux **enforcing**, check
install, restart, reboot, labels/AVCs, drift rejection, import rollback at each
interruption point, legacy uninstall and interrupted uninstall. Verify no external
SMTP listener, queue preservation, unchanged firewall and correct baseline restore.

With an approved test tenant and recipient, verify token acquisition, ordinary and
forced-refresh SMTP delivery, concurrent workers, expired/revoked secret, unavailable
token endpoint, malformed response, and certificate rejection. Confirm mailbox
scope isolation and queue retry after recovery. Review logs for token/secret leakage.
Do not treat a container build or mocked HTTP tests as these acceptance tests.

## CLI QA walkthrough (isolated test host)

Run as root from the approved checkout. Replace the approved test recipient in the
commands below. These tests send mail and interrupt service; run only with explicit
recipient/tenant permission, stopped application submissions and a disposable host.
Use a commercial Microsoft 365 test tenant with approved application-only SMTP
permissions. Final acceptance must also run in the intended sending tenant.

1. Follow the deployment steps above installation, then run:

```bash
bash smtp-oauth-deploy.sh status
ss -ltn 'sport = :25'
postqueue -p
bash smtp-oauth-deploy.sh test --recipient operator@example.com
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Pass: status exits 0, only `127.0.0.1:25` listens, both sends print `RELAY ACCEPTED`
with queue IDs, forced renewal reports a token-file update, and the recipient
confirms both messages. A queued ID alone is **not** a pass.

2. Reboot and check persistence:

```bash
reboot
# Reconnect, return to the approved checkout, then:
systemctl is-active postfix
bash smtp-oauth-deploy.sh status
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Pass: service active, status exit 0, native renewal and upstream acceptance observed.

3. Test bad credentials without destroying the working credential:

```bash
umask 077
jq '.client_secret="deliberately-invalid-qa-secret"' /root/smtp-oauth/client.json > /root/smtp-oauth/bad.json
bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/bad.json --yes
echo "exit=$?"
bash smtp-oauth-deploy.sh status
rm -f /root/smtp-oauth/bad.json
```

Pass: import exits nonzero, reports a generic token failure without secret contents,
status still succeeds, and a normal send still works. Invalid credentials must never
replace active configuration.

4. Test unavailable token access using a temporary loopback proxy on the disposable
host. First confirm port 9 is unused (`ss -ltn 'sport = :9'` must show no listener).
Use a copied QA credential only; these commands test preactivation failure without
editing firewall rules or the live plugin configuration:

```bash
HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 NO_PROXY= no_proxy= \
  bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/client.json --yes
echo "exit=$?"
bash smtp-oauth-deploy.sh status
```

Pass: bounded nonzero failure, no activation, existing status succeeds. For **runtime
queue retry**, separately use the lab's approved network fault injection to block
only token-endpoint HTTPS from Postfix, then run the forced-renewal send. Expect
nonzero/no `RELAY ACCEPTED`, deferred mail in `postqueue -p` and no secret leakage.
Restore lab connectivity, then:

```bash
postqueue -f
postqueue -p
journalctl -t postfix/smtp --since '10 minutes ago' --no-pager
```

Pass: the **same** recorded queue ID reaches upstream `status=sent`; do not submit a
replacement and call that recovery. Actual queue-failure testing is not covered by
the temporary proxy preactivation test.

5. Test interruption recovery on a disposable VM snapshot: interrupt an import
process during preparation and during file activation using the lab harness. Then:

```bash
bash smtp-oauth-deploy.sh status
bash smtp-oauth-deploy.sh recover-import --yes
bash smtp-oauth-deploy.sh status
bash smtp-oauth-deploy.sh test --recipient operator@example.com
```

Pass: an interruption is diagnosed, recovery restores the previous known-good
credentials, status succeeds and sending works. The automated mock tests also check
that recovery failure retains its pending marker. Do not kill random production
processes or edit the recovery manifest to simulate this.

6. With submissions paused and the queue empty:

```bash
postqueue -p
bash smtp-oauth-deploy.sh uninstall --yes
systemctl is-active postfix
postconf -n
```

Pass: prior recorded settings and prior service state restored; managed state,
credential maps and token directory removed; queue and packages preserved. Compare
to the baseline captured before installation. A previously stopped service should
be stopped again. Inspect SELinux AVCs throughout (`ausearch -m AVC -ts recent`);
unexplained denials are a failure, not a reason to set permissive mode.

## Business Basic trial lab — selected route

Use a **Microsoft 365 Business Basic one-month trial** for live QA. Start it only
after the matching EL package is ready, so packaging delays do not consume trial
days. Local compilation/mocked tests on an existing Linux VM require no subscription.
A payment card is required for the trial; it becomes paid automatically unless
recurring billing is disabled. We do not create accounts or start a purchase for you.
See Microsoft's [trial and cancellation guide](https://learn.microsoft.com/en-gb/microsoft-365/commerce/try-or-buy-microsoft-365?view=o365-worldwide).

On your **workstation browser**, as the test tenant administrator:

1. Select the Business Basic trial and complete tenant provisioning. Use the supplied
   `yourlab.onmicrosoft.com` domain; there is no need to buy or connect a domain.
2. In **Billing > Your products**, select the trial and turn **recurring billing OFF**.
   Verify that renewal is disabled, record the expiry date, and retain the confirmation.
3. In **Users > Active users**, create `relay@yourlab.onmicrosoft.com` and assign a
   Business Basic license with Exchange Online enabled. Wait for its mailbox to be
   provisioned. Use your own approved inbox as the QA recipient.
4. Complete the application registration, secret and mailbox-scoped RBAC procedure
   above in this **test tenant**. Record the tenant/application IDs, Enterprise
   Application object ID, secret value and secret expiry. No sending-mailbox login
   is needed for this application-only candidate. The administrator still signs in.
5. Confirm approved SMTP AUTH policy. If the trial tenant's security baseline blocks
   it, stop and resolve the design/policy with the administrator; do not disable
   tenant-wide Security Defaults simply to make the test pass.

Download the matching unsigned QA artifact from a successful exact-commit Actions
run as described above, and verify its provenance and checksums. Do not compile
on the client VM. On the **Linux test VM**, use only CLI commands. Follow the deployment steps above's matching RPM and
OS prerequisite installation, then prepare the private JSON:

```bash
install -d -m 700 /root/smtp-oauth
install -m 600 m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh status
```

Enter `relay@yourlab.onmicrosoft.com`, the trial tenant GUID, application GUID and
secret **value** in the JSON. Pass evidence: `check` reports credential structure and
local prerequisites passed; `install` reports application token request passed and
installed; `status` exits 0. An empty cache before the first SMTP authentication is
normal. Keep credentials off command lines and out of support transcripts.

Run walkthrough steps 1–6 above for actual sending, native reacquisition, reboot,
failed credentials/network, interrupted import recovery and uninstall. Record exit
codes and queue IDs; native/mock tests are separate from live SMTP evidence. Remove
unused test application credentials through the tenant administrator after QA, and
recheck recurring billing is off before leaving the trial.

This is a time-limited **commercial Microsoft 365 lab**, not a permanent free tenant
or an exact replica of every managed tenant. It tests the app-only candidate; final
acceptance still requires the intended sending tenant and its approved permissions.
Personal Outlook.com is not an equivalent lab.
