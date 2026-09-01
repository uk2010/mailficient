# Troubleshooting

## Provider rate limits

If Mailficient reports that the mail server is busy, the provider has temporarily throttled connections or sending. Leave queued messages in Outbox and wait a few minutes; Mailficient keeps the draft and uses exponential retry delays rather than repeatedly contacting the provider. A throttled SMTP rejection is not shown as uncertain delivery because the provider explicitly refused that attempt.

If Mailficient reports **Some mail could not be updated**, successful folders and messages have already been saved. Older cached mail is retained for every folder whose server inventory could not be completed. Expand Technical Details to identify the affected folder, then choose Get Mail to retry; do not remove and re-add the account.

## Legacy-data migration

When Mailficient finds a legacy `personal-mail` data directory and no current `mailficient` directory, it copies the legacy database and private files through an atomic staging migration. Saved draft and received-attachment paths are rewritten to their new location. If migration reports an error, the original legacy directory has not been replaced or deleted; correct the disk-space or permission problem and choose Try Again.

## Draft synchronization and background delivery

Mailficient presents one unified, editable **Drafts** favorite. Provider Drafts folders are synchronized into it and are intentionally hidden from account folder groups so the same provider message does not also appear as a raw read-only row.

If an imported draft shows **Not available locally** for an attachment, the provider part could not be cached within Mailficient's outgoing attachment limits or was unavailable during synchronization. The draft is intentionally blocked from sending so an attachment is never silently omitted. Remove the placeholder or obtain the file and reattach it before sending.

Native packages start a current-session background-delivery worker as soon as a configured account has durable work; their XDG autostart entry covers later logins. Flatpak asks for desktop Background permission after a real-account Draft or Outbox item first needs it and starts the worker only after the desktop grants that request. Demo data never prompts or starts a worker. If scheduled mail remains queued after its due time, check that Mailficient is allowed to run in the background in the desktop's application permissions, then launch Mailficient once to retry. Denying or disabling the permission does not lose the message: keep Mailficient open for a foreground check or launch it later. An item shown as **Sending in the background** is temporarily read-only because another process owns its delivery claim.

With **Undo Send** enabled under **Preferences → Compose**, the composer closes as soon as Send is clicked and a bottom-of-main-window **Undo Send** action remains for 5–30 seconds. No countdown is shown in the composer. Turning Undo Send off makes the click own an immediate foreground SMTP attempt. If the action has expired, check Outbox for the current **Preparing** or **Sending** state rather than editing the row during delivery.

## Calendar invitations

If an invitation shows **Open in Calendar to Respond** instead of **Accept**, **Tentative**, and **Decline**, first check the note beneath the card. Response buttons require a request that lists the exact configured address for that mail account and a build with EDS calendar support; cancellations and invitations addressed only to someone else are intentionally not actionable. For a native source build, install the libecal and libical development packages from the README and configure with `-Dcalendar=enabled`. The portable fallback still opens the original bounded `.ics` data in the registered desktop calendar and never claims that it recorded an RSVP.

If a direct response or **Create Meeting from Email** fails, make sure Evolution Data Server is running and GNOME Calendar has an enabled, writable default calendar. A read-only default must be changed in the calendar application. Flatpak builds also require the packaged `org.gnome.evolution.dataserver.Calendar8` session-bus permission; reinstall the checked manifest if a locally altered package omitted it. Snap's `calendar-service` interface does not auto-connect; connect it with `sudo snap connect mailficient:calendar-service` to enable direct EDS access, or continue with the safe **Open in Calendar** fallback.

If Today or Events says that GNOME Calendar events are unavailable, use a build with EDS calendar support and confirm at least one calendar is enabled. New Event also requires a writable default calendar. These views do not fall back to local mail-database tasks, so fixing EDS access is required for them to show or save events.

The response confirmation's **Send a response to the organizer** checkbox is independent of the calendar update. Leave it off to change only the calendar, or enable it to let EDS send the iTIP reply. Creating a meeting from an email always suppresses automatic invitation delivery: review the saved event in GNOME Calendar and send from there only if intended.

- If Meson cannot find GTK or Camel, install the development packages listed in the README, not only runtime libraries.
- If the window cannot connect to a display, launch from an active GNOME session or run interface smoke tests under Xvfb.
- If Secret Service is unavailable, start GNOME Keyring; do not fall back to plaintext credential files.
- A **Secure connection failed** warning means the server certificate could not be verified. Expand **Certificate Details**, confirm the configured hostname, and contact the provider if the name is correct. Do not bypass the warning or substitute an unencrypted port.
- Mailficient does not automatically cache an individual received attachment larger than 50 MB or more than 100 MB of attachments from one message. Its name and size remain visible; choose the download button to save it directly from the server. Explicit downloads are limited to 2 GB and require the original message to remain in the configured account.
- If Outbox says delivery could not be confirmed, check the provider's Sent mailbox before choosing **Send Again**. The previous SMTP attempt may have succeeded even though its final response was lost. Mailficient never retries this state automatically.
- **Sending…** means SMTP is active; it is not an unknown result. Only an item with a recorded transport-loss diagnostic is labeled uncertain. A dedicated outgoing connection prevents a large Inbox download or Get Mail cancellation from disconnecting SMTP.
- If Outbox says **Message was not sent**, a temporary server response or preparation failure kept it from submission. It remains queued and no duplicate-delivery confirmation is needed. If it says **Mail server rejected this message**, a permanent 5xx response has paused automatic retry; expand Technical Details, correct the recipient or message, and choose Try Again.
- Demo mode never contacts a server and is available without an account.
- If a compose window is closed, choose **Save Draft** to keep it in the unified Drafts mailbox and synchronize it to the configured provider. Draft attachments are private local copies and remain available after restart. **Discard** removes the database entry, its private copies, and the exact synchronized provider copy when one exists.
- Configure a separate plain-text signature for each sending identity from **Mailficient menu → Preferences → Composing**. Existing drafts retain their saved body and are not given a duplicate signature when reopened.
- Spell checking is entirely local. If only common typing errors are detected, install an Enchant or Aspell dictionary for the desktop locale, then reopen the composer. Disabling **Check spelling while typing** removes the underlines without changing message text.
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
