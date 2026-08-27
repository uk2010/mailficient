# Qualification status and real-account test checklist

The locally executable regression checklist was refreshed on 2026-08-25. The isolated GreenMail provider-harness qualification is complete. The remaining external gates require provider credentials, a controlled external mailbox, or a person operating Orca in an interactive desktop session; none can be truthfully replaced by a local harness.

## Critical qualification: initial-sync memory use

On 2026-07-20, real-account testing found that memory usage grew dramatically while Mailficient downloaded mail. The process consumed the machine's available 32 GB of RAM and then crashed.

The synchronization pipeline was bounded on 2026-07-22: each backend session downloads at most 250 new MIME messages, publishes small database batches of converted messages, explicitly releases each Camel MIME tree after conversion, and rejects decoded text parts over 10 MB. When more uncached mail remains, Mailficient checkpoints the batch, releases the Camel session, and automatically continues with another bounded session until the account is caught up—no restart or repeated Get Mail action is required. Refresh identity discovery selects IDs directly from SQLite instead of materializing every cached body and HTML document. The mailbox view exposes the complete logical count while retaining at most three 40-summary pages, loads a full body only when that message is opened, and coalesces streamed database updates before refreshing visible rows. Core and Camel regression tests cover these bounds.

This removes the known unbounded application allocations. A 240-cycle streamed stress test now processes 20,000 synthetic messages, including 40 intermittent offline failures, 200 successful 100-message batches, serialized refreshes, bounded notifications, session teardown after every pass, and less than 128 MB resident-memory growth. The test process peaked at about 23 MB RSS in the qualifying run. It is not a substitute for profiling Camel against a real provider. Reproduce first with a controlled mailbox, watch resident memory across multiple progressive refreshes, and confirm that the cache reaches a stable ceiling. Do not repeat the original large production-mailbox test until that controlled run passes.

## Completed locally

1. Bounded sync and lightweight cache identity scanning are covered by core and Camel regression tests.
2. The 240-cycle, 20,000-message background-sync stress test covers summary-only mailbox loading, batching, serialized execution, per-pass Camel teardown, intermittent connectivity, notification limits, and resident-memory growth.
3. Provider folder-role fallbacks cover common Gmail, Microsoft, and other Sent, Archive, Junk, and Trash names. Moves that omit a destination UID recover it only from a unique new message with the same Message-ID.
4. The credential-free OAuth boundary covers GNOME Online Accounts discovery parsing, XOAUTH2 selection, short-lived token bridging, and token removal.
5. The final live AT-SPI audit found 40 visible interactive controls in the baseline state and no unnamed actionable control. Automated keyboard QA verifies Ctrl+F, Ctrl+N, forward and reverse Tab focus through the composer, Ctrl+Tab insertion in the message body, and safe Ctrl+Enter validation.
6. Light, dark, narrow, preferences, Rules, calendar-invitation, security, empty, error, sync, compose, and Outbox visual states were repeated and inspected without a visual defect or Mailficient warning, critical, or error.
7. A clean Flatpak Builder build compiled against Evolution Data Server 3.60.2 and exposed an API-version mismatch in server search. The compatibility path was fixed for both pre-3.58 and current Camel APIs, after which all seven in-sandbox suites passed. The installed application, address-book probe, ECal/Camel linkage, autostart entry, documentation, desktop metadata, XML, icons, and AppStream composition were verified from the finished application tree, and the packaged executable completed a real X11 startup/screenshot smoke test.
8. Focused Drafts, Outbox, and storage regressions cover exact remote revision/UID ownership, same-UID external edits, UID replacement, authoritative empty-folder deletion, explicit third-party discard, unavailable-attachment placeholders, stale-worker/autosave exclusion, reconcile-versus-edit ordering, duplicate-safe delivery claims, zero-network no-work checks, Flatpak activation gating, and concurrent SQLite writers with bounded busy waiting.
9. Camel boundary coverage verifies deterministic Draft Message-IDs, exact UID-plus-Message-ID deletion, separate plain/HTML fidelity (including HTML-only drafts), Bcc preservation for editable provider drafts, and bounded refresh convergence for Drafts folders larger than one 250-message session.
10. On 2026-08-25, fresh disposable GreenMail runs passed against both the legacy host Camel API and EDS 3.60.2 in 8.67 and 8.72 seconds. They exercised encrypted loopback IMAP/SMTP authentication, Drafts creation/save/idempotent lookup/exact deletion, MIME attachment round trips, sending and Sent filing, folder state/move operations, matching and empty bounded server searches, a live IMAP IDLE arrival from an independent client, intentional disconnect, reconnect, and final provider-state verification. The companion 501-Draft regression converged across three bounded 250-message sessions.
11. Calendar regressions cover folded Outlook-style invitations, RFC 6868 parameters, time zones, duration and recurrence, all-day cancellation, malformed and oversized input, exact attendee identity, optional organizer delivery, meeting drafts with iTIP disabled, private staging cleanup, EDS PARTSTAT mutation, and unnamed inline `text/calendar` MIME extraction. The invitation-card visual state was inspected without a GTK warning or critical.
12. Compose safety regressions cover local Enchant/Aspell spell checking with an offline fallback, forgotten-attachment detection, optional 5–30 second Undo Send through a bottom-window action, crash-safe delayed delivery, immediate foreground delivery when disabled, and reopening an undone message as an editable draft.
13. Task regressions cover local Today and Planned views, due dates, reminders, recurrence, completion, and message-linked follow-up creation. Empty, light, dark, and keyboard states were reviewed.
14. Security regressions cover authentication, sender/reply, punycode, and link-risk indicators; a separately managed Safe Senders list; bounded raw headers; HTTPS/`mailto:` unsubscribe review; and durable phishing reporting through Junk plus a local sender rule. Light and dark security states and their keyboard actions passed.
15. Automation and search regressions cover ordered AND/OR rules, exceptions, multiple actions, stop-processing, account scope, reordering, bounded run-now, reusable Quick Steps, richer local query syntax, and explicit bounded server scope. The Rules preferences state, empty states, keyboard labels, and live GreenMail server-search path passed.
16. Native staged installation and strict-package metadata now include the executable, address-book probe, desktop/DBus/AppStream metadata, icons, release documentation, and the XDG background-delivery entry. Debian, RPM, Snap, and Flatpak definitions pass the available local static checks; Flatpak additionally passed the clean executable package build above.

## External qualification still required

1. Profile the bounded initial download against a controlled real mailbox, verify that resident memory stabilizes across progressive refreshes, then repeat a larger non-critical-mailbox test.
2. Qualify at least one real IMAP/SMTP provider end to end: initial folder discovery, incremental refresh, local and server-scope search, sending, Sent filing, two-way Drafts edits/deletion and attachments, moves, Junk/Not Junk, Safe Senders, unsubscribe review, phishing reporting, offline restart, and reconnection. With the app open, deliver new mail from a second client and confirm the live IMAP IDLE path refreshes the mailbox and emits one bounded notification without pressing Get Mail. Schedule a disposable message, close the main window, and confirm native XDG autostart or the granted Flatpak Background permission delivers it once; repeat a queued retry after connectivity returns.
3. Qualify both Gmail and Microsoft OAuth with authorized GNOME Online Accounts. The probes were repeated on 2026-08-25: Google reached the configured Online Account, but GOA reported that its credentials were absent from the keyring and authorization must be renewed; no Microsoft mail-enabled Online Account was available. The probe requests cancellation after 30 seconds and performs only connect/disconnect.
4. Complete a hands-on Orca spoken-output and full keyboard-only review. The automated tree and critical-shortcut checks cannot judge pronunciation, announcement quality, or the subjective usability of a complete workflow.
5. To qualify cross-device task synchronization, wire the existing `TaskSyncProvider` boundary to libecal/EDS and test it with an authorized task-capable CalDAV or GNOME Online Account. The current build intentionally stores tasks locally; this does not gate local Today/Planned views, reminders, recurrence, or linked-email follow-up.
6. Qualify invitations against writable real-account EDS sources for Gmail and Microsoft. Exercise a recurring request, an all-day event, a cancellation, each participation value, and both organizer-response choices; verify that only the selected identity changes and that the organizer receives mail only when requested. Confirm that **Create Meeting from Email** creates one reviewable event without sending an invitation automatically.
7. Run the multi-architecture release workflows and install their produced Debian, RPM, and Snap artifacts on the targeted distributions. Verify upgrades, desktop/DBus registration, dictionaries, EDS ABI dependencies, autostart behavior, and clean removal. These are artifact/platform qualification gates; the package definitions and Flatpak application tree are already complete locally.

Provider-specific defects found during these credentialed passes must be fixed and the relevant local and provider checks repeated before a production-ready declaration.

## Reproducible external qualification

For the controlled-mailbox memory run, start the normal application, begin with a small secondary mailbox, and run:

```bash
tools/real-account-memory-profile.sh --duration 1800 --output controlled-mailbox.csv
```

Trigger **Get Mail** once and let the mailbox advance automatically through bounded 250-message sessions. The profiler samples RSS, PSS, and the process high-water mark every five seconds. Its conservative default requires at least 20 minutes of evidence, no more than 1 MiB/minute final-half RSS growth, and no more than 256 MiB final-half variation before it reports a plateau candidate. Preserve the CSV and review the raw trajectory; the heuristic is supporting evidence, not a substitute for confirming that multiple successful sessions occurred. Repeat with a larger non-critical mailbox only after the controlled run plateaus.

After configuring or renewing Online Accounts, run the redacted provider probe:

```bash
tools/goa-provider-qa.sh
```

It checks Google and Microsoft separately, performs only connect/disconnect, suppresses core dumps, applies an outer 40-second watchdog, and never prints an account address. `PASS` is required for each provider. `AUTHORIZATION REQUIRED` or `UNAVAILABLE` identifies an external setup gate rather than satisfying it.

For the hands-on Orca pass, use the normal desktop session with sound enabled. Verify the account and mailbox sidebar, message list, reading pane, compose recipients and attachment controls, preferences, dialogs, error details, and the complete send/draft/move workflow. Confirm that every focused control is announced with an understandable name and state, focus never becomes trapped, Escape closes transient UI where expected, and the spoken order matches the visual/task order. Record the desktop, Orca, GTK, and Mailficient versions and any misannouncement verbatim.

## Safe real-account test

Launch the normal application, not demo mode:

```bash
flatpak run --user com.local.Mailficient
```

Use **Add Account** on first launch, or open the top-right menu and choose **Accounts**. For the first pass, a secondary account or an account with non-critical mail is prudent even though Mailficient keeps offline mutations durable and asks before any ambiguous resend.

Test in this order:

1. Add the account and use **Test and Add Account**.
2. Choose **Get Mail** and confirm Inbox and account folders appear.
3. Open several messages, restart Mailficient, and confirm they remain readable offline.
4. Send a short message to yourself without an attachment, then confirm it appears in both Inbox and Sent.
5. Send a second message with a small text or image attachment.
6. Save and reopen a draft, confirm it appears in the provider Drafts folder, edit that draft with a second client, and confirm **Get Mail** imports the edit into the unified editable Drafts view. Discard a separate synchronized draft and confirm only that exact provider copy disappears.
7. Schedule a disposable message a few minutes ahead, close the main window, and confirm it is delivered exactly once by the permitted background worker. Repeat while initially offline and confirm the durable retry succeeds after connectivity returns.
8. While Mailficient remains open, send a new unread message from a second client. Confirm the live IDLE update appears without pressing Get Mail and that notification text/count is bounded rather than repeated across sync continuations.
9. Send a disposable invitation to this account. First update the calendar with **Send a response to the organizer** off and verify no reply arrives; use a second invitation with it on and verify exactly one response. Convert a disposable email to a meeting and verify GNOME Calendar opens one saved event without mailing the attendee.
10. Search locally with two combined fields, repeat in explicit server scope, and confirm a result that is not already cached can be opened.
11. On a disposable mailing-list message, review the unsubscribe target before continuing. Open security details and raw headers, then exercise Safe Sender and Report Phishing with a disposable sender.
12. Mark a test message read/unread and flagged/unflagged; move it to Archive and back where supported.
13. Test Junk/Not Junk only on a disposable message.
14. Disconnect the network, make one read or flag change, reconnect, and choose **Get Mail**.

Do not use a production message for the first Delete, Trash, Junk, folder rename, or folder deletion test. OAuth accounts should be added through GNOME Online Accounts; Mailficient never stores the short-lived OAuth token in its database.

## Reporting a problem

Record the visible error title, the action being performed, and the expandable **Technical Details** text. Do not send passwords, app passwords, OAuth tokens, or complete private message bodies. A screenshot with addresses and subjects redacted is sufficient for visual defects.

The development demo remains available separately:

```bash
flatpak run --user --env=MAILFICIENT_QA=1 com.local.Mailficient
```
