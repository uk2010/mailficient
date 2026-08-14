# Feature guide

## Browsing and bulk actions

Mailboxes and search results load 100 lightweight summaries at a time. Use **Older** and **Newer** below the message list; opening one message loads only that message's body and attachments. This keeps browsing bounded even when an account contains tens of thousands of messages.

The message list follows normal desktop selection behavior: hold **Shift** while clicking to select a contiguous range, hold **Ctrl** to add or remove individual messages, use **Ctrl+A** to select every message in the current view, and press **Escape** to clear the selection. **J/K** navigate messages, while **E**, **I**, **R**, **F**, and **S** provide quick archive, read-state, reply, forward, and snooze actions.

Use the selection control above the list to enter multi-select mode, select the required rows, then apply Read/Unread, Flag, Archive, Junk, Move, or Delete once. Moving mail to Trash offers an **Undo** toast before the durable server operation is flushed. Deleting from Trash/Junk is permanent and requires confirmation. Right-click Trash or Junk in the sidebar to empty the complete server folder, also with confirmation.

## Composition

The composer supports bold, italic, underline, strike-through, code, bulleted and numbered lists, links, normal attachments, and CID-backed inline images. Drafts preserve formatted HTML, the plain-text alternative, attachment metadata, and message-security choices. **Send later** offers one hour, four hours, tomorrow morning, or next week; due messages leave Outbox during a subsequent configured mail check.

Choose **Contacts** beside the To field to open the GNOME Contacts picker; it initially lists up to 50 email contacts and can be narrowed with search. The Cc and Bcc fields have matching contact buttons when revealed. Recipient completion also searches enabled GNOME address books—including local GNOME Contacts and configured CardDAV sources—after two typed characters. Searches are asynchronous, cancellable, and bounded. Mailficient merges those contacts with cached correspondents, removes duplicates and the sending identity, and does not copy the complete system address book into its own database.

Use the template buttons at the bottom of the composer to save the current subject/body or insert a stored template. Templates are local to this Mailficient installation.

## Rules, labels, snooze, and vacation replies

Open **Preferences → Rules** to match Sender, Recipient, or Subject and mark read, flag, archive, trash, or apply a label to newly synchronized messages. Rules are local and run in their displayed order. Labels can be created and applied to one or many selected messages; search with `label:Name`.

Snooze removes selected mail from ordinary views until the chosen time and keeps it under the unified **Snoozed** mailbox meanwhile. Preferences contains per-account vacation-response dates, subject, and body. The responder skips no-reply senders and the account's own address, and records senders locally so each receives at most one response for the active period.

## Export and printing

Right-click a message or use its window actions to export standards-compatible `.eml`, export a paginated PDF, or print. EML export includes downloaded attachments and preserves a plain/HTML alternative. Remote attachments that have not been explicitly downloaded are not silently fetched by export.

## OpenPGP and S/MIME

Choose the security button at the bottom of the composer, select **OpenPGP** or **S/MIME**, then enable signing, encryption, or both. The optional identity accepts an OpenPGP key ID/email address or S/MIME certificate nickname; when blank, the sending address is used. Encryption includes To, Cc, Bcc, and the sender, while Bcc remains absent from message headers.

OpenPGP uses the normal GnuPG keyring and does not silently trust unknown keys or enable network key discovery. Every encryption recipient needs a usable public key, and signing needs the sender's private key.

S/MIME uses the NSS certificate database initialized for Mailficient under its private data directory. The selected identity must name a personal certificate with its private key, and every recipient needs an imported email certificate. For the Flatpak this database is normally `~/.var/app/com.local.Mailficient/data/mailficient/certificates`; a distribution's NSS tools (`pk12util` for a personal PKCS#12 identity and `certutil` for recipient certificates) can provision it. Mailficient never stores certificate passwords in its SQLite database.

Incoming supported encrypted messages are decrypted when the key is available, and signed messages are verified. A banner above the body reports verification/decryption status. Missing keys or invalid signatures remain message-local warnings and do not stop the rest of the account from synchronizing. Subjects and normal transport headers are outside MIME body encryption, so sensitive information should not be placed in the subject.
