# Mailficient

Mailficient is a native Vala, GTK4, Libadwaita, WebKitGTK, libsecret, SQLite, and Evolution Data Server/Camel desktop email client. Normal first launch opens account onboarding; realistic local demo data is confined to the automated development and visual-QA environment.

## License

Mailficient is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version. See [LICENSE](LICENSE).

## Development

The latest installed application can be launched with:

```sh
flatpak run --user com.local.Mailficient
```

The checked development launcher builds inside GNOME SDK 49 and runs the native
binary on the host desktop:

```sh
tools/run-dev.sh
```

Do not launch the binary from inside `flatpak run org.gnome.Sdk`; the SDK
sandbox cannot own the application's `com.local.Mailficient` session-bus name.

Ubuntu dependencies:

```sh
sudo apt install valac meson ninja-build libgtk-4-dev libadwaita-1-dev libgee-0.8-dev libjson-glib-dev libwebkitgtk-6.0-dev libsecret-1-dev libcamel1.2-dev libebook1.2-dev libedataserver1.2-dev libsqlite3-dev libxml2-dev libssl-dev libcairo2-dev libpango1.0-dev
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
build/src/mailficient
```

Fedora equivalents include `vala`, `meson`, `ninja-build`, `gtk4-devel`, `libadwaita-devel`, `libgee-devel`, `json-glib-devel`, `webkitgtk6.0-devel`, `libsecret-devel`, `evolution-data-server-devel`, `sqlite-devel`, `libxml2-devel`, and `openssl-devel`.

Without host development packages, use GNOME Builder or a GNOME SDK shell. The Flatpak manifest builds Evolution Data Server 3.60.2 from its checksum-pinned official source and enables the conditional Camel adapter.

## Flatpak package

Download the Flatpak for your architecture from the
[v0.2.4 GitHub release](https://github.com/uk2010/mailficient/releases/tag/v0.2.4),
then install and run it with:

```sh
flatpak install --user ./Mailficient-0.2.4-x86_64.flatpak
flatpak run --user com.local.Mailficient
```

The complete application source, tests, icons, metadata, and pinned Flatpak
manifest are in this repository. See [the Flatpak build guide](docs/flatpak.md)
for a clean source build and bundle instructions.

## Snap packages (AMD64 and ARM64)

The Snapcraft manifest builds native `amd64` and `arm64` packages. On a
64-bit ARM Ubuntu system, build and install it with:

```sh
sudo snap install snapcraft --classic
snapcraft --platform arm64
sudo snap install --dangerous ./mailficient_0.2.4_arm64.snap
sudo snap connect mailficient:password-manager-service
snap run mailficient
```

From an AMD64 development machine, an ARM64 package can instead be built on a
Launchpad ARM machine. The project must first be in a Git repository because
the remote builder uploads the committed source:

```sh
snapcraft remote-build --build-for=arm64 --launchpad-accept-public-upload
```

The password-manager connection is required for libsecret credential storage;
Snap installations do not auto-connect that sensitive interface. The Snap has
its own application data directory, so accounts and cached mail from a Flatpak
installation are not imported automatically.

## Debian packages (Ubuntu 26.04 AMD64 and ARM64)

The Debian-package builder produces a native host package that does not require
Flatpak after installation. It uses Ubuntu's GTK, Libadwaita, WebKitGTK, and
libsecret runtime libraries while privately bundling the matching Camel mail
engine used by the qualified application build:

```sh
tools/build-deb.sh
sudo apt install ./dist/mailficient_0.2.4-1_$(dpkg --print-architecture).deb
mailficient
```

The resulting package is intended for Ubuntu 26.04 on AMD64 or ARM64. Building it
requires the GNOME 49 SDK and the checked Camel-enabled build artifacts; these
are already present in the documented Flatpak development environment.
The builder also writes a matching `.deb.sha256` checksum for release uploads.

## Status

The complete feature roadmap is implemented: bounded page-by-page browsing and search; multi-selection and bulk actions; recoverable Trash moves plus confirmed permanent deletion and Empty Trash/Junk; rich composition with formatting, links, lists, inline images, and attachments; local rules and labels; scheduled sending, snooze, templates, and per-account vacation replies; EML/PDF export and printing; and OpenPGP/S/MIME signing, encryption, decryption, and signature verification. See [the feature guide](docs/features.md) for the controls and operational details.

Attachment rows provide signature-verified image, bounded text, and PDF previews. Remote images can be loaded once or allowed for a sender; the complete trusted-sender list remains reviewable and revocable under Preferences → Privacy. Background checking defaults to five minutes and can be changed to 15, 30, or 60 minutes—or manual-only—under Preferences → General; startup checking is independently configurable. Preferences also reopens to the last section used.

Calendar invitations (`text/calendar` or `.ics`) have an **Add to Calendar**
action. Mailficient copies the invitation to a private, size-bounded temporary
file and opens it with the desktop's registered calendar application, including
GNOME Calendar when it is the default `text/calendar` handler.

GNOME Calendar is a required companion application. The **Calendar** item in
Favorites launches it directly, keeping calendar data and synchronization in
GNOME Calendar instead of duplicating them in Mailficient. Debian and RPM
packages declare the dependency; Flatpak and Snap installations must have
GNOME Calendar installed separately because their application sandboxes do not
install another desktop application as a runtime dependency.

If the local mail database cannot be opened, Mailficient now shows a non-destructive recovery window with understandable guidance, expandable diagnostics, and a safe retry action rather than silently exiting or replacing the cache.

Invalid IMAP or SMTP certificates are rejected without a trust bypass. Account Setup now preserves Camel's validation reason and shows the affected host in an expandable certificate warning instead of reducing the failure to a generic connection error.

Provider throttling is classified separately from ordinary connection failures. Synchronization shows a clear wait-and-retry state. Temporary explicit SMTP failures remain in the retry queue with exponential backoff, while permanent 5xx rejections remain editable in Outbox and wait for the user to correct them instead of repeatedly contacting the server.

SMTP result handling now distinguishes a server response from a lost transport. A definitive rejection, authentication failure, invalid local message, or pre-SMTP attachment failure stays editable in Outbox; only a timeout, cancellation, or dropped connection after SMTP ownership triggers the duplicate-safe “delivery uncertain” state. Permanent 5xx rejection is a separate non-automatic state. Camel's boolean submission result and its sent-copy result are both checked instead of assuming that a call returning without an exception means success.

Sidebar badges are live unread counts, not total folder sizes. Demo counts are derived from the same message state shown in the list, and real-account counts are adjusted atomically when a message is marked read or unread—even while that server change is queued offline. Drafts and Outbox instead show their total local item counts; badge tooltips state which count is being shown.

Synchronization preserves useful partial results. If one folder or MIME message fails while other folders succeed, Mailficient commits the successful mail, leaves the affected folder's older cache untouched, reports the affected folder in expandable technical details, and shows a retry action instead of claiming that the account is fully up to date. Authentication, TLS, offline, timeout, and throttling failures stop further folder attempts but still preserve any results already downloaded during that pass.

Discarding a draft is database-first and failure-safe: a failed SQLite removal leaves the reopenable draft and all private attachment copies intact. After a successful discard, cleanup is restricted to Mailficient's private draft directory so corrupted metadata cannot delete an unrelated user file.

Before Mailficient gives a message to SMTP, it verifies that every attachment is still a regular file in private draft storage and still matches the size recorded when it was added. Missing or changed files leave the complete message safely queued in Outbox without entering the uncertain-delivery state. Outgoing MIME preparation is capped at 25 MB per attachment and 100 MB in total.

The one-time legacy Personal Mail data migration now rewrites absolute draft and received-attachment paths inside its staged SQLite copy before publishing the Mailficient directory. A failed copy or database rewrite removes the staging copy and leaves the legacy directory unchanged.

Received attachments are decoded through an enforcing private-cache stream. Misreported MIME sizes cannot write past the 50 MB per-attachment or 100 MB per-message automatic cache budgets, and partial files are removed atomically. Larger parts retain durable server metadata and can be explicitly downloaded to a user-chosen destination; Camel refetches the exact MIME part through a private staging file with a 2 GB hard boundary. Forwarding also retrieves uncached attachments when they fit the 25 MB outgoing safety limit, imports a durable private draft copy, and removes the temporary download on success, failure, or cancellation.

Implemented: modular build; polished adaptive three-pane demo; real conversation history; cached full-text and structured search; summary-only bounded mailbox lists with bodies loaded on demand; safe plain-text and sanitized WebKit HTML reading; scripts, storage, WebGL, and unsolicited remote resources disabled; explicit external-link confirmation; received-attachment saving without automatic opening; compose/reply/reply-all/forward; MIME attachments with tested Bcc privacy and byte-exact binary payloads; account-specific signatures; asynchronous GNOME address-book and cached-correspondent completion in To/Cc/Bcc; SQLite WAL migrations; durable drafts, Outbox, and offline message changes; safe private-cache maintenance; serialized synchronization and mutation retry that preserve offline state and authoritative unread totals across stale or partial server snapshots; automatically continuing 250-message sync sessions with Camel teardown between sessions; server-aware Junk/Not Junk classification plus local sender and domain junk rules; exponential send retry with an explicit non-retrying state for uncertain SMTP delivery; five-minute and reconnect-triggered synchronization; Sent filing with duplicate prevention for auto-filing providers; configurable desktop notifications; validated provider presets and recipients; libsecret credentials; initialized Camel IMAPX/SMTP folder and message synchronization with clean failed-connection retry and user-facing error classification; keyboard shortcuts, screen-reader labels, high-contrast states, and context menus; Flatpak metadata and original icon; core model/security/storage tests; and a credential-free Camel boundary test executed by Flatpak Builder.

The application is still under active development. Its standard IMAP/SMTP path is implemented, including adding, editing, testing, and safely removing accounts. Account changes are candidate-tested before a working session is disconnected, and credential, connection, or database failures restore the previous account transactionally. Gmail and Microsoft OAuth can be imported from GNOME Online Accounts without storing access tokens. Custom server folders can be created, renamed, and deleted; messages can be moved or copied to any folder through durable offline queues; the message list offers useful sorting modes; autosaved local drafts can be reopened from Drafts after a restart; and queued or failed sends remain visible and editable in Outbox. Draft persistence and Outbox insertion are atomic, and the compose window verifies preservation before claiming a failed send is safely queued. An uncertain SMTP result shows its diagnostic state and requires an explicit duplicate-delivery confirmation before resending; a server-accepted message awaiting local cleanup is read-only and cannot be sent twice. Reply All preserves and deduplicates To/Cc recipients, including replies to sent messages, and forwarding copies downloaded attachments into private draft storage. Preferences provides notification and per-identity signature controls. Synthetic long-duration sync, provider folder and destination-UID edge cases, automated AT-SPI and keyboard checks, light/dark/narrow visual QA, and a clean Flatpak build are qualified. Controlled real-mailbox memory profiling, credentialed provider end-to-end passes, and a hands-on Orca review still require an external account or interactive desktop session.

See [`docs/remaining-work.md`](docs/remaining-work.md) for the exact remaining qualification work and a safe real-account test sequence.

Credentialed qualification helpers are also included. `tools/real-account-memory-profile.sh` records and conservatively analyzes a controlled-mailbox RSS/PSS trajectory, while `tools/goa-provider-qa.sh` checks Google and Microsoft GOA connections independently without printing account addresses.

Useful shortcuts include **Ctrl+N** to compose, **Ctrl+F** to search, **F9** to refresh, **Ctrl+,** for Preferences, **Ctrl+A** to select all messages, **Escape** to clear selection, **Shift-click** to select a range, **Ctrl+J/Ctrl+K** to move between messages, **Ctrl+Shift+A/Ctrl+E** to archive, **Ctrl+Shift+U/Ctrl+I** to toggle read state, **Ctrl+R** to reply, **Ctrl+L** to forward, and **Ctrl+S** to snooze. **Ctrl+Enter** sends, **Ctrl+S** saves a draft, **Ctrl+Shift+A** attaches files, and **Ctrl+B**, **Ctrl+I**, or **Ctrl+U** formats selected compose text.

Search accepts ordinary words and the filters `from:`, `to:`, `mailbox:`, `label:`,
`is:unread`, `is:read`, `is:flagged`, `has:attachment`, and
`has:no-attachment`. Local calendar dates use ISO format, for example
`date:2026-07-19`, `after:2026-07-01`, or `before:2026-08-01`. Mailbox filters
match the visible folder name as well as its server and internal identifiers.

See [features](docs/features.md), [architecture](docs/architecture.md), [security](docs/security.md), [accounts](docs/accounts.md), [junk mail](docs/junk-mail.md), and [troubleshooting](docs/troubleshooting.md).
