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

This release provides an x86-64 Flatpak bundle, an Ubuntu 26.04 AMD64 `.deb`,
and an AMD64 Snap as GitHub Release downloads. ARM64 packages can be added from
a native ARM64 build. Matching SHA-256 checksum files accompany each package.

The source is licensed under GPL-3.0-or-later. Binary release artifacts are
published as GitHub Release assets rather than committed to the repository.
