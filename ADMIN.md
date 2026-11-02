# Administrator setup and release qualification

**NHSmail gate:** NHSmail supplies the intended sending mailbox. This generic
commercial Microsoft 365 configuration is not an approved NHSmail integration.
Obtain official NHSmail application registration/SMTP permission approval first;
a local client administrator may not have tenant-wide registration or role rights.
Do not execute the following tenant commands without the responsible tenant
administrator's authorization. If NHSmail permits only Graph application access
or delegated SMTP, this design needs a scope decision; do not substitute either
silently. No NHSmail policy or endpoint is inferred from third-party guidance. Public source
review did not confirm NHSmail approval of client_credentials/SMTP.SendAsApp:
**unverified, not declared unsupported**. Ask the NHSmail Local Administrator for
written confirmation of the approved app-only SMTP registration/permission route.
The supplied [6B article](https://6b.health/insight/integrating-with-nhsmail/) does not
establish that approval; its offline_access discussion concerns delegated access.
The [NHSmail backend application admin guide](https://support.nhs.net/knowledge-base/organisations-with-in-house-or-third-party-backend-applications-admin-guide/)
redirected to the support portal during review.

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
NHSmail compatibility is **pending** official application-only SMTP approval.
NHSmail supplies the sending mailbox. This build uses commercial Microsoft 365
endpoints; validate that endpoint and permission route with NHSmail first.

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

## Low-cost QA lab

Local compilation, mocked HTTP and deployment tests need no mailbox subscription
and can run free on an existing Linux VM. Real Exchange OAuth/SMTP testing needs a
licensed organizational test mailbox. Eligible members can use a Microsoft 365 E5
[Developer Program sandbox](https://learn.microsoft.com/en-us/office/developer-program/microsoft-365-developer-program-faq);
otherwise consider a time-limited Microsoft 365 Business Basic trial. Eligibility
and signup terms apply; personal Outlook.com is not an equivalent test tenant.
Microsoft's [current trial guide](https://learn.microsoft.com/en-gb/microsoft-365/commerce/try-or-buy-microsoft-365?view=o365-worldwide)
describes a 30-day trial that converts to paid renewal unless recurring billing is
turned off. Start the trial **after the package is ready** to preserve its test days.
No permanent free tenant or exact NHSmail replica is promised. A commercial lab
validates mechanics; final acceptance still requires the NHSmail sending tenant.
