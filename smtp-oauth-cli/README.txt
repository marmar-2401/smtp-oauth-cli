MICROSOFT SMTP OAUTH 2.1.0

Local Postfix relay for Outlook.com or Microsoft 365 / Exchange Online.
Targets RHEL, Oracle Linux and AlmaLinux 8, 9 and 10; validate your host before
production. Run as root in Bash, one command at a time. Stop on errors.
One sending mailbox; applications submit to 127.0.0.1:25.


1. PREPARE LINUX

Use a standard, dedicated Postfix host with IPv4/IPv6 loopback, working DNS,
correct time, and outbound TCP 443/587.

Enable approved EPEL/dependency repositories for your distribution.
AlmaLinux 9 lab example:

dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y epel-release

Then install the required packages:

dnf install -y postfix sasl-xoauth2 cyrus-sasl jq curl ca-certificates policycoreutils-python-utils iproute util-linux

sasl-xoauth2 must be version 0.24 or newer.


2. DOWNLOAD AND CHECK

umask 077
install -d -m 700 /root/smtp-oauth-microsoft
cd /root/smtp-oauth-microsoft
curl -fL https://raw.githubusercontent.com/marmar-2401/smtp-oauth-cli/main/smtp-oauth-cli/smtp-oauth-deploy.sh -o smtp-oauth-deploy.sh
bash smtp-oauth-deploy.sh check

Continue only after "Local prerequisites passed".
Step 4 tests authorization and delivery.


3. AUTHORIZE THE SENDING MAILBOX

For M365, enable Authenticated SMTP at https://admin.microsoft.com/ > Users
> Active users > sender > Mail > Manage email apps. Tenant policy must allow
SMTP OAuth; Security Defaults can block it. Ask the administrator to resolve
policy restrictions.

Already have credentials?
Download the matching outlook-client-template.json or m365-client-template.json
from this repo, fill it in, and securely save it as
/root/smtp-oauth-microsoft/client.json. Continue at step 4.
Use UTF-8 and replace every placeholder with the matching app/mailbox REFRESH
token and IDs. Public clients leave client_secret empty; confidential grants
need the matching secret VALUE. For M365, tenant is the Directory tenant GUID.

New authorization requires Entra app-registration rights; a personal Outlook
account alone does not provide them. M365 also needs a licensed Exchange
Online mailbox.

On your PC, open https://entra.microsoft.com/:
- App registrations > New registration. Name it SMTP OAuth.
- Choose Personal Microsoft accounts only for Outlook.com, or Single tenant
  for Microsoft 365. Leave Redirect URI empty.
- Register and copy the Application (client) ID. For M365, also copy the
  Directory (tenant) ID.
- Under Authentication, enable Allow public client flows and save.
- API permissions > Add a permission > Microsoft Graph > Delegated permissions:
  add SMTP.Send and offline_access. Obtain any required administrator consent.
- Do not create a client secret for this public-client flow.

Back on Linux, choose m365 or outlook:

read -r -p 'Provider (m365 or outlook): ' provider
bash smtp-oauth-deploy.sh authorize --provider "$provider" --output /root/smtp-oauth-microsoft/client.json

Enter the requested IDs and sending mailbox. Leave the terminal open.
On your PC, open the displayed Microsoft URL, enter its code, and sign in
as the SENDING mailbox. The script saves client.json directly.

Device-code sign-in must be allowed. Existing files are preserved; choose
a new filename and use that path throughout.


4. INSTALL AND TEST

Pause application mail submissions. The queue must be empty before installing.
Do not install over an existing managed relay.

chown root:root /root/smtp-oauth-microsoft/client.json
chmod 600 /root/smtp-oauth-microsoft/client.json
postqueue -p
bash smtp-oauth-deploy.sh install --config /root/smtp-oauth-microsoft/client.json --yes
read -r -p 'Test recipient address: ' recipient
bash smtp-oauth-deploy.sh test --recipient "$recipient" --force-refresh --yes
bash smtp-oauth-deploy.sh status

Require both a token-file update reported as "observed" and "RELAY ACCEPTED".
Then confirm the message arrived in the recipient's inbox or junk folder.
The forced-refresh test briefly restarts Postfix.

No cron job: tokens refresh when mail is sent. Test the application using
an authorized sender; the script does not rewrite addresses.


5. MANAGE THE RELAY

For later sessions, return to the working folder:
cd /root/smtp-oauth-microsoft

Check status:
bash smtp-oauth-deploy.sh status

Send another test:
read -r -p 'Test recipient address: ' recipient
bash smtp-oauth-deploy.sh test --recipient "$recipient" --yes

Replace authorization for the SAME provider, mailbox and tenant:
Create replacement.json using step 3, then run:
chown root:root /root/smtp-oauth-microsoft/replacement.json
chmod 600 /root/smtp-oauth-microsoft/replacement.json
bash smtp-oauth-deploy.sh import-token --config /root/smtp-oauth-microsoft/replacement.json --yes
Repeat the forced-refresh test from step 4.

Remove the relay or change provider, mailbox or tenant:
Pause submissions and resolve queued mail, then run:
bash smtp-oauth-deploy.sh uninstall --yes

Removal restores prior managed settings and service state. It leaves input
JSON, queued mail, packages and Microsoft consent in place. To switch accounts,
authorize a new configuration filename, then install using that file.


IF SOMETHING FAILS

Read the reported error and stop. Check the queue and delivery logs:

postqueue -p
journalctl -b -t postfix/smtp --no-pager -n 50

If the journal is empty, check /var/log/maillog. Match the test's queue ID.
For Microsoft errors, check the account, tenant, consent, SMTP AUTH and policy.
This release rejects OAuth credentials containing &, + or %; never edit
issued tokens. That limitation needs a qualified script/plugin update.
Preserve state files if recovery or configuration-drift errors are reported.

Keep credential JSON, token files and raw OAuth traces out of GitHub.
