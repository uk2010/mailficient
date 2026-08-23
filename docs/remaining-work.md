# Qualification status and real-account test checklist

The locally executable checklist was completed on 2026-07-22. The remaining gates require provider credentials, a controlled external mailbox, or a person operating Orca in an interactive desktop session; none can be truthfully replaced by a credential-free unit test.

## Critical qualification: initial-sync memory use

On 2026-07-20, real-account testing found that memory usage grew dramatically while Mailficient downloaded mail. The process consumed the machine's available 32 GB of RAM and then crashed.

The synchronization pipeline was bounded on 2026-07-22: each backend session downloads at most 250 new MIME messages, publishes database batches of at most 20 converted messages, explicitly releases each Camel MIME tree after conversion, and rejects decoded text parts over 10 MB. When more uncached mail remains, Mailficient checkpoints the batch, releases the Camel session, and automatically continues with another bounded session until the account is caught up—no restart or repeated Get Mail action is required. Refresh identity discovery selects IDs directly from SQLite instead of materializing every cached body and HTML document. The mailbox view keeps at most 500 lightweight summaries in memory, loads a full body only when that message is opened, and reloads the visible list once per completed backend session instead of once per 20-message database batch. Core and Camel regression tests cover these bounds.

This removes the known unbounded application allocations. A 240-cycle streamed stress test now processes 20,000 synthetic messages, including 40 intermittent offline failures, 200 successful 100-message batches, serialized refreshes, bounded notifications, session teardown after every pass, and less than 128 MB resident-memory growth. The test process peaked at about 23 MB RSS in the qualifying run. It is not a substitute for profiling Camel against a real provider. Reproduce first with a controlled mailbox, watch resident memory across multiple progressive refreshes, and confirm that the cache reaches a stable ceiling. Do not repeat the original large production-mailbox test until that controlled run passes.

## Completed locally

1. Bounded sync and lightweight cache identity scanning are covered by core and Camel regression tests.
2. The 240-cycle, 20,000-message background-sync stress test covers summary-only mailbox loading, batching, serialized execution, per-pass Camel teardown, intermittent connectivity, notification limits, and resident-memory growth.
3. Provider folder-role fallbacks cover common Gmail, Microsoft, and other Sent, Archive, Junk, and Trash names. Moves that omit a destination UID recover it only from a unique new message with the same Message-ID.
4. The credential-free OAuth boundary covers GNOME Online Accounts discovery parsing, XOAUTH2 selection, short-lived token bridging, and token removal.
5. The live AT-SPI audit found 51 visible interactive controls and no unnamed actionable control. Automated keyboard QA verifies Ctrl+F, Ctrl+N, and forward Tab focus.
6. Light, dark, and narrow screenshots were repeated and inspected without a visual defect.
7. A clean Flatpak Builder build compiled libical, Evolution Data Server, and Mailficient from the manifest, then passed the full core and Camel suites during the build. Desktop metadata, XML, icon, and AppStream checks pass.

## External qualification still required

1. Profile the bounded initial download against a controlled real mailbox, verify that resident memory stabilizes across progressive refreshes, then repeat a larger non-critical-mailbox test.
2. Qualify at least one real IMAP/SMTP provider end to end: initial folder discovery, incremental refresh, sending, Sent filing, drafts, attachments, moves, Junk/Not Junk, offline restart, and reconnection.
3. Qualify both Gmail and Microsoft OAuth with authorized GNOME Online Accounts. An optional Google probe reached the configured Online Account on 2026-07-22, but GOA reported that the account needs renewed authorization. No Microsoft mail-enabled Online Account was available. The probe requests cancellation after 30 seconds and performs only connect/disconnect.
4. Complete a hands-on Orca spoken-output and full keyboard-only review. The automated tree and critical-shortcut checks cannot judge pronunciation, announcement quality, or the subjective usability of a complete workflow.

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
6. Save and reopen a draft, then discard a separate test draft.
7. Mark a test message read/unread and flagged/unflagged; move it to Archive and back where supported.
8. Test Junk/Not Junk only on a disposable message.
9. Disconnect the network, make one read or flag change, reconnect, and choose **Get Mail**.

Do not use a production message for the first Delete, Trash, Junk, folder rename, or folder deletion test. OAuth accounts should be added through GNOME Online Accounts; Mailficient never stores the short-lived OAuth token in its database.

## Reporting a problem

Record the visible error title, the action being performed, and the expandable **Technical Details** text. Do not send passwords, app passwords, OAuth tokens, or complete private message bodies. A screenshot with addresses and subjects redacted is sufficient for visual defects.

The development demo remains available separately:

```bash
flatpak run --user --env=MAILFICIENT_QA=1 com.local.Mailficient
```
