# Microsoft 365 email from a Linux server

Applications send to `127.0.0.1:25`. Postfix forwards their email through Microsoft 365.
No browser or mailbox sign-in is needed on Linux.

Use a dedicated server and one sending mailbox. This supports commercial Microsoft 365
with a client secret, the application's private password. Target systems are AlmaLinux,
Rocky Linux, RHEL and Oracle Linux 8/9/10. **Test on your platform and sending tenant
before production; live testing and RHEL qualification are still pending.**

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

## 2. Download and copy the package

The special **`sasl-xoauth2-m365-cli` RPM is required**. The stock plugin cannot do this.

On your workstation, open [QA downloads](https://github.com/marmar-2401/smtp-oauth-cli/actions/runs/41494598629).
Under **Artifacts**, download a bundle matching your server, such as
`qa-alma-el9-x86_64` for AlmaLinux 9. Choose a package whose job passed.
Extract the ZIP and copy its contents to `/root/smtp-qa/` on Linux.

Or use GitHub CLI on your workstation (AlmaLinux 9 example):

```bash
gh run download 41494598629 --repo marmar-2401/smtp-oauth-cli --name qa-alma-el9-x86_64 --dir qa-el9
scp -r qa-el9/. root@YOUR_LAB_HOST:/root/smtp-qa/
```

Replace `YOUR_LAB_HOST` with your server. Downloads are unsigned lab packages and
expire after 30 days; a permanent release is pending. If missing, ask the maintainer.
Current bundles are x86_64; RHEL and aarch64 need separately validated packages.

## 3. Prepare Linux

Log in as **root**. Run all remaining Linux commands from this directory:

```bash
cd /root/smtp-qa
cat /etc/os-release
uname -m
dnf install -y postfix cyrus-sasl cyrus-sasl-lib cyrus-sasl-devel jq ca-certificates util-linux iproute policycoreutils policycoreutils-python-utils
```

Install the matching RPM. This example is for EL9 on x86_64; use `el8` or `el10`
for those versions. Do not install the `.src.rpm` file.

```bash
dnf install packages/sasl-xoauth2-m365-cli-0.28-1.smtpcli.el9.x86_64.rpm
```

The Linux team must allow DNS, correct system time, and outbound TCP **443** to
`login.microsoftonline.com` and **587** to `smtp.office365.com`.
If this server already relays mail, stop here and plan migration before replacing its plugin.

## 4. Fill in the private configuration

```bash
install -d -m 700 /root/smtp-oauth
install -m 600 m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
```

In `vi`, press `i` to edit. Replace each `REPLACE_WITH_...` value with the email
administrator's value. Keep the quotes and commas; leave `provider` as `m365`.
Use the secret **value**, not its ID. Press `Esc`, type `:wq`, then press Enter.
Keep this file private. Never paste its contents into logs or support tickets.

## 5. Check and install

```bash
bash smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-deploy.sh status
```

Continue only if each command succeeds. Expect `Local prerequisites passed`, then
`Installed`, and no errors from `status`. An empty token cache before the first send is normal.

## 6. Send two test messages

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

If sending fails, check the reported error and network access. Ask the email
administrator to check secret expiry, mailbox access and SMTP AUTH policy.
Do not disable TLS checks or SELinux to clear an error.

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

Expect `Removed. Prior settings/service restored.` Packages and tenant permissions remain.

## Manual QA checklist

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
4. Follow Microsoft's [SMTP Application RBAC instructions](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding):
   register the Exchange service principal using the Enterprise Application object ID,
   and assign **Application SMTP.SendAsApp** scoped to the sending mailbox.
   Use this RBAC route only; do not add the Entra `SMTP.SendAsApp` API permission.
5. Verify that this mailbox is in scope, other mailboxes are excluded, and SMTP AUTH
   is allowed by approved tenant policy. Supply the completed JSON securely.

If the tenant blocks this method, stop and agree another design. Do not disable
Security Defaults or weaken tenant-wide protection to make the script work.

## Lab: Microsoft 365 Business Basic trial

Start the one-month trial **after the Linux package is ready**. A payment card is
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

On Linux, follow steps 2–6 and the manual QA checklist. Use your own approved inbox
as the recipient. After QA, remove unused test credentials and recheck that renewal is off.

---
Main contains only this guide, the script and the JSON template.
[Maintainer source, license and tests](https://github.com/marmar-2401/smtp-oauth-cli/tree/maintenance/m365-build)
are kept separately; operators do not need them.
