# Mailficient 0.1.12

Mailficient 0.1.12 fixes message selection stability and improves toolbar
customization.

Highlights:

- Keeps a clicked unread message selected while it is marked read
- Organizes the application menu into clear Mail, View, Accounts, Settings,
  and Help sections
- Adds an extensible right-click toolbar popup with “Customize Toolbar…”
- Provides matching Debian packages for x86-64 and ARM64 with SHA-256 checksums

# Mailficient 0.1.11

Mailficient 0.1.11 completes full mailbox downloads without an artificial
per-check message limit.

Highlights:

- Downloads every discovered uncached message during synchronization
- Streams messages in small database batches and yields between downloads so
  large mailboxes remain responsive without truncating the check
- Keeps the faster persistent incoming IMAP and lazy SMTP connection behavior

This release provides Debian packages for x86-64 and ARM64 with matching
SHA-256 checksum files.

# Mailficient 0.1.10

Mailficient 0.1.10 makes Get Mail substantially faster and more predictable.

Highlights:

- Keeps incoming IMAP connections available between mail checks instead of
  reconnecting for every sync
- Opens SMTP lazily for sending and account validation, so checking mail does
  not wait for the outgoing server
- Refreshes only folders that support remote refresh and bounds each sync's
  message-download work
- Defers older message history to later checks instead of chaining many slow
  download passes into one Get Mail action
- Publishes matching Debian packages for AMD64 and ARM64

This release provides Debian packages for x86-64 and ARM64 with matching
SHA-256 checksum files.

# Mailficient 0.1.9

Mailficient 0.1.9 improves message triage, keyboard navigation, and local
cache efficiency.

Highlights:

- Adds Shift-click range selection, Ctrl-click toggling, Ctrl+A select-all,
  and Escape selection clearing
- Adds J/K navigation plus E archive, I read-state, R reply, F forward, and S
  snooze shortcuts
- Coalesces bulk-action refreshes so large selections update once
- Speeds up Drafts, Outbox scheduling, and conversation loading with lighter
  summary queries and new cache indexes
- Publishes Debian packages for AMD64 and ARM64 with matching checksums

This release provides Flatpak, Debian, and Snap packages for x86-64 and ARM64.

# Mailficient 0.1.8

Mailficient 0.1.8 improves account setup, manual-account sending, and mailbox
workflow clarity.

Highlights:

- Preserves the mailbox, message list, and reader as three visible columns when
  the window is scaled down, matching Apple Mail's desktop behavior
- Enforces a practical minimum width so panes and controls cannot be clipped
- Compacts the toolbar and moves excess actions into overflow while keeping
  mailbox navigation, compose, Reply, Reply All, Forward, search, and sorting
  available
- Keeps every compacted command accessible from the application menu
- Imports plain and signed Apple `.mobileconfig` mail profiles through both
  onboarding and Settings → Accounts, with review and connection testing
- Explicitly authenticates password-based IMAP and SMTP sessions so manually
  configured accounts can send mail reliably
- Lets saved signatures be inserted manually even when automatic insertion is
  disabled
- Preserves each sidebar account's expanded or collapsed state across mail
  checks and application restarts
- Shows distinct Junk and Not Junk toolbar icons based on the current mailbox,
  with matching tooltips and accessibility labels
- Bundles the matching XML and Camel runtime libraries in Debian packages on
  both AMD64 and ARM64

This release provides Flatpak, Debian, and Snap packages for x86-64 and ARM64,
with matching SHA-256 checksum files.

# Mailficient 0.1.6

Mailficient 0.1.6 refines the customizable toolbar, unread-message workflow,
smart-mailbox results, and native package integration.

Highlights:

- Makes the customizable top bar compact and consistently sizes its actions,
  application menu, and flag split button while retaining system colors
- Keeps an opened unread message visible long enough to read after it is marked
  read
- Deduplicates Flagged results and unread counts when one email is cached in
  Inbox, All Mail, and Important
- Corrects Debian and Snap desktop integration, architecture detection, and
  installed file permissions
- Prevents Get Mail from crashing after an Evolution Data Server upgrade by
  rebuilding incompatible, disposable Camel folder-summary caches
- Ensures Debian packages cannot mix an executable and bundled Camel libraries
  from incompatible Evolution Data Server ABIs

This release provides an x86-64 Flatpak bundle, Ubuntu 26.04 AMD64 and ARM64
`.deb` packages, and an AMD64 Snap as GitHub Release downloads. Matching
SHA-256 checksum files accompany each package.

The source is licensed under GPL-3.0-or-later. Binary release artifacts are
published as GitHub Release assets rather than committed to the repository.
