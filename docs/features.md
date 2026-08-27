# Feature guide

## Browsing and bulk actions

Mailboxes and search results expose their complete logical result set and load lightweight summaries transparently in small pages as you scroll. Only a few pages remain in memory, and opening one message loads only that message's body and attachments. Initial synchronization likewise continues through bounded background sessions until all discovered history is cached; 250 messages is a per-session memory boundary, not an account limit. This keeps browsing bounded without hiding mail when an account contains tens of thousands of messages.

The message list follows normal desktop selection behavior: hold **Shift** while clicking to select a contiguous range, hold **Ctrl** to add or remove individual messages, use **Ctrl+A** to select every message in the current view, and press **Escape** to clear the selection. **J/K** navigate messages, while **E**, **I**, **R**, **F**, and **S** provide quick archive, read-state, reply, forward, and snooze actions.

Use the selection control above the list to enter multi-select mode, select the required rows, then apply Read/Unread, Flag, Archive, Junk, Move, or Delete once. Moving mail to Trash offers an **Undo** toast before the durable server operation is flushed. Deleting from Trash/Junk is permanent and requires confirmation. Right-click Trash or Junk in the sidebar to empty the complete server folder, also with confirmation.

The read-state action is context-aware: it says **Mark as Read** for unread selection and **Mark as Unread** for read selection. Marking a selected message unread keeps it unread until you move away and select it again.

## Message identity, headers, and mailing lists

The shield beside each message opens **Message Security** with the retained raw headers, bounded to 64 KiB, and any identity signals Mailficient can explain. A receiving-server SPF, DKIM, or DMARC failure, a different Reply-To or display-name domain, punycode, and a visible link label that opens another domain are surfaced conservatively. Passing authentication is context, not proof that a request, link, or attachment is safe. **Preferences → Safety** opens the separate searchable **Sender Lists** window; Safe Senders there load remote images automatically and hide the automatic sender-warning card. The complete assessment remains available from the shield, while link confirmation, attachment checks, and HTML restrictions stay active.

**Report Phishing** requires confirmation, removes the sender from Safe Senders, asks the configured provider to classify the message as junk, moves it to Junk, and retains the local sender block. This standard IMAP/Junk path does not claim to submit a separate report to a provider-specific abuse API.

For a standards-based `List-Unsubscribe` header, the reader offers **Unsubscribe…**. Only HTTPS and `mailto:` targets are accepted. Mailficient never follows a hidden one-click POST: it confirms first, then opens the secure web page, or prepares a reviewable unsubscribe draft. Plain HTTP, script schemes, control characters, invalid addresses, and oversized targets are ignored.

## Composition

The composer supports bold, italic, underline, strike-through, code, bulleted and numbered lists, links, normal attachments, and CID-backed inline images. Drafts preserve formatted HTML, the plain-text alternative, attachment metadata, and message-security choices. The single **Drafts** favorite is the editable view for every configured account: Mailficient mirrors each provider's Drafts folder into that view and does not expose a second raw, read-only Drafts mailbox under the account.

Spelling is checked while typing with the device's local Enchant/Aspell dictionary; a built-in common-correction fallback remains available in minimal sandboxes. Possible errors are underlined, and the spelling button offers local corrections or ignores a word for the current message. Message text is never sent to an online spelling service. Configure the feature under **Preferences → Composing**.

If the authored subject or body says that a file is attached or included but the message has no attachment, Send and Send Later ask whether to keep editing. Quoted replies and forwarded history do not trigger that reminder. **Preferences → Compose → Undo Send** can turn the feature off. When enabled, Send closes the composer and shows a bottom-of-main-window notification with an **Undo Send** button for the configured 5–30 second durable Outbox fence; no countdown remains in the composer. When disabled, Send begins its foreground SMTP attempt immediately. Activating a still-deferred Outbox item restores the same main-window action.

Conversation rendering follows mailbox intent: normal Inbox, Sent, and Archive conversations omit messages moved to Trash or Junk, while a conversation opened from Trash or Junk stays scoped to that discard mailbox. Deleted intermediate replies can still connect surviving thread members without being displayed themselves.

Edits made by another mail client are imported, including an edit that keeps the same IMAP UID. A local unsynchronized edit is never overwritten by a provider refresh. Explicitly discarding an imported draft removes its exact provider UID after verifying its Message-ID; a missing or mismatched message is not substituted by another copy. Provider attachments that cannot be cached within the outgoing safety limits remain visible as **Not available locally** placeholders and block sending until removed or reattached.

**Send later** offers one hour, four hours, tomorrow morning, or next week. Scheduled and retryable messages are durably claimed from Outbox by background delivery, including while the main window is closed. Native packages start one resident worker when real provider work is queued and install an XDG autostart entry for later logins. The Flatpak asks the desktop Background portal for permission when a real-account Draft or Outbox item first needs background work, then starts the current-session worker only after the portal confirms access. Demo and local-only queues never launch it or prompt. If permission is unavailable, the item remains safely queued for a foreground mail check or the next launch.

Choose **Contacts** beside the To field to open the GNOME Contacts picker; it initially lists up to 50 email contacts and can be narrowed with search. The Cc and Bcc fields have matching contact buttons when revealed. Recipient completion also searches enabled GNOME address books—including local GNOME Contacts and configured CardDAV sources—after two typed characters. Searches are asynchronous, cancellable, and bounded. Mailficient merges those contacts with cached correspondents, removes duplicates and the sending identity, and does not copy the complete system address book into its own database.

Use the template buttons at the bottom of the composer to save the current subject/body or insert a stored template. Templates are local to this Mailficient installation.

## Search, rules, Quick Steps, labels, and snooze

Search is local and private while you type. Use quoted phrases, uppercase `OR`, and a leading `-` to exclude a term. Available scopes include `from:`, `to:`, `cc:`, `bcc:`, `subject:`, `account:`, `folder:`/`mailbox:`, `label:`, `attachment:`/`filename:`, and `type:`. Status, date, and size filters include `is:unread`, `is:flagged`, `has:attachment`, `date:2026-08-25`, `after:`, `before:`, and `size:>10MB`.

Press **Enter** in Search to request older matches from the selected **Current Folder**, **Current Account**, or **All Mail** server scope. Remote search is explicit, cancellable, and capped at 200 downloaded messages across the request; matching candidates join the private local cache and are then evaluated by the complete query. Ordinary typing never starts a network search.

Open **Preferences → Rules** to build ordered local rules with multiple AND/OR conditions, exceptions, account scope, multiple actions, and **Stop processing**. Conditions cover sender and recipients, subject/body, mailbox, attachment name/state, message size, read state, and flag state. Actions can mark read/unread, flag/unflag, archive, trash, label, move, or copy. Reorder or disable rules, edit them, or choose **Run Now** for a bounded pass over at most 10,000 cached messages.

**Quick Steps** are named, reusable action sequences created on the same page and run against the current message selection from **More → Quick Steps**. They use the same durable local operations as rules, including multi-message read, flag, label, move, and copy workflows. Labels can also be created and applied directly to one or many selected messages; search with `label:Name`.

Open **Preferences → Smart Mailboxes** to save searches such as `is:unread has:attachment` or `from:alice@example.com after:2026-01-01`. Saved searches appear in the left column with live unread counts.

## Calendar invitations and meeting drafts

**Calendar** in Favorites opens GNOME Calendar. Mailficient remains mail-focused: Evolution Data Server and the desktop calendar remain the authoritative event store, with no second calendar database or embedded calendar view.

An inline `text/calendar` part or `.ics` attachment is parsed within strict input, line, component, and attendee limits. The reader presents its title, local time or all-day range, location, organizer, recurrence, description, cancellation state, and the account's current participation. If the organizer address differs from the email sender, a warning appears before any response action.

When the exact configured address for the message's account is an attendee, builds with EDS calendar support offer **Accept**, **Tentative**, and **Decline**. The confirmation dialog independently controls whether EDS sends an iTIP response to the organizer; turning it off updates only the default calendar. Unlisted identities cannot respond on another attendee's behalf. A build without direct EDS support says so and offers **Open in Calendar to Respond**, using a private, size-bounded temporary `.ics` file instead of pretending the response was saved.

Choose **Create Meeting from Email** beside the subject to prefill an event from the message sender, subject, and excerpt. Review its date, time, duration, title, and attendee before saving. With EDS support it is added to the default writable calendar and GNOME Calendar opens for final review; automatic iTIP delivery is explicitly disabled. The portable fallback opens a private `.ics` event draft in the registered calendar application. Neither path sends an invitation merely because an email was converted to a meeting.

Snooze removes selected mail from ordinary views until the chosen time and keeps it under the unified **Snoozed** mailbox meanwhile. Preferences contains per-account vacation-response dates, subject, and body. The responder skips no-reply senders and the account's own address, and records senders locally so each receives at most one response for the active period.

## Tasks and email follow-up

**Today** and **Planned** are available in Favorites even before an email account is added. Today includes every unfinished task due today or overdue; Planned shows the complete schedule. Use **New Task** to choose a due date, desktop reminder, and daily, weekly, monthly, or yearly recurrence. Completed tasks can be revealed, reopened, edited, or deleted from either view. Completing a recurring occurrence atomically records it and creates the next occurrence, so a crash cannot silently end the series.

Select an email and choose **More → Create Task from Message…** to create a linked follow-up. Mailficient flags the email while any linked task remains open, opens the original email from the task row, and clears the flag after the last linked task is completed or deleted. An existing open task is edited instead of creating an accidental duplicate. Ordinary flags remain lightweight markers and do not create tasks automatically.

Task data and reminder-delivery state are durable in Mailficient's local database. Reminders are checked on startup and once per minute while Mailficient is running; selecting one opens the exact task. The service exposes a provider-sync boundary, but this build does not claim EDS/CalDAV task synchronization: no task-capable libecal provider or authorized CalDAV/GOA account is currently wired. Local create, edit, recurrence, reminder, and email-link behavior do not depend on external credentials.

## Export and printing

Right-click a message or use its window actions to export standards-compatible `.eml`, export a paginated PDF, or print. EML export includes downloaded attachments and preserves a plain/HTML alternative. Remote attachments that have not been explicitly downloaded are not silently fetched by export.

## OpenPGP and S/MIME

Choose the security button at the bottom of the composer, select **OpenPGP** or **S/MIME**, then enable signing, encryption, or both. The optional identity accepts an OpenPGP key ID/email address or S/MIME certificate nickname; when blank, the sending address is used. Encryption includes To, Cc, Bcc, and the sender, while Bcc remains absent from message headers.

OpenPGP uses the normal GnuPG keyring and does not silently trust unknown keys or enable network key discovery. Every encryption recipient needs a usable public key, and signing needs the sender's private key.

S/MIME uses the NSS certificate database initialized for Mailficient under its private data directory. The selected identity must name a personal certificate with its private key, and every recipient needs an imported email certificate. For the Flatpak this database is normally `~/.var/app/com.local.Mailficient/data/mailficient/certificates`; a distribution's NSS tools (`pk12util` for a personal PKCS#12 identity and `certutil` for recipient certificates) can provision it. Mailficient never stores certificate passwords in its SQLite database.

Incoming supported encrypted messages are decrypted when the key is available, and signed messages are verified. A banner above the body reports verification/decryption status. Missing keys or invalid signatures remain message-local warnings and do not stop the rest of the account from synchronizing. Subjects and normal transport headers are outside MIME body encryption, so sensitive information should not be placed in the subject.
