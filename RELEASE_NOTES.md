# Mailficient 0.1.3

Mailficient 0.1.3 makes iCloud Mail setup directly visible on the Accounts
screen. It also includes the provider-guided setup, calendar-invitation
interoperability, and manual-account sending fixes introduced in 0.1.2.

Highlights:

- Adds a dedicated **iCloud Mail** row and **Add iCloud** button
- Explains that iCloud uses an Apple Account email and app-specific password
- Adds provider choices for iCloud, Microsoft, Google, Yahoo, AOL, and custom
  IMAP/SMTP accounts
- Prevents stalled SMTP connections from leaving manual-account sends hanging
  indefinitely
- Adds an **Add to Calendar** action for `.ics` and `text/calendar`
  attachments
- Opens invitations with the desktop's registered calendar application,
  including GNOME Calendar
- Bounds calendar invitation staging to 2 MB and uses a private temporary copy
- Includes the corrected Mailficient application icon in the Debian package
- Retains the adaptive GTK4/Libadwaita interface, offline cache, full-text
  search, drafts, Outbox, secure libsecret credentials, and Camel IMAP/SMTP

This release provides an Ubuntu 26.04 AMD64 `.deb`. The existing v0.1.1
x86-64 Flatpak remains available from its release, and all Flatpak build source
and its checksum-pinned manifest remain in this repository.

The source is licensed under GPL-3.0-or-later. Binary release archives are
published as GitHub Release assets rather than committed to the repository.
