# Mailficient 0.1.0

Mailficient 0.1.0 is the first public source release of the native Linux
desktop email client.

Highlights include:

- Adaptive three-pane GTK4 and Libadwaita interface
- Standard IMAP and SMTP account support through Evolution Data Server
- Secure credential storage with libsecret
- Offline cache, full-text search, drafts, Outbox, and background sync
- Safe plain-text and sanitized HTML message display
- Compose, reply, forwarding, attachments, signatures, and rich formatting
- Flatpak and Snap packaging definitions
- Automated core, Camel-boundary, accessibility, and visual-QA helpers

The standard IMAP/SMTP path is implemented. Controlled real-provider
qualification, long-duration memory profiling, and a hands-on screen-reader
review remain environment-dependent checks. See
[`docs/remaining-work.md`](docs/remaining-work.md) for details.

The source is licensed under GPL-3.0-or-later. Binary release archives should
be published as GitHub Release assets rather than committed to the repository.
