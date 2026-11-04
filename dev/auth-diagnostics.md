# Token pipeline investigation — 2026-11-04

The reported AlmaLinux 10.2 failure happened after RPM installation, during
candidate validation, before relay activation. The old error grouped local file
access, helper execution/configuration, timeout, transport, Microsoft rejection,
and malformed/unsupported response together. It did not establish a bad secret.
The native app-only implementation intentionally suppresses response details.

No lab credentials or tenant/server access were available. The actual lab cause
therefore remains unknown. The request endpoint, form encoding and scope match
Microsoft's documented client-credentials exchange. A HEAD request checks neither
this POST nor its credentials. SMTP mailbox grants are a separate later stage.

## Changes

Preflight now checks postfix access to staged configuration, CA and runtime files,
then runs the real helper in configuration-only mode before token acquisition.
Execution uses an explicit working directory independent of /root. The helper
watchdog allows its bounded lock/request windows and kills overdue processes.

If token acquisition fails, one bounded curl POST uses the same credentials,
endpoint, CA and scope as postfix. The form and response are protected files, not
argv or terminal data. No redirects or TLS bypass are allowed. Responses are size
bounded. Output consists only of fixed categories, a validated HTTP status or
recognized AADSTS codes; raw body/descriptions/headers/identifiers are never shown.
A successful diagnostic token never substitutes for the native helper or becomes
active. Temporary files are removed, and failed candidate validation cannot reach
snapshot/cutover. Existing relay credentials remain unchanged.

A separate successful POST establishes only that those credentials worked at that
moment; it does not prove why the helper failed (including a transient failure).
Recent helper SELinux audit events are reported only as a lead, never a diagnosis.
`check --config` provides the same safe native acquisition check without changing
Postfix or active credentials. The existing check without a config remains local.

## Evidence and tests

- Native plugin compilation and all three existing CTest cases passed; existing
  deployment regression tests and ShellCheck passed.
- The actual built helper ran as postfix from a mode-700 /root directory using the
  original invocation as well as the explicit-working-directory invocation. It
  loaded staged configuration successfully. A test-only LD_PRELOAD shim intercepted
  curl_easy_perform and proved that original invocation reached the HTTP stage
  after reading/locking the protected cache. No real network request was permitted.
  Thus the /root traversal hypothesis did not reproduce in this Linux container.
- Disposable integration tests used real user switching and file permissions,
  the native helper, a network-denying shim and a mock curl response. They verified
  request encoding/file access, recognized-error redaction, cleanup, unreadable CA,
  execution failure, and that failed installation does not snapshot/activate or
  overwrite existing credentials.
- Classifier tests cover DNS/connection/TLS/timeouts/local I/O, redirects, throttling,
  server errors, successful/malformed token responses, recognized and malformed
  error codes, and malicious secret/token/identifier canaries. No canary was output.
- SELinux enforcement was unavailable in these containers. Audit classification
  was mocked; real AlmaLinux SELinux contexts remain unverified. No Microsoft token
  or SMTP request, tenant change, lab deployment or credential access was performed.

`auth-diagnostics.sh` runs classifier tests by default. Native mode is restricted
to an explicitly disposable Docker container (`SMTP_DISPOSABLE_TEST=1`), with a
built `NATIVE_HELPER` and `NATIVE_HTTP_SHIM` compiled from `no-network.c` using
`cc -shared -fPIC`. It creates a postfix user and installs a mock curl inside that
disposable container; never run native mode on a client server.

Microsoft routes are documented separately in the README:
[Entra consent/mailbox route](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
and [Application RBAC route](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding).
A failed role assignment does not configure RBAC, but does not diagnose token
issuance failure for the Entra-consent route either. No permission changes are made
by this installer.
