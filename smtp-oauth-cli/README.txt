MICROSOFT SMTP OAUTH 2.1.0 - QUICK START

Supports personal Outlook.com and Microsoft 365 / Exchange Online.
Run Linux commands as root in Bash. One mailbox is active at a time.

1. PREPARE LINUX

The host needs standard Postfix, IPv4/IPv6 loopback, correct time, working DNS,
and outbound HTTPS 443 plus SMTP 587. The application submits locally to
127.0.0.1:25. The script checks Enterprise Linux 8/9/10 capabilities.

For a clean AlmaLinux 9 lab, install:

dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y epel-release
dnf install -y postfix sasl-xoauth2 cyrus-sasl jq curl ca-certificates policycoreutils-python-utils iproute util-linux

On Oracle Linux/RHEL, use the client's approved repositories for these packages.
sasl-xoauth2 must be 0.24 or newer. Stop if any package command fails.

2. EXTRACT AND CHECK

Upload the archive to /root/SMTP_OAuth_Microsoft_v2.1.0.tar.gz, then run:

bash
umask 077
install -d -m 700 /root/smtp-oauth-microsoft
tar -xzf /root/SMTP_OAuth_Microsoft_v2.1.0.tar.gz --strip-components=1 -C /root/smtp-oauth-microsoft
chmod 700 /root/smtp-oauth-microsoft
cd /root/smtp-oauth-microsoft
sha256sum -c SHA256SUMS.txt
bash smtp-oauth-deploy.sh check

Expected: all checksums say OK and Local prerequisites passed.
Use this new folder for this version. Existing 2.0.x installations remain
manageable with status/uninstall; do not run install over an installed relay.

3. GET client.json - CHOOSE ONE ROUTE

M365 prerequisite for BOTH routes: admin.microsoft.com > Users > Active users
> sender > Mail > Manage email apps > enable Authenticated SMTP. Tenant policy
must also permit SMTP OAuth. Security Defaults can block it; the mailbox
checkbox alone is insufficient. Resolve that with the tenant administrator.

CLIENT ALREADY PROVIDED CREDENTIALS:
Have the client fill the matching outlook-client-template.json or
m365-client-template.json and securely provide it as:
/root/smtp-oauth-microsoft/client.json

Replace all REPLACE_WITH values. Use a REFRESH token issued to the matching
application and sending mailbox, not an access token or mailbox password.
For a Microsoft public client, client_secret stays empty. A supplied confidential
grant needs its matching secret VALUE. M365 tenant is the Directory tenant GUID.
Save as UTF-8. Skip the account setup below and continue at step 4.

NEW LAB / NO REFRESH TOKEN YET:
You need access to an Entra tenant where you can register an app. A personal
Outlook mailbox alone does not provide those rights. M365 additionally needs
a licensed Exchange Online mailbox that can already send through Outlook web.

On your PC, open https://entra.microsoft.com/:
- Entra ID > App registrations > New registration. Name: SCC SMTP OAuth.
- Accounts: Personal Microsoft accounts only for Outlook; Single tenant for M365.
- Leave Redirect URI empty. Register and copy Application (client) ID.
  For M365, also copy Directory (tenant) ID. Do not use Object ID.
- Authentication > Advanced settings > Allow public client flows = Yes; Save.
- API permissions > Add a permission > Microsoft Graph > Delegated permissions.
  Add SMTP.Send and offline_access. Obtain any required administrator consent.
- Create no client secret for this public-client lab.

For authorize, M365 tenant policy must also permit device-code sign-in.
A supplied grant skips this initial flow but cannot bypass an SMTP AUTH block.

Back in the Linux terminal, enter outlook or m365 at the first prompt:

read -r -p 'Provider (outlook or m365): ' lab_provider
bash smtp-oauth-deploy.sh authorize --provider "$lab_provider" --output /root/smtp-oauth-microsoft/client.json

Enter the client ID, sending mailbox and, for M365, tenant GUID when prompted.
Leave the terminal open. In your PC browser, open the displayed Microsoft URL,
enter its code and complete sign-in/MFA as the SENDING mailbox.

Expected: Created protected configuration: /root/smtp-oauth-microsoft/client.json
The script writes the JSON directly. The server needs no browser; approve the
sign-in on your PC.

4. INSTALL AND TEST

Pause application mail submissions for this change. Run each line separately;
stop if one fails. The queue must be empty before installing a different relay.

chown root:root /root/smtp-oauth-microsoft/client.json
chmod 600 /root/smtp-oauth-microsoft/client.json
postqueue -p
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth-microsoft/client.json --yes
read -r -p 'Test recipient address: ' test_recipient
bash smtp-oauth-deploy.sh test --recipient "$test_recipient" --force-refresh --yes
bash smtp-oauth-deploy.sh status

Require BOTH "token-file update ... observed" and "RELAY ACCEPTED", then confirm
the message arrived in the recipient's inbox/junk. The forced test briefly
restarts Postfix. A local queue ID alone does not prove delivery.

Normal access-token refresh is automatic when Postfix sends; no cron job is
needed. Test the real application's sender too: this script does not
rewrite From/envelope addresses; the provider must authorize the sender.

5. NORMAL COMMANDS

Status:
bash smtp-oauth-deploy.sh status

Send another test:
read -r -p 'Test recipient address: ' test_recipient
bash smtp-oauth-deploy.sh test --recipient "$test_recipient" --yes

Replace revoked/expired authorization for the SAME mailbox:
Obtain a new protected replacement.json using the same route as step 3.
Then run:
bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth-microsoft/replacement.json --yes
read -r -p 'Test recipient address: ' test_recipient
bash smtp-oauth-deploy.sh test --recipient "$test_recipient" --force-refresh --yes

Remove or switch providers:
Pause submissions, review/resolve queued mail, then run:
postqueue -p
bash smtp-oauth-deploy.sh uninstall --yes
Removal restores prior managed settings/service state. Input JSON and cloud
consent remain. For a different provider, use a new configuration filename and
supply that same filename to install --config.

IF SOMETHING FAILS

Package/DNS error: fix repository or network access before continuing.
Output file exists: use a new filename and use it in install --config too.
Microsoft asks for client_secret: recheck Allow public client flows for the lab app.
AADSTS/policy error: check the code, correct account/tenant, consent and tenant policy.
Token exchange passes but SMTP fails: check SMTP AUTH, sending mailbox and port 587.
Credentials contain &, + or %: the reviewed plugin cannot safely refresh them;
do not edit the issued values. Use a corrected and qualified plugin build.
Managed drift/recovery error: preserve the state files and review the reported
change; do not delete state to force past it. Older 1.x installs need their old
script's uninstaller first.

Useful checks:
postqueue -p
journalctl -b -t postfix/smtp --no-pager -n 50

If journal output is empty, check /var/log/maillog.
Use the queue ID from the test to find its logs. Never share client.json, token
files or raw OAuth traces. Refresh grants can be revoked or require a new
interactive sign-in even though routine access-token renewal is automatic.

Verified locally: Bash syntax; 27 deployment and 16 authorization test groups.
Live Microsoft sign-in, SMTP delivery and the actual client OS still need testing.

Official references:
https://github.com/tarickb/sasl-xoauth2
https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth
https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission
https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults
