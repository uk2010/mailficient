# Mailficient 0.1.7

Mailficient 0.1.7 fixes the main window's behavior at small desktop sizes.

Highlights:

- Preserves the mailbox, message list, and reader as three visible columns when
  the window is scaled down, matching Apple Mail's desktop behavior
- Enforces a practical minimum width so panes and controls cannot be clipped
- Compacts the toolbar and moves excess actions into overflow while keeping
  mailbox navigation, compose, Reply, Reply All, Forward, search, and sorting
  available
- Keeps every compacted command accessible from the application menu
- Debian revision 4 bundles the matching XML runtime on ARM64 so the native
  package starts correctly on current Ubuntu releases

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
