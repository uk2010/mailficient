# Mailficient 0.1.1

Mailficient 0.1.1 is the corrected packaging release of the native Linux
desktop email client. It removes an obsolete scalable icon that caused GNOME
to show the wrong application artwork and uses the intended black-and-white
Mailficient icon set. The release includes both an Ubuntu 26.04 AMD64 `.deb`
and an x86-64 Flatpak bundle.

Highlights include:

- Adaptive three-pane GTK4 and Libadwaita interface
- Standard IMAP and SMTP account support through Evolution Data Server
- Secure credential storage with libsecret
- Offline cache, full-text search, drafts, Outbox, and background sync
- Safe plain-text and sanitized HTML message display
- Compose, reply, forwarding, attachments, signatures, and rich formatting
- Flatpak, Debian, and Snap packaging
- Reproducible Flatpak source manifest with pinned libical and Camel dependencies
- Automated core, Camel-boundary, accessibility, and visual-QA helpers

The standard IMAP/SMTP path is implemented. Controlled real-provider
qualification, long-duration memory profiling, and a hands-on screen-reader
review remain environment-dependent checks. See
[`docs/remaining-work.md`](docs/remaining-work.md) for details.

The source is licensed under GPL-3.0-or-later. Binary release archives should
be published as GitHub Release assets rather than committed to the repository.
