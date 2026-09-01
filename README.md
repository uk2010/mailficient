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
sudo apt install valac meson ninja-build libgtk-4-dev libadwaita-1-dev libgee-0.8-dev libjson-glib-dev libwebkitgtk-6.0-dev libsecret-1-dev libcamel1.2-dev libebook1.2-dev libecal2.0-dev libedataserver1.2-dev libical-dev libsqlite3-dev libxml2-dev libssl-dev libcairo2-dev libpango1.0-dev
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
MAILFICIENT_DEV_INSTANCE=1 build/src/mailficient
```

Fedora equivalents include `vala`, `meson`, `ninja-build`, `gtk4-devel`, `libadwaita-devel`, `libgee-devel`, `json-glib-devel`, `webkitgtk6.0-devel`, `libsecret-devel`, `evolution-data-server-devel`, `libical-devel`, `sqlite-devel`, `libxml2-devel`, and `openssl-devel`.

Without host development packages, use GNOME Builder or a GNOME SDK shell. The Flatpak manifest builds Evolution Data Server 3.60.2 from its checksum-pinned official source and enables the conditional Camel adapter.

## Release downloads

The [v0.6.0-beta.1 GitHub release](https://github.com/uk2010/mailficient/releases/tag/v0.6.0-beta.1)
provides the complete source archive, Debian and RPM packages for AMD64 and
ARM64, and SHA-256 checksums for every downloadable package. Reproducible
workflows for Flatpak and Snap builds are included in the source repository.

## Flatpak package

Build the current Flatpak from the pinned source manifest, then install and run
the resulting bundle with:

```sh
flatpak install --user ./Mailficient-0.6.0-beta.1-x86_64.flatpak
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
sudo snap install --dangerous ./mailficient_0.6.0-beta.1_arm64.snap
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
sudo apt install ./dist/mailficient_0.6.0~beta1-1_$(dpkg --print-architecture).deb
mailficient
```

The resulting package is intended for Ubuntu 26.04 on AMD64 or ARM64. Building it
requires the GNOME 50 SDK and the checked Camel-enabled build artifacts; these
are already present in the documented Flatpak development environment.
The builder also writes a matching `.deb.sha256` checksum for release uploads.

## Status

The complete feature roadmap is implemented: bounded local and explicit server-side search; multi-selection and bulk actions; recoverable Trash moves plus confirmed permanent deletion and Empty Trash/Junk; rich composition with spellcheck, attachment reminders, durable Undo Send, formatting, inline images, and attachments; multi-condition rules, Quick Steps, and labels; scheduled sending, snooze, templates, and vacation replies; GNOME Calendar-backed Today and Events views with event creation, editing, deletion, all-day scheduling, and recurrence; calendar RSVP and meeting workflows; identity warnings, raw headers, Safe Senders, and reviewable unsubscribe/reporting actions; EML/PDF export and printing; and OpenPGP/S/MIME support. See [the feature guide](docs/features.md) for the controls and operational details.

Attachment rows provide signature-verified image, bounded text, and PDF previews. Remote images can be loaded once or allowed for a sender; Preferences → Safety opens the separate searchable Sender Lists window for reviewing and revoking trusted senders. IMAP IDLE delivers push updates while Mailficient is open. Background polling defaults to five minutes and can be changed to 1, 15, 30, or 60 minutes—or manual-only—under Preferences → General; startup checking is independently configurable. Preferences also reopens to the last section used.

Calendar invitations (`text/calendar` or `.ics`) are parsed within strict size
and structure limits and displayed as meeting cards in the reader. Builds with
Evolution Data Server calendar support can **Accept**, mark **Tentative**, or
**Decline** for the exact configured identity listed as an attendee, with an
explicit choice to send or suppress the organizer response. A sender/organizer
mismatch is highlighted before any action. Source builds without libecal retain
an honest **Open in Calendar to Respond** fallback instead of claiming that an
RSVP was recorded.

**Create Meeting from Email** saves an event draft to the default writable EDS
calendar with automatic invitation delivery disabled, then opens GNOME Calendar
for review. The fallback opens a private, size-bounded `.ics` draft in the
desktop calendar and likewise never sends an invitation automatically. The
**Today**, **Events**, and **Calendar** are reorderable direct Favorites rather
than a nested sidebar group. Today and Events query enabled Evolution Data
Server calendars, expand recurring occurrences, and write changes directly to
the selected event's calendar; new events go to the writable default calendar.
**Calendar** opens GNOME Calendar directly. No event copy is stored in the mail
database. GNOME Calendar must be installed
separately for Flatpak and Snap because their sandboxes cannot install another
desktop application as a runtime dependency. The Flatpak manifest enables the
EDS integration and grants access only to its calendar service.

If the local mail database cannot be opened, Mailficient now shows a non-destructive recovery window with understandable guidance, expandable diagnostics, and a safe retry action rather than silently exiting or replacing the cache.

Invalid IMAP or SMTP certificates are rejected without a trust bypass. Account Setup now preserves Camel's validation reason and shows the affected host in an expandable certificate warning instead of reducing the failure to a generic connection error.

Provider throttling is classified separately from ordinary connection failures. Synchronization shows a clear wait-and-retry state. Temporary explicit SMTP failures remain in the retry queue with exponential backoff, while permanent 5xx rejections remain editable in Outbox and wait for the user to correct them instead of repeatedly contacting the server.

SMTP result handling now distinguishes a server response from a lost transport. A definitive rejection, authentication failure, invalid local message, or pre-SMTP attachment failure stays editable in Outbox; only a timeout, cancellation, or dropped connection after SMTP ownership triggers the duplicate-safe “delivery uncertain” state. Permanent 5xx rejection is a separate non-automatic state. Camel's boolean submission result and its sent-copy result are both checked instead of assuming that a call returning without an exception means success.

Sidebar badges are live unread counts, not total folder sizes. Demo counts are derived from the same message state shown in the list, and real-account counts are adjusted atomically when a message is marked read or unread—even while that server change is queued offline. Active snoozes are removed from the visible Inbox count without discarding authoritative totals for mail that has not downloaded yet. Persistent desktop new-mail notifications are journaled and withdrawn after the message is read, moved, snoozed, or deleted, so the desktop app icon cannot retain a stale unread indicator. Drafts and Outbox instead show their total local item counts; badge tooltips state which count is being shown.

Synchronization preserves useful partial results. If one folder or MIME message fails while other folders succeed, Mailficient commits the successful mail, leaves the affected folder's older cache untouched, reports the affected folder in expandable technical details, and shows a retry action instead of claiming that the account is fully up to date. Authentication, TLS, offline, timeout, and throttling failures stop further folder attempts but still preserve any results already downloaded during that pass.

Discarding a draft is database-first and failure-safe: a failed SQLite removal leaves the reopenable draft and all private attachment copies intact. After a successful discard, cleanup is restricted to Mailficient's private draft directory so corrupted metadata cannot delete an unrelated user file.

Before Mailficient gives a message to SMTP, it verifies that every attachment is still a regular file in private draft storage and still matches the size recorded when it was added. Missing or changed files leave the complete message safely queued in Outbox without entering the uncertain-delivery state. Outgoing MIME preparation is capped at 25 MB per attachment and 100 MB in total.

The composer checks spelling with local desktop dictionaries and has an offline common-correction fallback. It also catches attachment wording when no file is present. Undo Send can be disabled. When enabled, the composer closes immediately and a bottom-of-main-window **Undo Send** action remains available for the configured 5–30 second durable Outbox fence; there is no composer countdown. When disabled, Send owns the first foreground SMTP attempt immediately. Outgoing delivery uses a connection lane isolated from Inbox synchronization, and the background worker remains the crash-safe fallback.

The reader exposes conservative message-identity findings and bounded raw headers from its shield control. A locally designated Safe Sender hides the automatic inline sender warning and permits remote images, while the full assessment stays available from the shield and link/attachment/HTML protections remain active. Standards-based unsubscribe targets are restricted to HTTPS or a reviewable mailto draft, and Report Phishing confirms before using the provider Junk path and local sender block.

Rules now support ordered AND/OR conditions, exceptions, multiple actions, account scope, stop-processing, reordering, and a bounded Run Now pass. Quick Steps apply reusable action sequences to selected messages. Search supports quotes, OR, exclusions, recipient/account/folder/attachment scopes, dates, flags, and sizes. Typing searches the private local index; pressing Enter explicitly runs a cancellable, 200-message-bounded server search in the chosen folder/account/all-mail scope.

The one-time legacy Personal Mail data migration now rewrites absolute draft and received-attachment paths inside its staged SQLite copy before publishing the Mailficient directory. A failed copy or database rewrite removes the staging copy and leaves the legacy directory unchanged.

Received attachments are decoded through an enforcing private-cache stream. Misreported MIME sizes cannot write past the 50 MB per-attachment or 100 MB per-message automatic cache budgets, and partial files are removed atomically. Larger parts retain durable server metadata and can be explicitly downloaded to a user-chosen destination; Camel refetches the exact MIME part through a private staging file with a 2 GB hard boundary. Forwarding also retrieves uncached attachments when they fit the 25 MB outgoing safety limit, imports a durable private draft copy, and removes the temporary download on success, failure, or cancellation.

Implemented: modular build; polished adaptive three-pane demo; real conversation history; cached full-text and structured search; summary-only bounded mailbox lists with bodies loaded on demand; safe plain-text and sanitized WebKit HTML reading; scripts, storage, WebGL, and unsolicited remote resources disabled; explicit external-link confirmation; received-attachment saving without automatic opening; compose/reply/reply-all/forward; MIME attachments with tested Bcc privacy and byte-exact binary payloads; account-specific signatures; asynchronous GNOME address-book and cached-correspondent completion in To/Cc/Bcc; SQLite WAL migrations with bounded cross-process write waiting; durable two-way provider Drafts, Outbox, and offline message changes; duplicate-safe leased background scheduled sending through an immediately started native worker plus XDG autostart for later logins, or through the Flatpak Background portal after its asynchronous grant; safe private-cache maintenance; serialized synchronization and mutation retry that preserve offline state and authoritative unread totals across stale or partial server snapshots; automatically continuing 250-message sync sessions with Camel teardown between sessions; server-aware Junk/Not Junk classification plus local sender and domain junk rules; exponential send retry with an explicit non-retrying state for uncertain SMTP delivery; five-minute and reconnect-triggered synchronization; Sent filing with duplicate prevention for auto-filing providers; configurable desktop notifications; validated provider presets and recipients; libsecret credentials; initialized Camel IMAPX/SMTP folder and message synchronization with clean failed-connection retry and user-facing error classification; keyboard shortcuts, screen-reader labels, high-contrast states, and context menus; Flatpak metadata and original icon; core model/security/storage tests; and credential-free Camel and provider-harness boundary tests.

The application is still under active development. Its standard IMAP/SMTP path is implemented, including adding, editing, testing, and safely removing accounts. Account changes are candidate-tested before a working session is disconnected, and credential, connection, or database failures restore the previous account transactionally. Gmail and Microsoft OAuth can be imported from GNOME Online Accounts without storing access tokens. Custom server folders can be created, renamed, and deleted; messages can be moved or copied to any folder through durable offline queues; the message list offers useful sorting modes; and provider drafts are mirrored into one unified editable Drafts view with revision-aware conflict and deletion handling. Unavailable provider attachments remain visible and block sending instead of disappearing. Queued, scheduled, or failed sends remain visible in Outbox and can be delivered by the background worker while the main window is closed. Draft persistence and Outbox insertion are atomic, and delivery reloads the durable draft after acquiring its database lease. An uncertain SMTP result shows its diagnostic state and requires an explicit duplicate-delivery confirmation before resending; a server-accepted message awaiting local cleanup is read-only and cannot be sent twice. Reply All preserves and deduplicates To/Cc recipients, including replies to sent messages, and forwarding copies downloaded attachments into private draft storage. Preferences provides notification and per-identity signature controls. Synthetic long-duration sync, provider folder and destination-UID edge cases, automated AT-SPI and keyboard checks, light/dark/narrow visual QA, and a clean Flatpak build are qualified. Controlled real-mailbox memory profiling, credentialed provider end-to-end passes, and a hands-on Orca review still require an external account or interactive desktop session.

See [`docs/remaining-work.md`](docs/remaining-work.md) for the exact remaining qualification work and a safe real-account test sequence.

Credentialed qualification helpers are also included. `tools/real-account-memory-profile.sh` records and conservatively analyzes a controlled-mailbox RSS/PSS trajectory, while `tools/goa-provider-qa.sh` checks Google and Microsoft GOA connections independently without printing account addresses.

Useful shortcuts include **Ctrl+N** to compose, **Ctrl+Shift+T** to create a task, **Ctrl+F** to search, **Enter** in Search to request bounded server results, **F9** to refresh, **Ctrl+,** for Preferences, **Ctrl+A** to select all messages, **Escape** to clear selection, **Shift-click** to select a range, **Ctrl+J/Ctrl+K** to move between messages, **Ctrl+Shift+A/Ctrl+E** to archive, **Ctrl+Shift+U/Ctrl+I** to toggle read state, **Ctrl+R** to reply, **Ctrl+L** to forward, and **Ctrl+S** to snooze. In the composer, **Ctrl+Enter** sends, **Ctrl+S** saves a draft, **Ctrl+Shift+A** attaches files, and **Ctrl+B**, **Ctrl+I**, or **Ctrl+U** formats selected text.

Search accepts ordinary words, quoted phrases, uppercase `OR`, a leading `-`
for exclusion, and the filters `from:`, `to:`, `cc:`, `bcc:`, `subject:`,
`account:`, `folder:`/`mailbox:`, `label:`, `attachment:`, `type:`, `is:unread`,
`is:read`, `is:flagged`, `has:attachment`, `has:no-attachment`, and `size:>10MB`.
Local calendar dates use ISO format, for example `date:2026-07-19`,
`after:2026-07-01`, or `before:2026-08-01`. Mailbox filters match the visible
folder name as well as its server and internal identifiers.

See [features](docs/features.md), [architecture](docs/architecture.md), [security](docs/security.md), [accounts](docs/accounts.md), [junk mail](docs/junk-mail.md), and [troubleshooting](docs/troubleshooting.md).
