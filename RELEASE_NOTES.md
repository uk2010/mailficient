# Mailficient 0.1.4

Mailficient 0.1.4 improves message-list continuity and makes flag controls
render consistently on every supported desktop theme.

Highlights:

- Bundles a proper symbolic flag icon instead of relying on a theme icon that
  could appear as a red missing-image square
- Uses the flag consistently in message rows, the main toolbar, toolbar
  customization, and the Flagged mailbox
- Selects the next adjacent message after archive, Trash, permanent deletion,
  or Junk classification instead of leaving the reading pane empty
- Keeps the existing provider-guided setup, calendar invitation support,
  bounded synchronization, offline cache, drafts, Outbox, and secure
  libsecret credential storage

This release provides an x86-64 Flatpak bundle, an Ubuntu 26.04 AMD64 `.deb`,
and an AMD64 Snap as GitHub Release downloads. Matching SHA-256 checksum files
are included for each package.

The source is licensed under GPL-3.0-or-later. Binary release artifacts are
published as GitHub Release assets rather than committed to the repository.
