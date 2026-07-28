# Troubleshooting

## Provider rate limits

If Mailficient reports that the mail server is busy, the provider has temporarily throttled connections or sending. Leave queued messages in Outbox and wait a few minutes; Mailficient keeps the draft and uses exponential retry delays rather than repeatedly contacting the provider. A throttled SMTP rejection is not shown as uncertain delivery because the provider explicitly refused that attempt.

If Mailficient reports **Some mail could not be updated**, successful folders and messages have already been saved. Older cached mail is retained for every folder whose server inventory could not be completed. Expand Technical Details to identify the affected folder, then choose Get Mail to retry; do not remove and re-add the account.

## Legacy-data migration

When Mailficient finds a legacy `personal-mail` data directory and no current `mailficient` directory, it copies the legacy database and private files through an atomic staging migration. Saved draft and received-attachment paths are rewritten to their new location. If migration reports an error, the original legacy directory has not been replaced or deleted; correct the disk-space or permission problem and choose Try Again.

- If Meson cannot find GTK or Camel, install the development packages listed in the README, not only runtime libraries.
- If the window cannot connect to a display, launch from an active GNOME session or run interface smoke tests under Xvfb.
- If Secret Service is unavailable, start GNOME Keyring; do not fall back to plaintext credential files.
- A **Secure connection failed** warning means the server certificate could not be verified. Expand **Certificate Details**, confirm the configured hostname, and contact the provider if the name is correct. Do not bypass the warning or substitute an unencrypted port.
- Mailficient does not automatically cache an individual received attachment larger than 50 MB or more than 100 MB of attachments from one message. Its name and size remain visible; choose the download button to save it directly from the server. Explicit downloads are limited to 2 GB and require the original message to remain in the configured account.
- If Outbox says delivery could not be confirmed, check the provider's Sent mailbox before choosing **Send Again**. The previous SMTP attempt may have succeeded even though its final response was lost. Mailficient never retries this state automatically.
- If Outbox says **Message was not sent**, a temporary server response or preparation failure kept it from submission. It remains queued and no duplicate-delivery confirmation is needed. If it says **Mail server rejected this message**, a permanent 5xx response has paused automatic retry; expand Technical Details, correct the recipient or message, and choose Try Again.
- Demo mode never contacts a server and is available without an account.
- If a compose window is closed, choose **Save Draft** to keep it in the local Drafts mailbox. Draft attachments are private local copies and remain available after restart. **Discard** removes both the database entry and those private copies.
- Configure a separate plain-text signature for each sending identity from **Mailficient menu → Preferences → Composing**. Existing drafts retain their saved body and are not given a duplicate signature when reopened.
- Recipient suggestions are local and private: type part of a cached sender's name or address in To, Cc, or Bcc, press **Down**, then **Enter**. Suggestions appear only after that correspondent exists in the local cache.
- Drafts and queued messages are stored in `$XDG_DATA_HOME/mailficient/mail.db` (normally `~/.local/share/mailficient/mail.db`). Passwords are never stored there.
- If the local database cannot be opened, Mailficient shows a recovery window instead of silently exiting. Review **Technical Details**, correct disk-space or file-permission problems, and choose **Try Again**. Mailficient does not automatically delete, rename, or replace `mail.db`; keep a copy before performing any manual recovery.
- To verify the packaged build, run `flatpak run --user com.local.Mailficient`. If it is missing, rebuild and install with the manifest in `packaging/`.
- A failed send remains visible in Outbox and retries after its backoff delay during background synchronization or after connectivity returns. Activate the Outbox row to edit or retry it; repeatedly pressing Send is not necessary.
- If Mailficient says an attachment changed, is missing, or is outside private storage, reopen the message from Outbox, remove that attachment, and add the current file again. The message has not reached SMTP, so this error does not require checking Sent for duplicate delivery.
- Invalid TLS certificates are rejected. Fix the server name, system time, or certificate chain; do not bypass the warning.
- Gmail or Outlook password rejection usually means the provider requires OAuth or an app password. On GNOME, add the identity in **Settings → Online Accounts**, enable Mail, and import it with **Accounts → Add from GNOME Online Accounts**. If it no longer appears or authorization expires, reconnect it in GNOME Settings and refresh Mailficient.
- If OpenPGP signing reports a missing secret key, confirm that the composer identity matches a key shown by `gpg --list-secret-keys`. Encryption also requires a trusted public key for every To, Cc, and Bcc address. Mailficient deliberately does not bypass GnuPG trust or fetch keys automatically.
- If S/MIME cannot find a certificate, confirm that the nickname entered in Message Security exists in Mailficient's NSS certificate database and includes a private key for signing. Recipient certificates must contain the corresponding email addresses. Certificate or key errors occur before SMTP, so the message remains safe in Outbox for correction.
