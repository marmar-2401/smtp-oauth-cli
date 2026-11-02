# Microsoft 365 SMTP relay — CLI only

Postfix accepts application mail at **127.0.0.1:25** and sends it through
`smtp.office365.com:587` with verified TLS and application-only OAuth.
This **application-only candidate** needs no mailbox login, device code, browser,
user refresh token or token daemon. It is not yet the selected NHSmail solution.
A delegated workflow can also run on a headless Linux server when authorization
occurs on a separate workstation; selecting that route requires provider and user
confirmation. The original 2.1.0 workflow remains in Git at commit
`4a3fbbd84a6b213a5c1fc4470580cd4a0da5798f`; these changes are isolated on a local branch.
The client’s administrator must authorize the application for one sending mailbox.
This release supports a **client secret**; certificate credentials, personal
Outlook.com and Gmail are outside this workflow.

**Qualification pending:** target platforms are RHEL, Oracle Linux and AlmaLinux
8/9/10. Local native and mocked tests do not certify those systems, SELinux or a
Microsoft tenant. The intended sender is an NHSmail mailbox. **NHSmail compatibility is unverified**
until its authorized administrators approve application-only SMTP and the exact
permission route. Generic Microsoft 365 support does not establish NHSmail support. Complete the checks in [ADMIN.md](ADMIN.md) before production. That guide includes
the selected Business Basic one-month trial lab; activate it after packaging is ready.

## 1. Obtain the approved package and configuration

Have the administrator complete [ADMIN.md](ADMIN.md) and securely supply the tenant
ID, application ID, sending mailbox and **secret value**, with its expiration date.
Build the separately named plugin RPM on an isolated matching EL builder using
[packaging/README.md](packaging/README.md). Stock sasl-xoauth2 cannot do this flow.
Use an approved, immutable release checkout; do not download and run mutable `main`
as root. Verify the approved RPM signature and checksum through your release process.

All following commands run as **root**, from the approved repository directory.
Install OS prerequisites from your approved repositories:

```bash
dnf install -y postfix cyrus-sasl cyrus-sasl-lib cyrus-sasl-devel jq curl ca-certificates util-linux iproute policycoreutils policycoreutils-python-utils
```

On an existing delegated installation, first pause submissions, drain its queue and
follow recovery below **before changing plugin packages**. The application RPM
conflicts explicitly with stock `sasl-xoauth2`; review the package replacement
transaction, including any dependents. This installer never removes packages.
Install the approved RPM (replace the example path with the actual artifact):

```bash
dnf install /root/releases/sasl-xoauth2-m365-cli-0.28-1.smtpcli.el9.x86_64.rpm
install -d -m 700 /root/smtp-oauth
install -m 600 smtp-oauth-cli/m365-client-template.json /root/smtp-oauth/client.json
vi /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh check --config /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh install --config /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
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
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Success requires queue-ID-matched upstream `status=sent`, not just local acceptance.
Confirm receipt separately. Configure your application to use **127.0.0.1, port 25**,
with the approved mailbox as sender. Local submissions need no SMTP credentials.
Other local users can also submit mail; use a dedicated trusted server.

## 3. Replace an expiring secret or recover

Before expiry, obtain an approved replacement secret, update the protected JSON,
then run:

```bash
bash smtp-oauth-cli/smtp-oauth-deploy.sh import-token --config /root/smtp-oauth/client.json
bash smtp-oauth-cli/smtp-oauth-deploy.sh test --recipient operator@example.com --force-refresh
```

Keep the previous secret valid until verification succeeds. The application obtains
new access tokens on demand; Postfix retains failed mail for its ordinary queue retry.
No timer is required. Monitor the queue, service health and **client secret expiry**.

```bash
bash smtp-oauth-cli/smtp-oauth-deploy.sh status
postqueue -p
bash smtp-oauth-cli/smtp-oauth-deploy.sh recover-import
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
bash smtp-oauth-cli/smtp-oauth-deploy.sh uninstall
```

Uninstall restores prior managed settings and service state; it preserves packages,
the mail queue and tenant authorization. Pause submissions and drain the queue before
migration/removal so queued mail is not sent using restored settings. Review retained
private backups and revoke unused secrets through the administrator after success.
