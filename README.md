# Microsoft 365 email from a Linux server

Applications send to `127.0.0.1:25`. Postfix forwards their email through Microsoft 365.
No browser or mailbox sign-in is needed on Linux.

Use a dedicated server and one sending mailbox. This supports commercial Microsoft 365
with a client secret, the application's private password. Target systems are AlmaLinux,
Rocky Linux, RHEL and Oracle Linux 8/9/10. Use the QA checklist for your server and
mailbox; live Microsoft sending and RHEL testing remain to be completed.

## 1. Ask the client email administrator

Copy this into the setup request:

> Please provide:
> 1. The sending mailbox address.
> 2. Confirmation that application-only OAuth SMTP sending is allowed without mailbox sign-in.
> 3. A completed `m365-client-template.json`, sent through our secure channel. Your email administrator supplies the tenant ID, application ID and secret, and grants mailbox access. Do not paste secrets into the task.
> 4. An email administrator contact, test recipient, and owner for renewing the secret before expiry.
>
> Your email team handles Microsoft permissions. Our Linux team handles server networking and Postfix.
> If application-only SMTP is not allowed, tell us before setup.

## 2. Clone the repository

As **root**, on the Linux server:

```bash
git clone https://github.com/marmar-2401/smtp-oauth-cli.git /root/smtp-oauth-cli
cd /root/smtp-oauth-cli
install -d -m 700 /root/smtp-oauth
install -m 600 m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
```

In `vi`, press `i`. Replace each `REPLACE_WITH_...` value with the email
administrator's value. Keep the quotes and commas; leave `provider` as `m365`.
Use the secret **value**, not its ID. Press `Esc`, type `:wq`, then press Enter.
Keep this file private; never paste it into support tickets.

## 3. Install

```bash
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh status
```

The installer asks before installing dependencies and building the custom OAuth
plugin from pinned, hash-checked source. It builds and tests a native RPM as a
temporary unprivileged user, then installs it with DNF. No GitHub Actions,
release downloads, manual compilation, or GitHub login are needed. First install
requires HTTPS access to `raw.githubusercontent.com` and `codeload.github.com`.

The installer checks repository health and exact dependency availability before
building. If required repositories are disabled, it shows their names and asks
separately before enabling them. `install --yes` does not approve repository changes.
You can check first without installing packages or changing repository configuration:

```bash
bash smtp-oauth-deploy.sh repos
# Review and approve repository setup if the check reports missing dependencies:
bash smtp-oauth-deploy.sh repos --setup
```

EL8/9 use PowerTools/CRB (Oracle/RHEL CodeReady Builder) plus EPEL for
`jsoncpp-devel`; Oracle uses its own EPEL release package. EL10 needs CRB/CodeReady
Builder for that package, **not EPEL**. Existing approved mirrors are accepted when
they supply the packages. Missing vendor definitions, RHEL registration/content
access, exclusions and broken network/metadata require the Linux administrator;
the diagnostic distinguishes these from missing packages. Repository changes remain
after uninstall. No cross-distribution OS repositories or security overrides are added.
Local RPMs are unsigned; hosts requiring signed local packages need an approved
signing process. Signature policy is not bypassed.

Repository references: [Fedora EPEL](https://docs.fedoraproject.org/en-US/epel/getting-started/),
[Rocky](https://docs.rockylinux.org/10/teams/rel_eng/repo/),
[AlmaLinux](https://wiki.almalinux.org/repos/Extras.html),
[Oracle](https://yum.oracle.com/getting-started.html), and
[Red Hat EL10 package manifest](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/package_manifest/index).

Automatic builds are limited to x86_64 on the listed EL versions and build natively
for the detected host. An already installed matching custom `sasl-xoauth2-m365-cli`
package skips compilation and must pass integrity/capability checks. Stock
`sasl-xoauth2` is not interchangeable; an existing plugin or relay needs a planned
migration first.

Compiler/development packages remain installed. Source RPMs, the license, build
logs and provenance are retained in root-only `/var/lib/smtp-oauth-cli-builds`.
A failed build leaves these installed dependencies but does not configure the relay.

Expect `Installed` and no errors from `status`. An empty token cache before the
first send is normal. Run later commands from `/root/smtp-oauth-cli`.
The Linux team needs working DNS, correct time, and outbound TCP 443 to
`login.microsoftonline.com` and TCP 587 to `smtp.office365.com`.

## 4. Send two test messages

Replace `operator@example.com` with your approved test recipient. Confirm the prompts.

```bash
bash smtp-oauth-deploy.sh test --recipient operator@example.com
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Both must print **`RELAY ACCEPTED`** with a queue ID. The recipient must confirm both
messages arrived. The second test obtains a new access token.

Configure your application on this same server:

| Setting | Value |
|---|---|
| SMTP server | `127.0.0.1` |
| Port | `25` |
| SMTP username/password | None |
| From address | The configured sending mailbox |

The local connection needs no login; Postfix handles OAuth and verified TLS upstream.
Applications on other servers cannot connect to this localhost-only relay.

## Everyday commands

**Check service and queued mail:**

```bash
bash smtp-oauth-deploy.sh status
postqueue -p
journalctl -u postfix --since '10 minutes ago' --no-pager
```

If installation or credential import fails, the installer now identifies the stage:
local file/helper access, TLS/network, token endpoint HTTP/recognized Entra errors,
or native-helper failure after a separate successful token request. It never prints
secrets, tokens or raw server responses. A successful website/HEAD check does not
validate a token POST. Existing relay credentials are preserved on candidate failure.

If needed later, repeat the same protected configuration check without changing
Postfix or its active credentials:

```bash
bash smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
```

This checks native token acquisition. On helper failure it makes one additional,
bounded token POST to classify the failure; it never activates the diagnostic token.
Only `test` verifies SMTP authorization and delivery acceptance. For an SMTP failure,
the email administrator checks the selected authorization route, sender permissions
and SMTP AUTH policy. Do not disable TLS checks or SELinux to clear an error.

**Replace an expiring secret:** ask the administrator for a replacement, edit the
private JSON, then run these commands. Keep the old secret valid until the test passes.

```bash
vi /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

**Recover an interrupted credential import:**

```bash
bash smtp-oauth-deploy.sh recover-import
bash smtp-oauth-deploy.sh status
```

If recovery fails, retain `/var/lib/smtp-oauth-cli` and resolve the reported error.

**Uninstall:** stop application submissions first. Wait for `Mail queue is empty`.

```bash
postqueue -p
bash smtp-oauth-deploy.sh uninstall
```

Expect `Removed. Prior settings/service restored.` Packages, build records and tenant permissions remain.

## Manual QA checklist

The custom plugin is maintained from pinned upstream source, not vendor-certified.
Earlier container builds passed for Alma/Rocky/Oracle 8/9/10 x86_64; the automatic
on-server build path still needs platform acceptance. Direct RHEL, live Microsoft
sending, reboot and SELinux validation remain required. No aarch64 build support
is claimed. Source pins reproduce inputs, not necessarily byte-identical RPMs.

Use a disposable test server. Record the OS version and results for each platform.

- [ ] Install, check status, and confirm only `127.0.0.1:25` listens (`ss -ltn 'sport = :25'`).
- [ ] Run both send tests above; confirm receipt and token renewal.
- [ ] Reboot, then repeat status and the renewal/send test.
- [ ] Import a separate JSON copy with an invalid secret: import must fail and the working setup must still send.
- [ ] Simulate a network failure in the lab: mail must stay queued. Restore connectivity, run `postqueue -f`, and confirm delivery of the queued message.
- [ ] Interrupt an import on a disposable VM snapshot; `recover-import` must restore working sending.
- [ ] With SELinux enforcing, check `ausearch -m AVC -ts recent` for unexplained denials. Check logs contain no secrets.
- [ ] Uninstall with an empty queue; confirm the previous Postfix settings and service state return.

## Email administrator: Microsoft setup

These steps belong to the **email administrator**, using their workstation.
The Linux operator only needs the completed JSON.

1. In **Entra admin center > App registrations > New registration**, create a
   single-tenant application. Record its application ID and directory/tenant ID.
2. Open **Certificates & secrets > Client secrets > New client secret**. Record
   its value, expiry date and renewal owner.
3. Open **Enterprise applications**, select the application, and record its object ID.
   This is different from the App Registration object ID.
4. Register the Exchange service principal using the Enterprise Application object ID.
   Choose **one administrator-approved authorization route**:
   - **Entra application permission route:** grant Exchange Online `SMTP.SendAsApp`
     application permission and tenant admin consent, then grant the Exchange service
     principal access to the intended mailbox. Follow Microsoft's
     [client-credentials instructions](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth),
     including its SendAs requirement for the sender. FullAccess is not a substitute
     for SendAs. Restrict grants to the approved mailbox; these are application
     permissions, not a mailbox user's interactive login.
   - **Scoped Application RBAC route:** follow Microsoft's
     [SMTP RBAC instructions](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding)
     to assign `Application SMTP.SendAsApp` with a mailbox resource scope. This route
     does not require mailbox FullAccess or the Entra `SMTP.SendAsApp` claim.
     Microsoft warns that including that claim triggers mailbox permission checks;
     do not assume an RBAC scope restricts grants made through the other route.
5. Verify effective access to the intended sender and exclusion of other mailboxes,
   then check that SMTP AUTH is allowed by approved tenant policy. A failed RBAC
   assignment is not a completed RBAC configuration. Do not change routes or remove
   existing grants without the email administrator's approval.

Both routes use the same tenant-specific client-credentials token request and
`https://outlook.office365.com/.default` scope. Token acquisition and SMTP mailbox
permission are different stages: neither FullAccess nor a role assignment proves
that the client secret works, and obtaining a token does not prove permission to send.
NHSmail tenant approval has not been verified.

If the tenant blocks this method, stop and agree another design. Do not disable
Security Defaults or weaken tenant-wide protection to make the script work.

## Lab: Microsoft 365 Business Basic trial

Start the one-month trial **after the Linux installation prerequisites are ready**. A payment card is
required; turn off renewal to avoid charges. See Microsoft's [trial guide](https://learn.microsoft.com/en-gb/microsoft-365/commerce/try-or-buy-microsoft-365?view=o365-worldwide).

On your workstation, as the lab's email administrator:

1. Create the Business Basic trial tenant. Use its `yourlab.onmicrosoft.com` domain;
   you do not need to buy a domain.
2. In **Microsoft 365 admin center > Billing > Your products**, select the trial
   and turn **recurring billing OFF**. Record the expiry date.
3. In **Users > Active users**, create `relay@yourlab.onmicrosoft.com` and assign
   a Business Basic license with Exchange Online enabled. Wait for the mailbox.
4. Complete the email-administrator steps above and fill in the JSON for this mailbox.
5. Check SMTP AUTH policy before proceeding. Business Basic does not guarantee
   this flow is allowed: if Security Defaults blocks SMTP AUTH, stop for an
   administrator-approved solution. Do not turn it off just for testing.

On Linux, follow steps 2–4 and the manual QA checklist. Use your own approved inbox
as the recipient. After QA, remove unused test credentials and recheck that renewal is off.

---
Main contains only this guide, the script and the JSON template.
[Maintainer source, license and tests](https://github.com/marmar-2401/smtp-oauth-cli/tree/maintenance/m365-build)
are kept separately; operators do not need them.
