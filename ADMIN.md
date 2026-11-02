# Administrator setup and release qualification

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

On each supported distribution/major version and architecture, build the RPM and
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

1. Follow README installation, then run:

```bash
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
ss -ltn 'sport = :25'
postqueue -p
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Pass: status exits 0, only `127.0.0.1:25` listens, both sends print `RELAY ACCEPTED`
with queue IDs, forced renewal reports a token-file update, and the recipient
confirms both messages. A queued ID alone is **not** a pass.

2. Reboot and check persistence:

```bash
reboot
# Reconnect, return to the approved checkout, then:
systemctl is-active postfix
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Pass: service active, status exit 0, native renewal and upstream acceptance observed.

3. Test bad credentials without destroying the working credential:

```bash
umask 077
jq '.client_secret="deliberately-invalid-qa-secret"' /root/smtp-oauth/client.json > /root/smtp-oauth/bad.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/bad.json --yes
echo "exit=$?"
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
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
  bash smtp-oauth-cli/smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/client.json --yes
echo "exit=$?"
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
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
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
bash smtp-oauth-cli/smtp-oauth-deploy.sh recover-import --yes
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com
```

Pass: an interruption is diagnosed, recovery restores the previous known-good
credentials, status succeeds and sending works. The automated mock tests also check
that recovery failure retains its pending marker. Do not kill random production
processes or edit the recovery manifest to simulate this.

6. With submissions paused and the queue empty:

```bash
postqueue -p
bash smtp-oauth-cli/smtp-oauth-deploy.sh uninstall --yes
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

On the **Linux test VM**, use only CLI commands. Follow README's matching RPM and
OS prerequisite installation, then prepare the private JSON:

```bash
install -d -m 700 /root/smtp-oauth
install -m 600 smtp-oauth-cli/m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
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
