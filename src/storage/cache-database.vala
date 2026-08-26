namespace Mailficient {
public class CacheDatabase : Object, AccountStore {
    public const int MESSAGE_LIST_LIMIT = 500;
    public const int MAX_CONVERSATION_MESSAGES = 100;
    public const int BUSY_TIMEOUT_MILLISECONDS = 5000;
    // Sent-draft tombstones only bridge overlapping provider snapshots. User
    // initiated discards are permanent; successful sends can age out after a
    // conservative week so normal use cannot grow per-sync filtering forever.
    private const int64 TRANSIENT_DRAFT_TOMBSTONE_SECONDS = 7 * 24 * 60 * 60;
    // cached_messages.managed_draft_identity uses an explicit negative marker
    // so upgraded rows are parsed once, rather than rescanned on every Cancel.
    private const string NO_MANAGED_DRAFT_IDENTITY = "!";
    // Recipient completion is invoked from GTK entry change handlers.  Never
    // walk an unbounded mailbox here: a large local archive would otherwise
    // make the compose window (and its Send button) appear to hang.
    public const int RECIPIENT_CANDIDATE_MESSAGE_LIMIT = 500;
    public signal void mutation_queued (string account_id);
    // Successful local saves may need a provider Drafts upload. The
    // application uses this edge-trigger to request Flatpak background access;
    // the background service itself verifies the durable database state.
    public signal void remote_draft_work_queued (string account_id);
    private Sqlite.Database database;
    private Sqlite.Statement? bulk_message_statement;
    private bool bulk_sync_mode;

    public CacheDatabase (string path) throws MailError {
        if (Sqlite.Database.open (path, out database) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not open the mail cache");
        // The GUI and the background delivery process intentionally share this
        // WAL database. Give short overlapping writes time to serialize rather
        // than surfacing a transient SQLITE_BUSY as lost mail state.
        execute ("PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        migrate ();
    }

    private void migrate () throws MailError {
        execute ("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);" +
            "INSERT INTO schema_version(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM schema_version);" +
            "CREATE TABLE IF NOT EXISTS drafts(" +
            "id TEXT PRIMARY KEY, account_id TEXT NOT NULL, recipients_to TEXT NOT NULL, cc TEXT NOT NULL, bcc TEXT NOT NULL," +
            "subject TEXT NOT NULL, body_text TEXT NOT NULL, in_reply_to TEXT NOT NULL, modified_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS draft_attachments(" +
            "draft_id TEXT NOT NULL, id TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, content_type TEXT NOT NULL," +
            "PRIMARY KEY(draft_id,id), FOREIGN KEY(draft_id) REFERENCES drafts(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0," +
            "next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '',delivery_state INTEGER NOT NULL DEFAULT 0);" +
            "DELETE FROM outbox WHERE rowid NOT IN (SELECT MAX(rowid) FROM outbox GROUP BY draft_id);" +
            "CREATE UNIQUE INDEX IF NOT EXISTS outbox_draft_id ON outbox(draft_id);" +
            "CREATE TABLE IF NOT EXISTS accounts(" +
            "id TEXT PRIMARY KEY, display_name TEXT NOT NULL, email TEXT NOT NULL UNIQUE," +
            "incoming_host TEXT NOT NULL, incoming_port INTEGER NOT NULL, incoming_encryption INTEGER NOT NULL, incoming_username TEXT NOT NULL," +
            "outgoing_host TEXT NOT NULL, outgoing_port INTEGER NOT NULL, outgoing_encryption INTEGER NOT NULL, outgoing_username TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS vip_senders(address TEXT PRIMARY KEY COLLATE NOCASE);" +
            "CREATE TABLE IF NOT EXISTS trusted_remote_senders(address TEXT PRIMARY KEY COLLATE NOCASE,created_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS safe_senders(address TEXT PRIMARY KEY COLLATE NOCASE,created_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS junk_rules(id INTEGER PRIMARY KEY AUTOINCREMENT,kind INTEGER NOT NULL,pattern TEXT NOT NULL COLLATE NOCASE,UNIQUE(kind,pattern));" +
            "CREATE TABLE IF NOT EXISTS mail_labels(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE COLLATE NOCASE,color TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS mail_rules(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,account_id TEXT NOT NULL," +
            "field INTEGER NOT NULL,pattern TEXT NOT NULL,action INTEGER NOT NULL,value TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1);" +
            "CREATE TABLE IF NOT EXISTS mail_rule_conditions(rule_id INTEGER NOT NULL,position INTEGER NOT NULL,field INTEGER NOT NULL," +
            "operator INTEGER NOT NULL,pattern TEXT NOT NULL,is_exception INTEGER NOT NULL DEFAULT 0," +
            "PRIMARY KEY(rule_id,is_exception,position),FOREIGN KEY(rule_id) REFERENCES mail_rules(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS mail_rule_actions(rule_id INTEGER NOT NULL,position INTEGER NOT NULL,action INTEGER NOT NULL,value TEXT NOT NULL," +
            "PRIMARY KEY(rule_id,position),FOREIGN KEY(rule_id) REFERENCES mail_rules(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS quick_steps(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,account_id TEXT NOT NULL DEFAULT '',position INTEGER NOT NULL DEFAULT 0);" +
            "CREATE TABLE IF NOT EXISTS quick_step_actions(quick_step_id INTEGER NOT NULL,position INTEGER NOT NULL,action INTEGER NOT NULL,value TEXT NOT NULL," +
            "PRIMARY KEY(quick_step_id,position),FOREIGN KEY(quick_step_id) REFERENCES quick_steps(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS smart_mailboxes(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE COLLATE NOCASE,query TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS mail_tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,due_at TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0,notes TEXT NOT NULL,message_id TEXT NOT NULL DEFAULT '');" +
            "CREATE TABLE IF NOT EXISTS mail_templates(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE COLLATE NOCASE," +
            "subject TEXT NOT NULL,body_text TEXT NOT NULL,body_html TEXT NOT NULL,body_format TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS message_labels(message_id TEXT NOT NULL,label_id INTEGER NOT NULL," +
            "PRIMARY KEY(message_id,label_id),FOREIGN KEY(message_id) REFERENCES cached_messages(id) ON DELETE CASCADE," +
            "FOREIGN KEY(label_id) REFERENCES mail_labels(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS snoozed_messages(message_id TEXT PRIMARY KEY,until_unix INTEGER NOT NULL," +
            "FOREIGN KEY(message_id) REFERENCES cached_messages(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS vacation_settings(account_id TEXT PRIMARY KEY,enabled INTEGER NOT NULL," +
            "starts_at INTEGER NOT NULL,ends_at INTEGER NOT NULL,subject TEXT NOT NULL,body TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS vacation_reply_log(account_id TEXT NOT NULL,sender TEXT NOT NULL COLLATE NOCASE,replied_at INTEGER NOT NULL," +
            "PRIMARY KEY(account_id,sender));" +
            "CREATE TABLE IF NOT EXISTS pending_credential_cleanup(account_id TEXT PRIMARY KEY,created_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS pending_remote_draft_deletions(" +
            "id INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL,mailbox_name TEXT NOT NULL,remote_uid TEXT NOT NULL," +
            "expected_message_id TEXT NOT NULL,expected_fingerprint TEXT NOT NULL DEFAULT ''," +
            "created_at INTEGER NOT NULL,completed_at INTEGER NOT NULL DEFAULT 0," +
            "suppress_reimport INTEGER NOT NULL DEFAULT 0,permanent_tombstone INTEGER NOT NULL DEFAULT 0);" +
            "CREATE TABLE IF NOT EXISTS remote_draft_upload_attempts(" +
            "draft_id TEXT NOT NULL,account_id TEXT NOT NULL,revision INTEGER NOT NULL," +
            "expected_message_id TEXT NOT NULL,created_at INTEGER NOT NULL," +
            "PRIMARY KEY(draft_id,revision));" +
            "CREATE TABLE IF NOT EXISTS cached_messages(" +
            "id TEXT PRIMARY KEY, mailbox_id TEXT NOT NULL, sender_name TEXT NOT NULL, sender_address TEXT NOT NULL, recipients TEXT NOT NULL," +
            "subject TEXT NOT NULL, preview TEXT NOT NULL, body TEXT NOT NULL, timestamp TEXT NOT NULL, unread INTEGER NOT NULL, flagged INTEGER NOT NULL," +
            "has_attachment INTEGER NOT NULL, conversation_count INTEGER NOT NULL, has_remote_content INTEGER NOT NULL, body_html TEXT NOT NULL," +
            "content_extracted INTEGER NOT NULL DEFAULT 0,managed_draft_identity TEXT NOT NULL DEFAULT ''," +
            "draft_content_fingerprint TEXT NOT NULL DEFAULT '');" +
            "CREATE TABLE IF NOT EXISTS cached_mailboxes(" +
            "id TEXT PRIMARY KEY, account_id TEXT NOT NULL, remote_name TEXT NOT NULL, name TEXT NOT NULL, icon_name TEXT NOT NULL," +
            "role INTEGER NOT NULL, unread_count INTEGER NOT NULL DEFAULT 0, UNIQUE(account_id,remote_name));" +
            "CREATE TABLE IF NOT EXISTS pending_mutations(" +
            "message_id TEXT NOT NULL, account_id TEXT NOT NULL, mailbox_name TEXT NOT NULL, remote_uid TEXT NOT NULL," +
            "field INTEGER NOT NULL, value INTEGER NOT NULL, created_at INTEGER NOT NULL," +
            "PRIMARY KEY(message_id,field));" +
            "CREATE TABLE IF NOT EXISTS pending_transfers(" +
            "message_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, source_mailbox TEXT NOT NULL, destination_mailbox TEXT NOT NULL," +
            "remote_uid TEXT NOT NULL, copy INTEGER NOT NULL, created_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS pending_deletions(" +
            "message_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, mailbox_name TEXT NOT NULL," +
            "remote_uid TEXT NOT NULL, created_at INTEGER NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS pending_folder_purges(" +
            "account_id TEXT NOT NULL, mailbox_name TEXT NOT NULL, created_at INTEGER NOT NULL," +
            "PRIMARY KEY(account_id,mailbox_name));" +
            "CREATE TABLE IF NOT EXISTS message_attachments(" +
            "message_id TEXT NOT NULL, id TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, content_type TEXT NOT NULL, content_id TEXT NOT NULL DEFAULT ''," +
            "PRIMARY KEY(message_id,id), FOREIGN KEY(message_id) REFERENCES cached_messages(id) ON DELETE CASCADE);" +
            "CREATE TABLE IF NOT EXISTS message_header_index(" +
            "message_id TEXT NOT NULL, account_id TEXT NOT NULL, header_id TEXT NOT NULL," +
            "PRIMARY KEY(message_id,header_id), FOREIGN KEY(message_id) REFERENCES cached_messages(id) ON DELETE CASCADE);" +
            "CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(id UNINDEXED, sender, recipients, subject, body, tokenize='unicode61 remove_diacritics 2');");
        ensure_column ("cached_messages", "account_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "remote_uid", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "internet_message_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "in_reply_to", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "references_header", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "date_unix", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("cached_messages", "cc_recipients", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "security_status", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "flag_color", "TEXT NOT NULL DEFAULT 'red'");
        ensure_column ("cached_messages", "bcc_recipients", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "message_size", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("cached_messages", "reply_to", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "authentication_results", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "list_unsubscribe", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "list_unsubscribe_post", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "raw_headers", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("cached_messages", "managed_draft_identity", "TEXT NOT NULL DEFAULT ''");
        // This is the verified semantic fingerprint supplied by the Drafts MIME
        // conversion, not a hash reconstructed from lossy message-list fields.
        // It makes immediate no-Message-ID cancellation safe across UID reuse.
        ensure_column ("cached_messages", "draft_content_fingerprint",
            "TEXT NOT NULL DEFAULT ''");
        // Older builds ignored top-level text/plain and text/html MIME bodies
        // and cached only the server preview. A zero value makes those rows
        // eligible for the normal bounded sync backfill.
        ensure_column ("cached_messages", "content_extracted", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "references_header", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "body_html", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "body_format", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "security_protocol", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "sign_message", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "encrypt_message", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "security_identity", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "revision", "INTEGER NOT NULL DEFAULT 1");
        ensure_column ("drafts", "remote_mailbox", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "remote_uid", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "remote_revision", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "remote_internet_message_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "remote_content_fingerprint", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "remote_owned", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("drafts", "remote_sync_owner", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("drafts", "remote_sync_until", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("accounts", "authentication", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("accounts", "online_account_path", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("message_attachments", "content_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("message_attachments", "remote_part_index", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("draft_attachments", "content_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("draft_attachments", "remote_part_index", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "delivery_state", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "lease_owner", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("outbox", "lease_until", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "undo_until", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "undo_previous_state", "INTEGER NOT NULL DEFAULT -1");
        ensure_column ("outbox", "undo_previous_attempts", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "undo_previous_next_attempt_at", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("outbox", "undo_previous_last_error", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("pending_remote_draft_deletions", "completed_at",
            "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("pending_remote_draft_deletions", "suppress_reimport",
            "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("pending_remote_draft_deletions", "permanent_tombstone",
            "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("pending_remote_draft_deletions", "expected_fingerprint",
            "TEXT NOT NULL DEFAULT ''");
        migrate_remote_draft_deletion_identity ();
        // Upgrade deletion work created by builds that had no distinction
        // between generic duplicate cleanup and an explicit discard. A live
        // draft whose adopted provider identity matches the row is the one
        // unsafe case to suppress account-wide; everything else is an orphan
        // the old build had already committed to deleting. The preference
        // fence makes this inference a one-time migration, not startup policy.
        execute ("UPDATE pending_remote_draft_deletions AS p " +
            "SET suppress_reimport=1,permanent_tombstone=1 " +
            "WHERE NOT EXISTS(SELECT 1 FROM preferences " +
            "WHERE key='draft-tombstone-identity-v2') " +
            "AND NOT EXISTS(SELECT 1 FROM drafts d WHERE d.account_id=p.account_id " +
            "AND REPLACE(REPLACE(TRIM(d.remote_internet_message_id),'<',''),'>','')=" +
            "REPLACE(REPLACE(TRIM(p.expected_message_id),'<',''),'>',''));" +
            "INSERT OR IGNORE INTO preferences(key,value) " +
            "VALUES('draft-tombstone-identity-v2','1')");
        ensure_column ("mail_tasks", "reminder_at", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_tasks", "recurrence", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_tasks", "recurrence_interval", "INTEGER NOT NULL DEFAULT 1");
        ensure_column ("mail_tasks", "created_at", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_tasks", "completed_at", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_tasks", "reminder_sent_at", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_rules", "position", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_rules", "match_mode", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("mail_rules", "stop_processing", "INTEGER NOT NULL DEFAULT 0");
        migrate_cached_text_decoding ();
        normalize_mail_rule_positions ();
        execute ("DELETE FROM pending_remote_draft_deletions " +
            "WHERE suppress_reimport=1 AND permanent_tombstone=0 AND completed_at>0 " +
            "AND completed_at<=strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string () + ";" +
            "DELETE FROM pending_remote_draft_deletions " +
            "WHERE suppress_reimport=1 AND permanent_tombstone=0 AND completed_at=0 " +
            "AND mailbox_name='' AND remote_uid='' " +
            "AND created_at<=strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string ());
        // Older development builds indexed the negative managed-identity marker
        // for every ordinary message. Replace that low-selectivity index once
        // with a positive-identity-only index.
        execute ("DROP INDEX IF EXISTS cached_messages_managed_draft_identity;" +
            "CREATE INDEX IF NOT EXISTS cached_messages_mailbox_date ON cached_messages(mailbox_id,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_mailbox_unread_date ON cached_messages(mailbox_id,unread DESC,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_mailbox_flagged_date ON cached_messages(mailbox_id,flagged DESC,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_account_date ON cached_messages(account_id,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_account_mailbox_remote_uid ON cached_messages(account_id,mailbox_id,remote_uid);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_account_message_id ON cached_messages(account_id,internet_message_id);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_managed_draft_identity_positive " +
            "ON cached_messages(account_id,managed_draft_identity) " +
            "WHERE managed_draft_identity<>'' AND managed_draft_identity<>'!';" +
            "CREATE INDEX IF NOT EXISTS cached_messages_account_reply ON cached_messages(account_id,in_reply_to);" +
            "CREATE INDEX IF NOT EXISTS cached_mailboxes_role_id ON cached_mailboxes(role,id);" +
            "CREATE INDEX IF NOT EXISTS cached_mailboxes_account_role ON cached_mailboxes(account_id,role);" +
            "CREATE INDEX IF NOT EXISTS message_labels_label_message ON message_labels(label_id,message_id);" +
            "CREATE INDEX IF NOT EXISTS snoozed_messages_until ON snoozed_messages(until_unix);" +
            "CREATE INDEX IF NOT EXISTS message_header_index_lookup ON message_header_index(account_id,header_id);" +
            "CREATE INDEX IF NOT EXISTS drafts_remote_sync ON drafts(account_id,revision,remote_revision);" +
            "CREATE INDEX IF NOT EXISTS pending_remote_draft_deletions_account ON pending_remote_draft_deletions(account_id,id);" +
            "CREATE INDEX IF NOT EXISTS pending_remote_draft_deletions_identity ON pending_remote_draft_deletions(account_id,expected_message_id);" +
            "CREATE INDEX IF NOT EXISTS pending_remote_draft_deletions_fingerprint ON pending_remote_draft_deletions(account_id,mailbox_name,remote_uid,expected_fingerprint);" +
            "CREATE UNIQUE INDEX IF NOT EXISTS pending_remote_draft_deletions_message_unique " +
            "ON pending_remote_draft_deletions(account_id,mailbox_name,remote_uid,expected_message_id) " +
            "WHERE expected_message_id<>'';" +
            "CREATE UNIQUE INDEX IF NOT EXISTS pending_remote_draft_deletions_fingerprint_unique " +
            "ON pending_remote_draft_deletions(account_id,mailbox_name,remote_uid,expected_fingerprint) " +
            "WHERE expected_message_id='' AND expected_fingerprint<>'';" +
            "CREATE INDEX IF NOT EXISTS remote_draft_upload_attempts_account ON remote_draft_upload_attempts(account_id,expected_message_id);" +
            "CREATE INDEX IF NOT EXISTS outbox_delivery_schedule ON outbox(delivery_state,next_attempt_at,lease_until);" +
            "CREATE INDEX IF NOT EXISTS mail_tasks_due ON mail_tasks(completed,due_at);" +
            "CREATE INDEX IF NOT EXISTS mail_tasks_reminders ON mail_tasks(completed,reminder_at,reminder_sent_at);" +
            "CREATE INDEX IF NOT EXISTS mail_tasks_message ON mail_tasks(message_id,completed);");
        execute ("CREATE INDEX IF NOT EXISTS mail_rules_position ON mail_rules(position,id);" +
            "CREATE INDEX IF NOT EXISTS quick_steps_position ON quick_steps(position,id);" +
            "CREATE INDEX IF NOT EXISTS safe_senders_created ON safe_senders(created_at);");
    }

    public string preference (string key, string fallback = "") throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT value FROM preferences WHERE key=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare preference loading");
        statement.bind_text (1, key);
        int result = statement.step ();
        if (result == Sqlite.DONE) return fallback;
        if (result != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the preference");
        return statement.column_text (0);
    }

    public void set_preference (string key, string value) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare preference storage");
        statement.bind_text (1, key); statement.bind_text (2, value);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the preference");
    }

    public Gee.ArrayList<JunkRule> list_junk_rules () throws MailError {
        var rules = new Gee.ArrayList<JunkRule> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,kind,pattern FROM junk_rules ORDER BY kind,pattern", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare junk-rule loading");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            rules.add (new JunkRule (statement.column_int64 (0), (JunkRuleKind) statement.column_int (1), statement.column_text (2)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load junk rules");
        return rules;
    }

    public void add_junk_rule (JunkRuleKind kind, string value) throws MailError {
        string pattern = JunkRule.normalize (kind, value); Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT OR IGNORE INTO junk_rules(kind,pattern) VALUES(?,?)", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare junk-rule storage");
        statement.bind_int (1, (int) kind); statement.bind_text (2, pattern);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the junk rule");
    }

    public void remove_junk_rule (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM junk_rules WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare junk-rule removal");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not remove the junk rule");
    }

    public Gee.ArrayList<MailLabel> list_mail_labels () throws MailError {
        var result = new Gee.ArrayList<MailLabel> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,color FROM mail_labels ORDER BY name COLLATE NOCASE", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare label loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new MailLabel (statement.column_int64 (0), statement.column_text (1), statement.column_text (2)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load labels");
        return result;
    }

    public MailLabel create_mail_label (string name, string color = "#3584e4") throws MailError {
        string clean = name.strip ();
        if (clean == "" || clean.length > 64) throw new MailError.STORAGE ("Enter a label name up to 64 characters");
        if (!Regex.match_simple ("^#[0-9A-Fa-f]{6}$", color)) color = "#3584e4";
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO mail_labels(name,color) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET color=excluded.color RETURNING id,name,color", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare label storage");
        statement.bind_text (1, clean); statement.bind_text (2, color);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not save the label");
        return new MailLabel (statement.column_int64 (0), statement.column_text (1), statement.column_text (2));
    }

    public void delete_mail_label (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM mail_labels WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare label deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete the label");
    }

    public Gee.ArrayList<MailLabel> labels_for_message (string message_id) throws MailError {
        var result = new Gee.ArrayList<MailLabel> (); Sqlite.Statement statement;
        const string sql = "SELECT l.id,l.name,l.color FROM mail_labels l JOIN message_labels ml ON ml.label_id=l.id WHERE ml.message_id=? ORDER BY l.name COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare message-label loading");
        statement.bind_text (1, message_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new MailLabel (statement.column_int64 (0), statement.column_text (1), statement.column_text (2)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load message labels");
        return result;
    }

    public void set_message_label (string message_id, int64 label_id, bool enabled) throws MailError {
        Sqlite.Statement statement; string sql = enabled ?
            "INSERT OR IGNORE INTO message_labels(message_id,label_id) VALUES(?,?)" :
            "DELETE FROM message_labels WHERE message_id=? AND label_id=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the message label change");
        statement.bind_text (1, message_id); statement.bind_int64 (2, label_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the message label");
    }

    public Gee.ArrayList<MailRule> list_mail_rules () throws MailError {
        var result = new Gee.ArrayList<MailRule> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,account_id,field,pattern,action,value,enabled,position,match_mode,stop_processing FROM mail_rules ORDER BY position,id", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mail-rule loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW) {
            var rule = new MailRule (statement.column_int64 (0), statement.column_text (1), statement.column_text (2),
                (MailRuleField) statement.column_int (3), statement.column_text (4),
                (MailRuleAction) statement.column_int (5), statement.column_text (6), statement.column_int (7) != 0,
                statement.column_int (8), (MailRuleMatchMode) statement.column_int (9), statement.column_int (10) != 0);
            load_mail_rule_parts (rule); result.add (rule);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load mail rules"); return result;
    }

    private void load_mail_rule_parts (MailRule rule) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT field,operator,pattern,is_exception FROM mail_rule_conditions WHERE rule_id=? ORDER BY is_exception,position", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare rule-condition loading");
        statement.bind_int64 (1, rule.id); int row; bool has_parts = false;
        while ((row = statement.step ()) == Sqlite.ROW) {
            if (!has_parts) { rule.replace_legacy_parts (); has_parts = true; }
            var condition = new MailRuleCondition ((MailRuleField) statement.column_int (0),
                statement.column_text (2), (MailRuleOperator) statement.column_int (1));
            if (statement.column_int (3) != 0) rule.exceptions.add (condition);
            else rule.conditions.add (condition);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load rule conditions");
        if (!has_parts) return;
        if (database.prepare_v2 ("SELECT action,value FROM mail_rule_actions WHERE rule_id=? ORDER BY position", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare rule-action loading");
        statement.bind_int64 (1, rule.id);
        while ((row = statement.step ()) == Sqlite.ROW)
            rule.operations.add (new MailRuleOperation ((MailRuleAction) statement.column_int (0), statement.column_text (1)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load rule actions");
    }

    public void add_mail_rule (string name, string account_id, MailRuleField field, string pattern,
                               MailRuleAction action, string value = "") throws MailError {
        string clean_name = name.strip (); string clean_pattern = pattern.strip ();
        if (clean_name == "" || clean_pattern == "") throw new MailError.STORAGE ("Rule name and match text are required");
        save_mail_rule (new MailRule (0, clean_name, account_id.strip (), field,
            clean_pattern, action, value.strip ()));
    }

    public MailRule save_mail_rule (MailRule rule) throws MailError {
        if (rule.name.strip () == "" || rule.conditions.size == 0 || rule.operations.size == 0)
            throw new MailError.STORAGE ("A rule needs a name, condition, and action");
        foreach (var condition in rule.conditions)
            if (condition.pattern.strip () == "")
                throw new MailError.STORAGE ("Every rule condition needs a value");
        foreach (var exception in rule.exceptions)
            if (exception.pattern.strip () == "")
                throw new MailError.STORAGE ("Every rule exception needs a value");
        validate_rule_operations (rule.operations);
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement; int64 id = rule.id;
            var first_condition = rule.conditions[0]; var first_action = rule.operations[0];
            if (id <= 0) {
                const string insert = "INSERT INTO mail_rules(name,account_id,field,pattern,action,value,enabled,position,match_mode,stop_processing) " +
                    "VALUES(?,?,?,?,?,?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM mail_rules),?,?) RETURNING id,position";
                if (database.prepare_v2 (insert, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare rule creation");
                statement.bind_text (1, rule.name.strip ()); statement.bind_text (2, rule.account_id.strip ());
                statement.bind_int (3, (int) first_condition.field); statement.bind_text (4, first_condition.pattern);
                statement.bind_int (5, (int) first_action.action); statement.bind_text (6, first_action.value);
                statement.bind_int (7, rule.enabled ? 1 : 0); statement.bind_int (8, (int) rule.match_mode);
                statement.bind_int (9, rule.stop_processing ? 1 : 0);
                if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not create the rule");
                id = statement.column_int64 (0); rule.position = statement.column_int (1);
                statement.reset ();
            } else {
                const string update = "UPDATE mail_rules SET name=?,account_id=?,field=?,pattern=?,action=?,value=?,enabled=?,position=?,match_mode=?,stop_processing=? WHERE id=?";
                if (database.prepare_v2 (update, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare rule editing");
                statement.bind_text (1, rule.name.strip ()); statement.bind_text (2, rule.account_id.strip ());
                statement.bind_int (3, (int) first_condition.field); statement.bind_text (4, first_condition.pattern);
                statement.bind_int (5, (int) first_action.action); statement.bind_text (6, first_action.value);
                statement.bind_int (7, rule.enabled ? 1 : 0); statement.bind_int (8, rule.position);
                statement.bind_int (9, (int) rule.match_mode); statement.bind_int (10, rule.stop_processing ? 1 : 0);
                statement.bind_int64 (11, id);
                if (statement.step () != Sqlite.DONE || database.changes () != 1)
                    throw new MailError.STORAGE ("The rule no longer exists");
            }
            var saved = new MailRule (id, rule.name.strip (), rule.account_id.strip (), first_condition.field,
                first_condition.pattern, first_action.action, first_action.value, rule.enabled, rule.position,
                rule.match_mode, rule.stop_processing);
            saved.replace_legacy_parts (); saved.conditions.add_all (rule.conditions);
            saved.exceptions.add_all (rule.exceptions); saved.operations.add_all (rule.operations);
            save_mail_rule_parts (saved); execute ("COMMIT"); return saved;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private void save_mail_rule_parts (MailRule rule) throws MailError {
        Sqlite.Statement statement;
        foreach (var sql in new string[] { "DELETE FROM mail_rule_conditions WHERE rule_id=?", "DELETE FROM mail_rule_actions WHERE rule_id=?" }) {
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare rule detail replacement");
            statement.bind_int64 (1, rule.id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not replace rule details");
        }
        int position = 0;
        foreach (var condition in rule.conditions) save_rule_condition (rule.id, position++, condition, false);
        position = 0;
        foreach (var exception in rule.exceptions) save_rule_condition (rule.id, position++, exception, true);
        position = 0;
        foreach (var operation in rule.operations) {
            if (database.prepare_v2 ("INSERT INTO mail_rule_actions(rule_id,position,action,value) VALUES(?,?,?,?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare rule-action storage");
            statement.bind_int64 (1, rule.id); statement.bind_int (2, position++);
            statement.bind_int (3, (int) operation.action); statement.bind_text (4, operation.value);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save a rule action");
        }
    }

    private void save_rule_condition (int64 rule_id, int position, MailRuleCondition condition,
                                      bool exception) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO mail_rule_conditions(rule_id,position,field,operator,pattern,is_exception) VALUES(?,?,?,?,?,?)", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare rule-condition storage");
        statement.bind_int64 (1, rule_id); statement.bind_int (2, position);
        statement.bind_int (3, (int) condition.field); statement.bind_int (4, (int) condition.operator);
        statement.bind_text (5, condition.pattern); statement.bind_int (6, exception ? 1 : 0);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save a rule condition");
    }

    private static void validate_rule_operations (Gee.List<MailRuleOperation> operations) throws MailError {
        bool terminal_transfer_seen = false;
        foreach (var operation in operations) {
            if ((operation.action == MailRuleAction.LABEL || operation.action == MailRuleAction.MOVE ||
                 operation.action == MailRuleAction.COPY) && operation.value.strip () == "")
                throw new MailError.STORAGE ("Label, move, and copy actions require a destination");
            bool terminal_transfer = operation.action == MailRuleAction.ARCHIVE ||
                operation.action == MailRuleAction.TRASH ||
                operation.action == MailRuleAction.MOVE;
            if (terminal_transfer && terminal_transfer_seen)
                throw new MailError.STORAGE (
                    "A rule or Quick Step can move a message only once");
            if (operation.action == MailRuleAction.COPY && terminal_transfer_seen)
                throw new MailError.STORAGE (
                    "Place copy actions before the move action");
            if (terminal_transfer) terminal_transfer_seen = true;
        }
    }

    public void set_mail_rule_enabled (int64 id, bool enabled) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE mail_rules SET enabled=? WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the rule toggle");
        statement.bind_int (1, enabled ? 1 : 0); statement.bind_int64 (2, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the rule");
    }

    public void move_mail_rule (int64 id, int direction) throws MailError {
        if (direction == 0) return;
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("SELECT position FROM mail_rules WHERE id=?", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare rule ordering");
            statement.bind_int64 (1, id);
            if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("The rule no longer exists");
            int position = statement.column_int (0); string comparison = direction < 0 ? "<" : ">";
            string ordering = direction < 0 ? "DESC" : "ASC";
            string neighbor_sql = "SELECT id,position FROM mail_rules WHERE position%s? ORDER BY position %s,id %s LIMIT 1".printf (
                comparison, ordering, ordering);
            if (database.prepare_v2 (neighbor_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare neighboring rule lookup");
            statement.bind_int (1, position);
            if (statement.step () == Sqlite.ROW) {
                int64 neighbor_id = statement.column_int64 (0); int neighbor_position = statement.column_int (1);
                if (database.prepare_v2 ("UPDATE mail_rules SET position=CASE id WHEN ? THEN ? WHEN ? THEN ? END WHERE id IN (?,?)", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare rule reordering");
                statement.bind_int64 (1, id); statement.bind_int (2, neighbor_position);
                statement.bind_int64 (3, neighbor_id); statement.bind_int (4, position);
                statement.bind_int64 (5, id); statement.bind_int64 (6, neighbor_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not reorder the rule");
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void remove_mail_rule (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM mail_rules WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mail-rule deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete the mail rule");
    }

    public Gee.ArrayList<QuickStep> list_quick_steps () throws MailError {
        var result = new Gee.ArrayList<QuickStep> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,account_id,position FROM quick_steps ORDER BY position,id", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Quick Step loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW) {
            var step = new QuickStep (statement.column_int64 (0), statement.column_text (1),
                statement.column_text (2), statement.column_int (3));
            Sqlite.Statement actions;
            if (database.prepare_v2 ("SELECT action,value FROM quick_step_actions WHERE quick_step_id=? ORDER BY position", -1, out actions) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare Quick Step actions");
            actions.bind_int64 (1, step.id); int action_row;
            while ((action_row = actions.step ()) == Sqlite.ROW)
                step.operations.add (new MailRuleOperation ((MailRuleAction) actions.column_int (0), actions.column_text (1)));
            if (action_row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Quick Step actions");
            result.add (step);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Quick Steps");
        return result;
    }

    public QuickStep add_quick_step (string name, string account_id,
                                     Gee.List<MailRuleOperation> operations) throws MailError {
        string clean = name.strip (); if (clean == "" || operations.size == 0)
            throw new MailError.STORAGE ("A Quick Step needs a name and at least one action");
        validate_rule_operations (operations); execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            const string insert = "INSERT INTO quick_steps(name,account_id,position) VALUES(?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM quick_steps)) RETURNING id,position";
            if (database.prepare_v2 (insert, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare Quick Step creation");
            statement.bind_text (1, clean); statement.bind_text (2, account_id.strip ());
            if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not create the Quick Step");
            var step = new QuickStep (statement.column_int64 (0), clean, account_id.strip (), statement.column_int (1));
            statement.reset ();
            int position = 0;
            foreach (var operation in operations) {
                step.operations.add (operation);
                if (database.prepare_v2 ("INSERT INTO quick_step_actions(quick_step_id,position,action,value) VALUES(?,?,?,?)", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare Quick Step action storage");
                statement.bind_int64 (1, step.id); statement.bind_int (2, position++);
                statement.bind_int (3, (int) operation.action); statement.bind_text (4, operation.value);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the Quick Step action");
            }
            execute ("COMMIT"); return step;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void remove_quick_step (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM quick_steps WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Quick Step deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete the Quick Step");
    }

    public Gee.ArrayList<SmartMailbox> list_smart_mailboxes () throws MailError {
        var result = new Gee.ArrayList<SmartMailbox> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,query FROM smart_mailboxes ORDER BY name COLLATE NOCASE", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Smart Mailbox loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new SmartMailbox (statement.column_int64 (0), statement.column_text (1), statement.column_text (2)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Smart Mailboxes");
        return result;
    }

    public SmartMailbox? find_smart_mailbox (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,query FROM smart_mailboxes WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Smart Mailbox lookup");
        statement.bind_int64 (1, id);
        int row = statement.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not find Smart Mailbox");
        return new SmartMailbox (statement.column_int64 (0), statement.column_text (1), statement.column_text (2));
    }

    public SmartMailbox add_smart_mailbox (string name, string query) throws MailError {
        var clean_name = name.strip (); var clean_query = query.strip ();
        if (clean_name == "" || clean_query == "") throw new MailError.STORAGE ("Smart Mailbox name and search are required");
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO smart_mailboxes(name,query) VALUES(?,?) RETURNING id", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Smart Mailbox storage");
        statement.bind_text (1, clean_name); statement.bind_text (2, clean_query);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not save Smart Mailbox");
        return new SmartMailbox (statement.column_int64 (0), clean_name, clean_query);
    }

    public void remove_smart_mailbox (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM smart_mailboxes WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Smart Mailbox deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete Smart Mailbox");
    }

    private static MailTask mail_task_from_row (Sqlite.Statement statement) {
        return new MailTask (statement.column_int64 (0), statement.column_text (1), statement.column_text (2),
            statement.column_int (3) != 0, statement.column_text (4), statement.column_text (5),
            statement.column_int64 (6), (TaskRecurrence) statement.column_int (7), statement.column_int (8),
            statement.column_int64 (9), statement.column_int64 (10), statement.column_int64 (11));
    }

    private const string MAIL_TASK_COLUMNS =
        "id,title,due_at,completed,notes,message_id,reminder_at,recurrence,recurrence_interval,created_at,completed_at,reminder_sent_at";

    public Gee.ArrayList<MailTask> list_mail_tasks () throws MailError {
        var result = new Gee.ArrayList<MailTask> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT " + MAIL_TASK_COLUMNS + " FROM mail_tasks ORDER BY completed,due_at,title COLLATE NOCASE", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (mail_task_from_row (statement));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load tasks");
        return result;
    }

    public MailTask? find_mail_task (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT " + MAIL_TASK_COLUMNS + " FROM mail_tasks WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task lookup");
        statement.bind_int64 (1, id); int row = statement.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the task");
        return mail_task_from_row (statement);
    }

    public void add_mail_task (string title, string due_at, string notes = "", string message_id = "") throws MailError {
        create_mail_task (title, due_at, notes, message_id);
    }

    public MailTask create_mail_task (string title, string due_at, string notes = "", string message_id = "",
                                      int64 reminder_at = 0, TaskRecurrence recurrence = TaskRecurrence.NONE,
                                      int recurrence_interval = 1) throws MailError {
        if (title.strip () == "") throw new MailError.STORAGE ("Task title is required");
        Sqlite.Statement statement;
        const string sql = "INSERT INTO mail_tasks(title,due_at,completed,notes,message_id,reminder_at,recurrence,recurrence_interval,created_at,completed_at,reminder_sent_at) " +
            "VALUES(?,?,0,?,?,?,?,?,strftime('%s','now'),0,0) RETURNING " + MAIL_TASK_COLUMNS;
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task storage");
        statement.bind_text (1, title.strip ()); statement.bind_text (2, due_at.strip ());
        statement.bind_text (3, notes.strip ()); statement.bind_text (4, message_id.strip ());
        statement.bind_int64 (5, int64.max (0, reminder_at)); statement.bind_int (6, (int) recurrence);
        statement.bind_int (7, int.max (1, recurrence_interval));
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not save task");
        return mail_task_from_row (statement);
    }

    public MailTask update_mail_task (int64 id, string title, string due_at, string notes,
                                      int64 reminder_at, TaskRecurrence recurrence,
                                      int recurrence_interval) throws MailError {
        if (title.strip () == "") throw new MailError.STORAGE ("Task title is required");
        Sqlite.Statement statement;
        const string sql = "UPDATE mail_tasks SET title=?,due_at=?,notes=?,reminder_at=?,recurrence=?,recurrence_interval=?," +
            "reminder_sent_at=CASE WHEN reminder_at<>? THEN 0 ELSE reminder_sent_at END WHERE id=? RETURNING " + MAIL_TASK_COLUMNS;
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task editing");
        int64 bounded_reminder = int64.max (0, reminder_at);
        statement.bind_text (1, title.strip ()); statement.bind_text (2, due_at.strip ());
        statement.bind_text (3, notes.strip ()); statement.bind_int64 (4, bounded_reminder);
        statement.bind_int (5, (int) recurrence); statement.bind_int (6, int.max (1, recurrence_interval));
        statement.bind_int64 (7, bounded_reminder); statement.bind_int64 (8, id);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not update the task");
        return mail_task_from_row (statement);
    }

    public void set_mail_task_completed (int64 id, bool completed) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE mail_tasks SET completed=?,completed_at=CASE WHEN ? THEN strftime('%s','now') ELSE 0 END WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task update");
        statement.bind_int (1, completed ? 1 : 0); statement.bind_int (2, completed ? 1 : 0);
        statement.bind_int64 (3, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update task");
    }

    // Completing a recurring occurrence and creating its successor is one
    // durable operation. A crash can therefore never silently end a series.
    public MailTask? complete_mail_task_occurrence (int64 id, int64 completed_at) throws MailError {
        var task = find_mail_task (id);
        if (task == null) throw new MailError.STORAGE ("The task no longer exists");
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("UPDATE mail_tasks SET completed=1,completed_at=? WHERE id=?", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare task completion");
            statement.bind_int64 (1, completed_at); statement.bind_int64 (2, id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not complete the task");

            MailTask? next = null;
            if (task.recurrence != TaskRecurrence.NONE) {
                string next_due = task.next_due_date ();
                int64 next_reminder = 0;
                var old_due = MailTask.parse_due_date (task.due_at);
                var new_due = MailTask.parse_due_date (next_due);
                if (task.reminder_at > 0 && old_due != null && new_due != null)
                    next_reminder = new_due.to_unix () + (task.reminder_at - old_due.to_unix ());
                const string insert_sql = "INSERT INTO mail_tasks(title,due_at,completed,notes,message_id,reminder_at,recurrence,recurrence_interval,created_at,completed_at,reminder_sent_at) " +
                    "VALUES(?,?,0,?,?,?,?,?,?,0,0) RETURNING " + MAIL_TASK_COLUMNS;
                if (database.prepare_v2 (insert_sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the next recurring task");
                statement.bind_text (1, task.title); statement.bind_text (2, next_due);
                statement.bind_text (3, task.notes); statement.bind_text (4, task.message_id);
                statement.bind_int64 (5, next_reminder); statement.bind_int (6, (int) task.recurrence);
                statement.bind_int (7, task.recurrence_interval); statement.bind_int64 (8, completed_at);
                if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not create the next recurring task");
                next = mail_task_from_row (statement);
                // RETURNING keeps the SQLite statement active after its ROW.
                // Consume DONE before COMMIT or SQLite correctly refuses to
                // commit while the cursor is still in progress.
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not finish the next recurring task");
            }
            execute ("COMMIT");
            return next;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public Gee.ArrayList<MailTask> due_mail_task_reminders (int64 now) throws MailError {
        var result = new Gee.ArrayList<MailTask> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT " + MAIL_TASK_COLUMNS +
            " FROM mail_tasks WHERE completed=0 AND reminder_at>0 AND reminder_at<=? AND reminder_sent_at=0 ORDER BY reminder_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task reminders");
        statement.bind_int64 (1, now); int row;
        while ((row = statement.step ()) == Sqlite.ROW) result.add (mail_task_from_row (statement));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load task reminders");
        return result;
    }

    public void mark_mail_task_reminder_sent (int64 id, int64 sent_at) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE mail_tasks SET reminder_sent_at=? WHERE id=? AND completed=0", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task reminder delivery");
        statement.bind_int64 (1, sent_at); statement.bind_int64 (2, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not record task reminder delivery");
    }

    public MailTask? open_mail_task_for_message (string message_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT " + MAIL_TASK_COLUMNS +
            " FROM mail_tasks WHERE message_id=? AND completed=0 ORDER BY due_at LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare linked task lookup");
        statement.bind_text (1, message_id); int row = statement.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the linked task");
        return mail_task_from_row (statement);
    }

    public int incomplete_mail_task_count_for_message (string message_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM mail_tasks WHERE message_id=? AND completed=0", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare linked task counting");
        statement.bind_text (1, message_id);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count linked tasks");
        return statement.column_int (0);
    }

    public int mail_task_count (bool due_today = false, int64 now = 0) throws MailError {
        Sqlite.Statement statement;
        string sql = "SELECT COUNT(*) FROM mail_tasks WHERE completed=0";
        if (due_today) sql += " AND due_at<=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare task counting");
        if (due_today) statement.bind_text (1, MailTask.date_for_unix (now > 0 ? now : new DateTime.now_local ().to_unix ()));
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count tasks");
        return statement.column_int (0);
    }

    public void remove_mail_task (int64 id) throws MailError {
        delete_bound_int64 ("DELETE FROM mail_tasks WHERE id=?", id);
    }

    public void snooze_message (string message_id, int64 until_unix) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO snoozed_messages(message_id,until_unix) VALUES(?,?) ON CONFLICT(message_id) DO UPDATE SET until_unix=excluded.until_unix", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare message snoozing");
        statement.bind_text (1, message_id); statement.bind_int64 (2, until_unix);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not snooze the message");
    }

    public void unsnooze_message (string message_id) throws MailError {
        delete_bound ("DELETE FROM snoozed_messages WHERE message_id=?", message_id);
    }

    public bool message_is_snoozed (string message_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM snoozed_messages WHERE message_id=? AND until_unix>strftime('%s','now')", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect message snoozing");
        statement.bind_text (1, message_id); int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE) throw new MailError.STORAGE ("Could not inspect message snoozing");
        return row == Sqlite.ROW;
    }

    public Gee.ArrayList<MailTemplate> list_mail_templates () throws MailError {
        var result = new Gee.ArrayList<MailTemplate> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,name,subject,body_text,body_html,body_format FROM mail_templates ORDER BY name COLLATE NOCASE", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare template loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new MailTemplate (statement.column_int64 (0), statement.column_text (1), statement.column_text (2),
                statement.column_text (3), statement.column_text (4), statement.column_text (5)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load templates"); return result;
    }

    public MailTemplate save_mail_template (string name, Draft draft) throws MailError {
        string clean = name.strip (); if (clean == "") throw new MailError.STORAGE ("Enter a template name");
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO mail_templates(name,subject,body_text,body_html,body_format) VALUES(?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET subject=excluded.subject,body_text=excluded.body_text,body_html=excluded.body_html,body_format=excluded.body_format RETURNING id", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare template storage");
        statement.bind_text (1, clean); statement.bind_text (2, draft.subject); statement.bind_text (3, draft.body_text);
        statement.bind_text (4, draft.body_html); statement.bind_text (5, draft.body_format);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not save the template");
        return new MailTemplate (statement.column_int64 (0), clean, draft.subject, draft.body_text, draft.body_html, draft.body_format);
    }

    public void delete_mail_template (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM mail_templates WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare template deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete the template");
    }

    public VacationSettings? vacation_settings (string account_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT enabled,starts_at,ends_at,subject,body FROM vacation_settings WHERE account_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare vacation settings");
        statement.bind_text (1, account_id); int row = statement.step (); if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not load vacation settings");
        return new VacationSettings (account_id, statement.column_int (0) != 0, statement.column_int64 (1),
            statement.column_int64 (2), statement.column_text (3), statement.column_text (4));
    }

    public void save_vacation_settings (VacationSettings settings) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO vacation_settings(account_id,enabled,starts_at,ends_at,subject,body) VALUES(?,?,?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET enabled=excluded.enabled,starts_at=excluded.starts_at,ends_at=excluded.ends_at,subject=excluded.subject,body=excluded.body", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare vacation setting storage");
        statement.bind_text (1, settings.account_id); statement.bind_int (2, settings.enabled ? 1 : 0);
        statement.bind_int64 (3, settings.starts_at); statement.bind_int64 (4, settings.ends_at);
        statement.bind_text (5, settings.subject); statement.bind_text (6, settings.body);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save vacation settings");
    }

    public bool vacation_replied_to (string account_id, string sender) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM vacation_reply_log WHERE account_id=? AND sender=? COLLATE NOCASE LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect vacation reply history");
        statement.bind_text (1, account_id); statement.bind_text (2, sender); int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE) throw new MailError.STORAGE ("Could not inspect vacation reply history");
        return row == Sqlite.ROW;
    }

    public void record_vacation_reply (string account_id, string sender) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT OR REPLACE INTO vacation_reply_log(account_id,sender,replied_at) VALUES(?,?,strftime('%s','now'))", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare vacation reply history");
        statement.bind_text (1, account_id); statement.bind_text (2, sender);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save vacation reply history");
    }

    public Gee.Set<string> referenced_attachment_paths () throws MailError {
        var result = new Gee.HashSet<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT path FROM draft_attachments UNION SELECT path FROM message_attachments", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare attachment reference loading");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) result.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load attachment references");
        return result;
    }

    public void forget_attachment_path (string path) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            delete_bound ("DELETE FROM draft_attachments WHERE path=?", path);
            delete_bound ("DELETE FROM message_attachments WHERE path=?", path);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void checkpoint () throws MailError { execute ("PRAGMA wal_checkpoint(PASSIVE)"); }

    public Gee.List<Recipient> recipient_candidates () throws MailError {
        var result = new Gee.ArrayList<Recipient> (); var seen = new Gee.HashSet<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT sender_name,sender_address,recipients,cc_recipients FROM cached_messages ORDER BY rowid DESC LIMIT ?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare correspondent loading");
        statement.bind_int (1, RECIPIENT_CANDIDATE_MESSAGE_LIMIT);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            add_recipient_candidate (result, seen, statement.column_text (0), statement.column_text (1));
            try {
                foreach (var recipient in RecipientParser.parse (statement.column_text (2)))
                    add_recipient_candidate (result, seen, recipient.name, recipient.address);
            } catch (Error error) { }
            try {
                foreach (var recipient in RecipientParser.parse (statement.column_text (3)))
                    add_recipient_candidate (result, seen, recipient.name, recipient.address);
            } catch (Error error) { }
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load correspondents");
        return result;
    }

    private static void add_recipient_candidate (Gee.ArrayList<Recipient> result, Gee.Set<string> seen,
                                                 string name, string address) {
        string normalized = address.strip ().down ();
        if (!RecipientParser.is_valid_address (normalized) || seen.contains (normalized)) return;
        seen.add (normalized); result.add (new Recipient (name.strip (), normalized));
    }

    private void ensure_column (string table, string column, string definition) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("PRAGMA table_info(" + table + ")", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect the mail cache schema");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            if (statement.column_text (1) == column) return;
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not inspect the mail cache schema");
        execute ("ALTER TABLE " + table + " ADD COLUMN " + column + " " + definition);
    }

    private void migrate_remote_draft_deletion_identity () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT sql FROM sqlite_master " +
                "WHERE type='table' AND name='pending_remote_draft_deletions'",
                -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect remote draft cleanup identity storage");
        int row = statement.step ();
        if (row != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not inspect remote draft cleanup identity storage");
        string definition = statement.column_text (0).down ().replace (" ", "")
            .replace ("\n", "").replace ("\t", "");
        statement.reset ();
        // Older databases made Message-ID alone part of the table constraint.
        // That collapses two distinct no-ID drafts when a provider reuses a
        // UID. Partial indexes below preserve the right identity semantics:
        // Message-ID when present, otherwise exact content fingerprint.
        if (!definition.contains (
                "unique(account_id,mailbox_name,remote_uid,expected_message_id)"))
            return;
        execute ("BEGIN IMMEDIATE");
        try {
            execute ("ALTER TABLE pending_remote_draft_deletions " +
                "RENAME TO pending_remote_draft_deletions_identity_v3;" +
                "CREATE TABLE pending_remote_draft_deletions(" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL," +
                "mailbox_name TEXT NOT NULL,remote_uid TEXT NOT NULL," +
                "expected_message_id TEXT NOT NULL," +
                "expected_fingerprint TEXT NOT NULL DEFAULT ''," +
                "created_at INTEGER NOT NULL,completed_at INTEGER NOT NULL DEFAULT 0," +
                "suppress_reimport INTEGER NOT NULL DEFAULT 0," +
                "permanent_tombstone INTEGER NOT NULL DEFAULT 0);" +
                "INSERT INTO pending_remote_draft_deletions(" +
                "id,account_id,mailbox_name,remote_uid,expected_message_id," +
                "expected_fingerprint,created_at,completed_at,suppress_reimport," +
                "permanent_tombstone) SELECT id,account_id,mailbox_name,remote_uid," +
                "expected_message_id,expected_fingerprint,created_at,completed_at," +
                "suppress_reimport,permanent_tombstone FROM " +
                "pending_remote_draft_deletions_identity_v3;" +
                "DROP TABLE pending_remote_draft_deletions_identity_v3;COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private void migrate_cached_text_decoding () throws MailError {
        Sqlite.Statement version_statement;
        if (database.prepare_v2 ("SELECT COALESCE(MAX(version),1) FROM schema_version",
                -1, out version_statement) != Sqlite.OK ||
            version_statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not inspect the mail cache version");
        if (version_statement.column_int (0) >= 2) return;
        version_statement.reset ();

        execute ("BEGIN IMMEDIATE");
        try {
            // Older MIME extraction decoded transfer encodings but did not
            // convert the declared character set. make_valid() permanently
            // replaced those bytes with U+FFFD. Only affected rows are made
            // eligible for the normal bounded IMAP content backfill.
            Sqlite.Statement repair;
            if (database.prepare_v2 (
                    "UPDATE cached_messages SET content_extracted=0 " +
                    "WHERE instr(body,?)>0 OR instr(body_html,?)>0",
                    -1, out repair) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare cached text repair");
            repair.bind_text (1, "�"); repair.bind_text (2, "�");
            if (repair.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not schedule cached text repair");
            execute ("UPDATE schema_version SET version=2;COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private void normalize_mail_rule_positions () throws MailError {
        Sqlite.Statement statement;
        const string inspect = "SELECT COUNT(*),COUNT(DISTINCT position)," +
            "COALESCE(MIN(position),0),COALESCE(MAX(position),-1) FROM mail_rules";
        if (database.prepare_v2 (inspect, -1, out statement) != Sqlite.OK ||
            statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not inspect mail-rule ordering");
        int count = statement.column_int (0);
        if (count == statement.column_int (1) &&
            (count == 0 || (statement.column_int (2) == 0 &&
             statement.column_int (3) == count - 1))) return;
        statement.reset ();

        // Pre-advanced-rule databases gave every migrated row position zero.
        // Snapshot the old (position,id) order first so updates cannot affect
        // the ranking that later updates observe, and replace it atomically.
        execute ("BEGIN IMMEDIATE");
        try {
            execute ("CREATE TEMP TABLE mail_rule_position_upgrade(" +
                "id INTEGER PRIMARY KEY,new_position INTEGER NOT NULL);" +
                "INSERT INTO mail_rule_position_upgrade(id,new_position) " +
                "SELECT id,ROW_NUMBER() OVER (ORDER BY position,id)-1 FROM mail_rules;" +
                "UPDATE mail_rules SET position=(SELECT new_position FROM " +
                "mail_rule_position_upgrade WHERE id=mail_rules.id);" +
                "DROP TABLE mail_rule_position_upgrade;COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private void execute (string sql) throws MailError {
        string? message = null;
        if (database.exec (sql, null, out message) != Sqlite.OK)
            throw new MailError.STORAGE (message ?? "The mail cache could not be updated");
    }

    public void save_draft (Draft draft) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            ensure_draft_mutable (draft.id, false);
            save_draft_rows (draft);
            execute ("COMMIT"); draft.mark_saved ();
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
        notify_remote_draft_work (draft.account_id);
    }

    private void save_draft_rows (Draft draft) throws MailError {
        Sqlite.Statement statement;
        const string sql = "INSERT INTO drafts(id,account_id,recipients_to,cc,bcc,subject,body_text,in_reply_to,references_header,modified_at,body_html,body_format,security_protocol,sign_message,encrypt_message,security_identity,revision) " +
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET " +
            "account_id=excluded.account_id,recipients_to=excluded.recipients_to,cc=excluded.cc,bcc=excluded.bcc,subject=excluded.subject," +
            "body_text=excluded.body_text,in_reply_to=excluded.in_reply_to,references_header=excluded.references_header,modified_at=excluded.modified_at," +
            "body_html=excluded.body_html,body_format=excluded.body_format,security_protocol=excluded.security_protocol,sign_message=excluded.sign_message," +
            "encrypt_message=excluded.encrypt_message,security_identity=excluded.security_identity,revision=excluded.revision," +
            "remote_owned=CASE WHEN excluded.revision>drafts.remote_revision AND drafts.remote_uid<>'' THEN 1 ELSE drafts.remote_owned END " +
            "WHERE excluded.revision>=drafts.revision";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare draft save");
        statement.bind_text (1, draft.id); statement.bind_text (2, draft.account_id); statement.bind_text (3, draft.to);
        statement.bind_text (4, draft.cc); statement.bind_text (5, draft.bcc); statement.bind_text (6, draft.subject);
        statement.bind_text (7, draft.body_text); statement.bind_text (8, draft.in_reply_to); statement.bind_text (9, draft.references); statement.bind_int64 (10, draft.modified_at);
        statement.bind_text (11, draft.body_html); statement.bind_text (12, draft.body_format);
        statement.bind_int (13, (int) draft.security_protocol); statement.bind_int (14, draft.sign_message ? 1 : 0);
        statement.bind_int (15, draft.encrypt_message ? 1 : 0); statement.bind_text (16, draft.security_identity);
        statement.bind_int64 (17, int64.max (1, draft.revision));
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the draft");
        if (database.changes () != 1)
            throw new MailError.STORAGE ("A newer copy of this draft was already saved");
        if (database.prepare_v2 ("DELETE FROM draft_attachments WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare attachment storage");
        statement.bind_text (1, draft.id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update draft attachments");
        foreach (var attachment in draft.attachments) {
            if (database.prepare_v2 ("INSERT INTO draft_attachments(draft_id,id,path,name,size,content_type,content_id,remote_part_index) VALUES(?,?,?,?,?,?,?,?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare attachment storage");
            statement.bind_text (1, draft.id); statement.bind_text (2, attachment.id); statement.bind_text (3, attachment.path);
            statement.bind_text (4, attachment.name); statement.bind_int64 (5, attachment.size); statement.bind_text (6, attachment.content_type);
            statement.bind_text (7, attachment.content_id);
            statement.bind_int (8, attachment.remote_part_index);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save a draft attachment");
        }
    }

    public Draft? load_draft (string id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT account_id,recipients_to,cc,bcc,subject,body_text,in_reply_to,references_header,modified_at,body_html,body_format,security_protocol,sign_message,encrypt_message,security_identity,revision,remote_mailbox,remote_uid,remote_revision,remote_internet_message_id,remote_content_fingerprint,remote_owned FROM drafts WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare draft load");
        statement.bind_text (1, id);
        int result = statement.step (); if (result == Sqlite.DONE) return null;
        if (result != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the draft");
        var draft = new Draft (statement.column_text (0), id);
        draft.to = statement.column_text (1); draft.cc = statement.column_text (2); draft.bcc = statement.column_text (3);
        draft.subject = statement.column_text (4); draft.body_text = statement.column_text (5); draft.in_reply_to = statement.column_text (6);
        draft.references = statement.column_text (7); draft.modified_at = statement.column_int64 (8);
        draft.body_html = statement.column_text (9); draft.body_format = statement.column_text (10);
        draft.security_protocol = (MessageSecurityProtocol) statement.column_int (11);
        draft.sign_message = statement.column_int (12) != 0; draft.encrypt_message = statement.column_int (13) != 0;
        draft.security_identity = statement.column_text (14);
        draft.revision = statement.column_int64 (15); draft.remote_mailbox = statement.column_text (16);
        draft.remote_uid = statement.column_text (17); draft.remote_revision = statement.column_int64 (18);
        draft.remote_internet_message_id = statement.column_text (19);
        draft.remote_content_fingerprint = statement.column_text (20);
        draft.remote_owned = statement.column_int (21) != 0;
        if (database.prepare_v2 ("SELECT id,path,name,size,content_type,content_id,remote_part_index FROM draft_attachments WHERE draft_id=? ORDER BY rowid", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare draft attachment loading");
        statement.bind_text (1, id);
        while ((result = statement.step ()) == Sqlite.ROW)
            draft.attachments.add (new Attachment (statement.column_text (0), statement.column_text (1), statement.column_text (2), statement.column_int64 (3), statement.column_text (4), statement.column_text (5), statement.column_int (6)));
        if (result != Sqlite.DONE) throw new MailError.STORAGE ("Could not load draft attachments");
        draft.mark_saved (); return draft;
    }

    public Gee.ArrayList<Draft> list_saved_drafts () throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT d.id FROM drafts d WHERE NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) ORDER BY d.modified_at DESC";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare saved draft loading");
        var ids = new Gee.ArrayList<string> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load saved drafts");
        var result = new Gee.ArrayList<Draft> ();
        foreach (var id in ids) { var draft = load_draft (id); if (draft != null) result.add (draft); }
        return result;
    }

    public int saved_draft_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM drafts d WHERE NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id)", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count saved drafts");
        return statement.column_int (0);
    }

    public Gee.ArrayList<Draft> list_pending_draft_uploads (string account_id) throws MailError {
        recover_expired_draft_sync_claims ();
        Sqlite.Statement statement;
        const string sql = "SELECT d.id FROM drafts d WHERE d.account_id=? AND d.revision>d.remote_revision " +
            "AND d.remote_sync_owner='' AND NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) ORDER BY d.modified_at";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare remote draft synchronization");
        statement.bind_text (1, account_id);
        var ids = new Gee.ArrayList<string> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load drafts awaiting synchronization");
        var drafts = new Gee.ArrayList<Draft> ();
        foreach (var id in ids) {
            var draft = load_draft (id);
            if (draft != null) drafts.add (draft);
        }
        return drafts;
    }

    public bool has_pending_remote_draft_work (string account_id) throws MailError {
        recover_expired_draft_sync_claims ();
        Sqlite.Statement statement;
        const string sql = "SELECT EXISTS(" +
            "SELECT 1 FROM drafts d WHERE d.account_id=? AND d.revision>d.remote_revision " +
            "AND d.remote_sync_owner='' AND NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) " +
            "UNION ALL SELECT 1 FROM pending_remote_draft_deletions p WHERE p.account_id=? " +
            "AND p.completed_at=0 AND p.mailbox_name<>'' AND p.remote_uid<>'' LIMIT 1)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare background Drafts work inspection");
        statement.bind_text (1, account_id); statement.bind_text (2, account_id);
        if (statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not inspect background Drafts work");
        return statement.column_int (0) != 0;
    }

    public bool import_remote_draft (RemoteDraftSnapshot snapshot, Draft imported) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            // A discarded draft can still be visible to one overlapping IMAP
            // refresh until its provider-side copy is deleted. Its durable
            // deletion journal is a tombstone: never recreate the editable
            // draft from that stale snapshot.
            string snapshot_message_id = snapshot.internet_message_id;
            if (snapshot_message_id.strip () == "" && snapshot.managed_by_mailficient)
                snapshot_message_id = Draft.remote_message_id_for (
                    snapshot.draft.id, snapshot.draft.revision);
            if (pending_remote_draft_identity (snapshot.draft.account_id,
                    snapshot_message_id, snapshot.content_fingerprint,
                    snapshot.mailbox_name, snapshot.remote_uid)) {
                queue_remote_draft_deletion (snapshot.draft.account_id,
                    snapshot.mailbox_name, snapshot.remote_uid,
                    snapshot_message_id, false, false,
                    snapshot.internet_message_id.strip () == "" ?
                        snapshot.content_fingerprint : "");
                execute ("COMMIT");
                notify_remote_draft_work (snapshot.draft.account_id);
                return false;
            }
            Sqlite.Statement statement;
            const string lookup = "SELECT revision,remote_revision,remote_mailbox,remote_uid," +
                "remote_internet_message_id,remote_content_fingerprint,remote_owned," +
                "EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) FROM drafts d WHERE id=?";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare provider draft import");
            statement.bind_text (1, imported.id);
            int row = statement.step ();
            bool exists = row == Sqlite.ROW;
            int64 local_revision = exists ? statement.column_int64 (0) : 0;
            int64 synced_revision = exists ? statement.column_int64 (1) : 0;
            string old_mailbox = exists ? statement.column_text (2) : "";
            string old_uid = exists ? statement.column_text (3) : "";
            string old_message_id = exists ? statement.column_text (4) : "";
            string old_fingerprint = exists ? statement.column_text (5) : "";
            bool old_owned = exists && statement.column_int (6) != 0;
            bool in_outbox = exists && statement.column_int (7) != 0;
            if (!exists && row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect the provider draft");

            // Local unsynchronized edits and Outbox ownership always win over
            // a provider snapshot. The pending upload will reconcile them.
            if (in_outbox || (exists && local_revision > synced_revision)) {
                execute ("COMMIT");
                return false;
            }

            int64 advertised_revision = int64.max (1, snapshot.draft.revision);
            if (exists && snapshot.managed_by_mailficient && advertised_revision < synced_revision) {
                execute ("COMMIT");
                return false;
            }
            bool external_same_revision_edit = false;
            if (exists && snapshot.managed_by_mailficient && advertised_revision == synced_revision) {
                bool exact_duplicate = old_fingerprint != "" &&
                    old_fingerprint == snapshot.content_fingerprint;
                if (exact_duplicate &&
                    (old_mailbox != snapshot.mailbox_name || old_uid != snapshot.remote_uid)) {
                    // A concurrent append produced the same deterministic
                    // revision twice. Keep the already adopted location.
                    queue_remote_draft_deletion (snapshot.draft.account_id,
                        snapshot.mailbox_name, snapshot.remote_uid,
                        snapshot.internet_message_id);
                }
                if (exact_duplicate) {
                    execute ("COMMIT");
                    return false;
                }
                // A provider client can preserve our custom headers while
                // changing the actual draft. Import it, then upload the next
                // revision so all clients converge on a fresh identity.
                external_same_revision_edit = true;
            }
            // UID and Message-ID are identities, not content versions. Several
            // IMAP providers allow another client to replace a draft body while
            // retaining both, so only the fingerprint proves it is unchanged.
            if (!external_same_revision_edit && exists &&
                old_fingerprint != "" && old_fingerprint == snapshot.content_fingerprint &&
                old_mailbox == snapshot.mailbox_name && old_uid == snapshot.remote_uid &&
                old_message_id == snapshot.internet_message_id) {
                execute ("COMMIT");
                return false;
            }

            int64 imported_revision = external_same_revision_edit ? local_revision + 1 :
                snapshot.managed_by_mailficient ? advertised_revision :
                (exists ? int64.max (local_revision + 1, advertised_revision) : advertised_revision);
            int64 mapped_remote_revision = external_same_revision_edit ? advertised_revision : imported_revision;
            imported.revision = imported_revision;
            imported.modified_at = snapshot.draft.modified_at;
            save_draft_rows (imported);
            if (old_owned && old_uid != "" &&
                (old_mailbox != snapshot.mailbox_name || old_uid != snapshot.remote_uid))
                queue_remote_draft_deletion (snapshot.draft.account_id, old_mailbox, old_uid,
                    old_message_id == "" ? Draft.remote_message_id_for (imported.id, synced_revision) :
                    old_message_id);
            const string update = "UPDATE drafts SET remote_mailbox=?,remote_uid=?,remote_revision=?," +
                "remote_internet_message_id=?,remote_content_fingerprint=?,remote_owned=?," +
                "remote_sync_owner='',remote_sync_until=0 WHERE id=?";
            if (database.prepare_v2 (update, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare provider draft mapping");
            statement.bind_text (1, snapshot.mailbox_name); statement.bind_text (2, snapshot.remote_uid);
            statement.bind_int64 (3, mapped_remote_revision); statement.bind_text (4, snapshot.internet_message_id);
            statement.bind_text (5, snapshot.content_fingerprint);
            statement.bind_int (6, snapshot.managed_by_mailficient ? 1 : 0); statement.bind_text (7, imported.id);
            if (statement.step () != Sqlite.DONE || database.changes () != 1)
                throw new MailError.STORAGE ("Could not preserve the provider draft mapping");
            execute ("COMMIT"); imported.remote_mailbox = snapshot.mailbox_name;
            imported.remote_uid = snapshot.remote_uid; imported.remote_revision = mapped_remote_revision;
            imported.remote_internet_message_id = snapshot.internet_message_id;
            imported.remote_content_fingerprint = snapshot.content_fingerprint;
            imported.remote_owned = snapshot.managed_by_mailficient; imported.mark_saved ();
            return true;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    // Reconcile provider-side deletion only for Drafts mailboxes whose full UID
    // inventory completed. Unsynchronized local edits survive and become a new
    // upload; an unchanged local mirror follows a deletion made on another
    // device. Returned drafts let the caller clean private attachment copies.
    public Gee.ArrayList<Draft> reconcile_remote_draft_deletions (
        MailSyncResult snapshot) throws MailError {
        var removed = new Gee.ArrayList<Draft> ();
        if (!snapshot.folder_inventory_complete) return removed;
        foreach (var mailbox in snapshot.mailboxes) {
            if (mailbox.role != MailboxRole.DRAFTS) continue;
            var inventory = snapshot.remote_uids_for (mailbox.id);
            if (inventory == null) continue;
            execute ("BEGIN IMMEDIATE");
            try {
                // Acquire the writer lock before selecting candidates. A
                // foreground autosave cannot turn an observed clean mirror into
                // a local edit between this read and the delete below.
                Sqlite.Statement statement;
                const string sql = "SELECT d.id,d.remote_uid,d.revision,d.remote_revision " +
                    "FROM drafts d WHERE d.account_id=? AND d.remote_mailbox=? AND d.remote_uid<>'' " +
                    "AND NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id)";
                if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare provider draft deletion reconciliation");
                statement.bind_text (1, snapshot.account_id);
                statement.bind_text (2, mailbox.remote_name);
                var missing = new Gee.ArrayList<string> ();
                var preserve = new Gee.ArrayList<string> ();
                int row;
                while ((row = statement.step ()) == Sqlite.ROW) {
                    if (inventory.contains (statement.column_text (1))) continue;
                    if (statement.column_int64 (2) > statement.column_int64 (3))
                        preserve.add (statement.column_text (0));
                    else
                        missing.add (statement.column_text (0));
                }
                if (row != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not inspect provider draft deletions");
                foreach (var id in preserve) {
                    if (database.prepare_v2 ("UPDATE drafts SET remote_mailbox='',remote_uid='',remote_revision=0," +
                                             "remote_internet_message_id='',remote_content_fingerprint='',remote_owned=1 " +
                                             "WHERE id=?", -1, out statement) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not preserve an edited provider draft");
                    statement.bind_text (1, id);
                    if (statement.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not preserve an edited provider draft");
                }
                foreach (var id in missing) {
                    var draft = load_draft (id);
                    if (draft != null) removed.add (draft);
                    // The provider has authoritatively removed this clean
                    // mirror. Any older append-attempt journal for it can no
                    // longer be upgraded by a later user discard.
                    delete_bound ("DELETE FROM remote_draft_upload_attempts WHERE draft_id=?", id);
                    delete_bound ("DELETE FROM drafts WHERE id=?", id);
                }
                execute ("COMMIT");
            } catch (MailError error) {
                try { execute ("ROLLBACK"); } catch (MailError ignored) { }
                throw error;
            }
        }
        return removed;
    }

    public bool claim_draft_upload (string draft_id, string owner, int64 lease_until) throws MailError {
        recover_expired_draft_sync_claims ();
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            const string sql = "UPDATE drafts SET remote_sync_owner=?,remote_sync_until=? WHERE id=? " +
                "AND revision>remote_revision AND remote_sync_owner='' " +
                "AND NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=drafts.id)";
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the remote draft claim");
            statement.bind_text (1, owner); statement.bind_int64 (2, lease_until);
            statement.bind_text (3, draft_id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not claim the remote draft update");
            bool claimed = database.changes () == 1;
            if (claimed) {
                const string attempt_sql = "INSERT OR IGNORE INTO remote_draft_upload_attempts(" +
                    "draft_id,account_id,revision,expected_message_id,created_at) " +
                    "SELECT id,account_id,revision,'',strftime('%s','now') FROM drafts WHERE id=?";
                if (database.prepare_v2 (attempt_sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the remote draft upload journal");
                statement.bind_text (1, draft_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not preserve the remote draft upload journal");
                if (database.prepare_v2 ("UPDATE remote_draft_upload_attempts SET " +
                        "expected_message_id='mailficient-draft-' || draft_id || '-' || revision || " +
                        "'@mailficient.local' WHERE draft_id=? AND expected_message_id=''",
                        -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the remote draft identity journal");
                statement.bind_text (1, draft_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not preserve the remote draft identity journal");
            }
            execute ("COMMIT");
            return claimed;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void release_draft_upload (string draft_id, string owner) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE drafts SET remote_sync_owner='',remote_sync_until=0 WHERE id=? AND remote_sync_owner=?", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the remote draft claim release");
        statement.bind_text (1, draft_id); statement.bind_text (2, owner);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not release the remote draft claim");
    }

    private void recover_expired_draft_sync_claims () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE drafts SET remote_sync_owner='',remote_sync_until=0 WHERE remote_sync_owner<>'' AND remote_sync_until<=strftime('%s','now')", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare expired remote draft recovery");
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not recover expired remote draft work");
    }

    public void record_remote_draft_uploaded (string draft_id, string account_id,
                                              int64 uploaded_revision,
                                              RemoteDraftLocation location,
                                              string claim_owner,
                                              string content_fingerprint) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            const string lookup = "SELECT account_id,remote_mailbox,remote_uid,remote_internet_message_id,remote_revision,revision,remote_sync_owner," +
                "EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) FROM drafts d WHERE id=?";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare remote draft reconciliation");
            statement.bind_text (1, draft_id);
            int row = statement.step ();
            string previous_mailbox = "";
            string previous_uid = "";
            string previous_message_id = "";
            int64 previous_revision = 0;
            int64 current_revision = 0;
            bool current_draft = false;
            bool owns_claim = false;
            if (row == Sqlite.ROW) {
                current_draft = statement.column_text (0) == account_id && statement.column_int (7) == 0;
                owns_claim = current_draft && statement.column_text (6) == claim_owner;
                previous_mailbox = statement.column_text (1);
                previous_uid = statement.column_text (2);
                previous_message_id = statement.column_text (3);
                previous_revision = statement.column_int64 (4);
                current_revision = statement.column_int64 (5);
            } else if (row != Sqlite.DONE) {
                throw new MailError.STORAGE ("Could not reconcile the remote draft");
            }

            // A stale worker may finish just after another process reclaimed
            // the lease.  If the local revision is still unchanged and no copy
            // of it was recorded yet, atomically adopt this completion and
            // invalidate the competing claim.  Otherwise its exact location is
            // redundant and must be cleaned up, never left as an orphan.
            bool canonical_same_revision = current_draft &&
                previous_revision == uploaded_revision &&
                remote_location_precedes (location.mailbox_name, location.remote_uid,
                    previous_mailbox, previous_uid);
            bool adopt_upload = current_draft && (owns_claim || canonical_same_revision ||
                (current_revision == uploaded_revision && previous_revision < uploaded_revision));
            bool retain_upload_attempt = false;
            if (!adopt_upload) {
                bool already_adopted = current_draft && previous_revision == uploaded_revision &&
                    previous_mailbox == location.mailbox_name && previous_uid == location.remote_uid;
                if (!already_adopted) {
                    queue_remote_draft_deletion (account_id, location.mailbox_name, location.remote_uid,
                        Draft.remote_message_id_for (draft_id, uploaded_revision));
                    // The live draft can still be explicitly discarded before
                    // that redundant-copy deletion completes. Keep its attempt
                    // identity so discard can upgrade the generic cleanup into
                    // a durable user-cancel tombstone.
                    retain_upload_attempt = current_draft;
                }
            } else {
                if (previous_uid != "" && previous_revision > 0 &&
                    (previous_mailbox != location.mailbox_name || previous_uid != location.remote_uid))
                    queue_remote_draft_deletion (account_id, previous_mailbox, previous_uid,
                        previous_message_id == "" ? Draft.remote_message_id_for (draft_id, previous_revision) :
                        previous_message_id);
                if (database.prepare_v2 ("UPDATE drafts SET remote_mailbox=?,remote_uid=?,remote_revision=?,remote_internet_message_id=?,remote_content_fingerprint=?,remote_owned=1,remote_sync_owner='',remote_sync_until=0 " +
                                         "WHERE id=? AND account_id=?", -1,
                                         out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare remote draft storage");
                statement.bind_text (1, location.mailbox_name); statement.bind_text (2, location.remote_uid);
                statement.bind_int64 (3, uploaded_revision);
                statement.bind_text (4, Draft.remote_message_id_for (draft_id, uploaded_revision));
                statement.bind_text (5, content_fingerprint);
                statement.bind_text (6, draft_id); statement.bind_text (7, account_id);
                if (statement.step () != Sqlite.DONE || database.changes () != 1)
                    throw new MailError.STORAGE ("Could not preserve the remote draft location");
            }
            if (!retain_upload_attempt) {
                if (database.prepare_v2 ("DELETE FROM remote_draft_upload_attempts " +
                        "WHERE draft_id=? AND revision=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare completed draft upload cleanup");
                statement.bind_text (1, draft_id); statement.bind_int64 (2, uploaded_revision);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not complete the draft upload journal");
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private static bool remote_location_precedes (string candidate_mailbox, string candidate_uid,
                                                   string current_mailbox, string current_uid) {
        int mailbox_order = strcmp (candidate_mailbox, current_mailbox);
        if (mailbox_order != 0) return mailbox_order < 0;
        uint64 candidate_number = 0; uint64 current_number = 0;
        bool candidate_numeric = uint64.try_parse (candidate_uid, out candidate_number);
        bool current_numeric = uint64.try_parse (current_uid, out current_number);
        if (candidate_numeric && current_numeric) return candidate_number < current_number;
        return strcmp (candidate_uid, current_uid) < 0;
    }

    public Gee.ArrayList<PendingDraftDeletion> list_pending_remote_draft_deletions (
        string account_id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT id,mailbox_name,remote_uid,expected_message_id," +
            "expected_fingerprint " +
            "FROM pending_remote_draft_deletions WHERE account_id=? AND completed_at=0 " +
            "AND mailbox_name<>'' AND remote_uid<>'' ORDER BY id";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare remote draft cleanup");
        statement.bind_text (1, account_id);
        var result = new Gee.ArrayList<PendingDraftDeletion> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new PendingDraftDeletion (statement.column_int64 (0), account_id,
                statement.column_text (1), statement.column_text (2),
                statement.column_text (3), statement.column_text (4)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load remote draft cleanup");
        return result;
    }

    public void complete_remote_draft_deletion (int64 id) throws MailError {
        // Redundant-copy cleanup needs no lasting identity tombstone. Explicit
        // discard does: retain that row after network completion so a sync
        // snapshot fetched just before deletion cannot resurrect the draft.
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            // A redundant upload attempt remains associated with its live
            // draft even after the exact server copy was deleted. A provider
            // snapshot fetched just before that deletion can arrive later; if
            // the user cancels in between, queue_saved_remote_draft_deletion()
            // must still be able to upgrade that identity into a permanent
            // tombstone. Successful adoption, send, discard, or account
            // removal eventually consumes the small per-draft journal.
            delete_bound_int64 ("DELETE FROM pending_remote_draft_deletions " +
                "WHERE id=? AND suppress_reimport=0", id);
            if (database.prepare_v2 ("UPDATE pending_remote_draft_deletions " +
                    "SET completed_at=strftime('%s','now') WHERE id=? AND completed_at=0",
                    -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare completed draft cleanup");
            statement.bind_int64 (1, id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve completed draft cleanup");
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public int pending_remote_draft_deletion_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM pending_remote_draft_deletions " +
                                 "WHERE completed_at=0 AND mailbox_name<>'' AND remote_uid<>''", -1,
                                 out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count remote draft cleanup");
        return statement.column_int (0);
    }

    public void queue_for_sending (Draft draft, int64 not_before = 0,
                                   bool allow_uncertain_resend = false) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            ensure_draft_mutable (draft.id, allow_uncertain_resend);
            save_draft_rows (draft);
            Sqlite.Statement ownership;
            if (database.prepare_v2 ("UPDATE drafts SET remote_owned=1 WHERE id=? AND remote_uid<>''", -1,
                                     out ownership) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare remote draft ownership");
            ownership.bind_text (1, draft.id);
            if (ownership.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve remote draft ownership");
            // Once a draft becomes an Outbox item its provider-side Drafts copy
            // must disappear.  Queue the cleanup in the same transaction so a
            // crash cannot strand the old copy indefinitely.
            queue_saved_remote_draft_deletion (draft.id, false);
            Sqlite.Statement statement;
            if (database.prepare_v2 ("INSERT INTO outbox(id,draft_id,attempts,next_attempt_at,last_error,delivery_state,lease_owner,lease_until) VALUES(?,?,0,?,'',0,'',0) " +
                                     "ON CONFLICT(draft_id) DO UPDATE SET attempts=0,next_attempt_at=excluded.next_attempt_at,last_error='',delivery_state=0,lease_owner='',lease_until=0," +
                                     "undo_until=0,undo_previous_state=-1,undo_previous_attempts=0,undo_previous_next_attempt_at=0,undo_previous_last_error=''",
                                     -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the outbox item");
            statement.bind_text (1, draft.id); statement.bind_text (2, draft.id); statement.bind_int64 (3, int64.max (0, not_before));
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not queue the message for sending");
            execute ("COMMIT"); draft.mark_saved ();
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void queue_for_undo_send (Draft draft, int64 undo_until,
                                     bool allow_uncertain_resend = false) throws MailError {
        int64 now = new DateTime.now_utc ().to_unix ();
        if (undo_until <= now)
            throw new MailError.INVALID_MESSAGE ("The Undo Send deadline must be in the future");
        execute ("BEGIN IMMEDIATE");
        try {
            ensure_draft_mutable (draft.id, allow_uncertain_resend);
            int previous_state = -1; int previous_attempts = 0;
            int64 previous_next_attempt_at = 0; string previous_last_error = "";
            Sqlite.Statement statement;
            if (database.prepare_v2 ("SELECT delivery_state,attempts,next_attempt_at,last_error FROM outbox WHERE draft_id=?", -1,
                                     out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the previous Outbox state");
            statement.bind_text (1, draft.id);
            int row = statement.step ();
            if (row == Sqlite.ROW) {
                previous_state = statement.column_int (0);
                previous_attempts = statement.column_int (1);
                previous_next_attempt_at = statement.column_int64 (2);
                previous_last_error = statement.column_text (3);
            } else if (row != Sqlite.DONE) {
                throw new MailError.STORAGE ("Could not inspect the previous Outbox state");
            }

            save_draft_rows (draft);
            if (database.prepare_v2 ("UPDATE drafts SET remote_owned=1 WHERE id=? AND remote_uid<>''", -1,
                                     out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare remote draft ownership");
            statement.bind_text (1, draft.id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve remote draft ownership");

            // Provider Draft cleanup is intentionally delayed until the SMTP
            // preparation lease is acquired. Undo therefore leaves an existing
            // provider draft untouched even if a background Drafts pass runs.
            const string sql = "INSERT INTO outbox(id,draft_id,attempts,next_attempt_at,last_error,delivery_state,lease_owner,lease_until," +
                "undo_until,undo_previous_state,undo_previous_attempts,undo_previous_next_attempt_at,undo_previous_last_error) " +
                "VALUES(?,?,0,?,'',0,'',0,?,?,?,?,?) ON CONFLICT(draft_id) DO UPDATE SET " +
                "attempts=0,next_attempt_at=excluded.next_attempt_at,last_error='',delivery_state=0,lease_owner='',lease_until=0," +
                "undo_until=excluded.undo_until,undo_previous_state=excluded.undo_previous_state," +
                "undo_previous_attempts=excluded.undo_previous_attempts," +
                "undo_previous_next_attempt_at=excluded.undo_previous_next_attempt_at," +
                "undo_previous_last_error=excluded.undo_previous_last_error";
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare Undo Send storage");
            statement.bind_text (1, draft.id); statement.bind_text (2, draft.id);
            statement.bind_int64 (3, undo_until); statement.bind_int64 (4, undo_until);
            statement.bind_int (5, previous_state); statement.bind_int (6, previous_attempts);
            statement.bind_int64 (7, previous_next_attempt_at);
            statement.bind_text (8, previous_last_error);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve the Undo Send item");
            execute ("COMMIT"); draft.mark_saved ();
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public bool cancel_undo_send (string draft_id) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            const string lookup = "SELECT undo_previous_state,undo_previous_attempts," +
                "undo_previous_next_attempt_at,undo_previous_last_error FROM outbox " +
                "WHERE draft_id=? AND delivery_state=? AND undo_until>strftime('%s','now')";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare Undo Send cancellation");
            statement.bind_text (1, draft_id);
            statement.bind_int (2, (int) OutboxDeliveryState.QUEUED);
            int row = statement.step ();
            if (row == Sqlite.DONE) { execute ("COMMIT"); return false; }
            if (row != Sqlite.ROW)
                throw new MailError.STORAGE ("Could not inspect Undo Send cancellation");
            int previous_state = statement.column_int (0);
            if (previous_state < 0) {
                if (database.prepare_v2 ("DELETE FROM outbox WHERE draft_id=?", -1,
                                         out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare Undo Send removal");
                statement.bind_text (1, draft_id);
            } else {
                int previous_attempts = statement.column_int (1);
                int64 previous_next_attempt_at = statement.column_int64 (2);
                string previous_last_error = statement.column_text (3);
                const string restore = "UPDATE outbox SET delivery_state=?,attempts=?,next_attempt_at=?,last_error=?," +
                    "lease_owner='',lease_until=0,undo_until=0,undo_previous_state=-1," +
                    "undo_previous_attempts=0,undo_previous_next_attempt_at=0,undo_previous_last_error='' WHERE draft_id=?";
                if (database.prepare_v2 (restore, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the previous Outbox state restoration");
                statement.bind_int (1, previous_state); statement.bind_int (2, previous_attempts);
                statement.bind_int64 (3, previous_next_attempt_at);
                statement.bind_text (4, previous_last_error); statement.bind_text (5, draft_id);
            }
            if (statement.step () != Sqlite.DONE || database.changes () != 1)
                throw new MailError.STORAGE ("Could not cancel Undo Send");
            execute ("COMMIT"); return true;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void record_send_failure (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,next_attempt_at=strftime('%s','now')+MIN(3600,60*(1 << MIN(attempts,6))),last_error=?,delivery_state=0,lease_owner='',lease_until=0,undo_until=0,undo_previous_state=-1,undo_previous_attempts=0,undo_previous_next_attempt_at=0,undo_previous_last_error='' WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare send failure storage");
        statement.bind_text (1, detail); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the send failure");
    }

    public void record_send_uncertain (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,last_error=?,delivery_state=1,lease_owner='',lease_until=0,undo_until=0,undo_previous_state=-1,undo_previous_attempts=0,undo_previous_next_attempt_at=0,undo_previous_last_error='' WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare uncertain delivery storage");
        statement.bind_text (1, detail); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve uncertain delivery status");
    }

    public void record_send_rejection (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,next_attempt_at=0,last_error=?,delivery_state=?,lease_owner='',lease_until=0,undo_until=0,undo_previous_state=-1,undo_previous_attempts=0,undo_previous_next_attempt_at=0,undo_previous_last_error='' WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare SMTP rejection storage");
        statement.bind_text (1, detail);
        statement.bind_int (2, (int) OutboxDeliveryState.REJECTED);
        statement.bind_text (3, draft_id);
        if (statement.step () != Sqlite.DONE || database.changes () != 1)
            throw new MailError.STORAGE ("Could not preserve the SMTP rejection");
    }

    public void complete_send (string draft_id) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("DELETE FROM outbox WHERE draft_id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare outbox completion");
            statement.bind_text (1, draft_id); if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not complete the outbox item");
            if (database.prepare_v2 ("DELETE FROM drafts WHERE id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare sent draft cleanup");
            statement.bind_text (1, draft_id); if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not clean up the sent draft");
            execute ("COMMIT");
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
    }

    public bool claim_queued_send (string draft_id, string lease_owner, int64 lease_until,
                                   bool due_only = true) throws MailError {
        recover_expired_outbox_claims ();
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            string sql = "UPDATE outbox SET delivery_state=?,lease_owner=?,lease_until=?," +
                "undo_until=0,undo_previous_state=-1,undo_previous_attempts=0," +
                "undo_previous_next_attempt_at=0,undo_previous_last_error='' " +
                "WHERE draft_id=? AND delivery_state=? " +
                // The Undo Send deadline is an unconditional fence.  A manual
                // retry may ignore ordinary backoff, but never this boundary.
                "AND (undo_until=0 OR undo_until<=strftime('%s','now'))" +
                (due_only ? " AND next_attempt_at<=strftime('%s','now')" : "");
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the Outbox delivery claim");
            statement.bind_int (1, (int) OutboxDeliveryState.PREPARING);
            statement.bind_text (2, lease_owner); statement.bind_int64 (3, lease_until);
            statement.bind_text (4, draft_id);
            statement.bind_int (5, (int) OutboxDeliveryState.QUEUED);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not claim the Outbox message");
            bool claimed = database.changes () == 1;
            if (claimed)
                queue_saved_remote_draft_deletion (draft_id, false);
            execute ("COMMIT"); return claimed;
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void record_preparation_failure (string draft_id, string lease_owner,
                                            string detail) throws MailError {
        Sqlite.Statement statement;
        const string sql = "UPDATE outbox SET attempts=attempts+1," +
            "next_attempt_at=strftime('%s','now')+MIN(3600,60*(1 << MIN(attempts,6)))," +
            "last_error=?,delivery_state=?,lease_owner='',lease_until=0 " +
            "WHERE draft_id=? AND delivery_state=? AND lease_owner=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the Outbox claim release");
        statement.bind_text (1, detail); statement.bind_int (2, (int) OutboxDeliveryState.QUEUED);
        statement.bind_text (3, draft_id); statement.bind_int (4, (int) OutboxDeliveryState.PREPARING);
        statement.bind_text (5, lease_owner);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not release the Outbox delivery claim");
    }

    public void mark_send_started (string draft_id, string lease_owner = "") throws MailError {
        if (lease_owner == "") {
            set_outbox_delivery_state (draft_id, OutboxDeliveryState.SENDING);
            return;
        }
        Sqlite.Statement statement;
        const string sql = "UPDATE outbox SET delivery_state=?,lease_owner='',lease_until=0 " +
            "WHERE draft_id=? AND delivery_state=? AND lease_owner=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare SMTP delivery state");
        statement.bind_int (1, (int) OutboxDeliveryState.SENDING); statement.bind_text (2, draft_id);
        statement.bind_int (3, (int) OutboxDeliveryState.PREPARING); statement.bind_text (4, lease_owner);
        if (statement.step () != Sqlite.DONE || database.changes () != 1)
            throw new MailError.STORAGE ("The Outbox delivery claim expired before SMTP started");
    }

    public void mark_send_accepted (string draft_id) throws MailError {
        set_outbox_delivery_state (draft_id, OutboxDeliveryState.ACCEPTED);
    }

    private void set_outbox_delivery_state (string draft_id, OutboxDeliveryState state) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET delivery_state=?,lease_owner='',lease_until=0 WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox delivery state");
        statement.bind_int (1, (int) state); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE || database.changes () != 1)
            throw new MailError.STORAGE ("Could not preserve Outbox delivery state");
    }

    public void recover_expired_outbox_claims () throws MailError {
        Sqlite.Statement statement;
        const string sql = "UPDATE outbox SET delivery_state=?,lease_owner='',lease_until=0," +
            "next_attempt_at=MIN(next_attempt_at,strftime('%s','now')) " +
            "WHERE delivery_state=? AND lease_until<=strftime('%s','now')";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare expired Outbox recovery");
        statement.bind_int (1, (int) OutboxDeliveryState.QUEUED);
        statement.bind_int (2, (int) OutboxDeliveryState.PREPARING);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not recover expired Outbox work");
    }

    public void delete_draft (string id) throws MailError {
        string cleanup_account_id = "";
        execute ("BEGIN IMMEDIATE");
        try {
            ensure_draft_mutable (id, true, true);
            // Explicit user discard is an ownership decision even for a draft
            // originally created by another client. Passive import/reconcile
            // remains non-owning, but discard must not let the draft reappear
            // on the next provider sync.
            Sqlite.Statement ownership;
            if (database.prepare_v2 ("UPDATE drafts SET remote_owned=1 WHERE id=? AND remote_uid<>''", -1,
                                     out ownership) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare provider draft discard");
            ownership.bind_text (1, id);
            if (ownership.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve provider draft discard");
            cleanup_account_id = queue_saved_remote_draft_deletion (id, true);
            delete_bound ("DELETE FROM outbox WHERE draft_id=?", id);
            delete_bound ("DELETE FROM drafts WHERE id=?", id);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        notify_remote_draft_work (cleanup_account_id);
    }

    private void ensure_draft_mutable (string draft_id, bool allow_uncertain_resend,
                                       bool deleting = false) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT delivery_state,last_error,undo_until FROM outbox WHERE draft_id=?", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect the Outbox delivery state");
        statement.bind_text (1, draft_id);
        int row = statement.step ();
        if (row == Sqlite.DONE) return;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not inspect the Outbox delivery state");
        var state = (OutboxDeliveryState) statement.column_int (0);
        string detail = statement.column_text (1);
        if (state == OutboxDeliveryState.QUEUED &&
            statement.column_int64 (2) > new DateTime.now_utc ().to_unix ())
            throw new MailError.SEND_FAILED (
                "Use Undo Send before editing or deleting this queued message");
        if (state == OutboxDeliveryState.PREPARING)
            throw new MailError.SEND_FAILED ("This message is already being prepared by a background sender");
        if (state == OutboxDeliveryState.ACCEPTED)
            throw new MailError.SEND_FAILED ("This message was already accepted by the mail server");
        if (state == OutboxDeliveryState.SENDING) {
            // An empty detail means SMTP is active right now.  A non-empty
            // detail is the durable uncertain state shown with an explicit
            // resend confirmation in the composer.
            if (detail == "" || (!deleting && !allow_uncertain_resend))
                throw new MailError.DELIVERY_UNCERTAIN (
                    detail == "" ? "This message is currently being sent" :
                    "Confirm the uncertain delivery before sending another copy");
        }
    }

    private string queue_saved_remote_draft_deletion (string draft_id,
                                                      bool permanent_tombstone) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT account_id,remote_mailbox,remote_uid," +
                "remote_revision,remote_owned,remote_internet_message_id," +
                "remote_content_fingerprint " +
                "FROM drafts WHERE id=?", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare remote draft cleanup");
        statement.bind_text (1, draft_id);
        int row = statement.step ();
        if (row == Sqlite.DONE) return "";
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not inspect remote draft cleanup");
        string mailbox_name = statement.column_text (1);
        string remote_uid = statement.column_text (2);
        int64 remote_revision = statement.column_int64 (3);
        bool remote_owned = statement.column_int (4) != 0;
        string remote_message_id = statement.column_text (5);
        string remote_fingerprint = statement.column_text (6);
        string account_id = statement.column_text (0);
        bool queued = false;

        // An append attempt outlives its short worker lease. The provider may
        // have accepted the MIME before a timeout or crash, so transfer every
        // attempted revision into the cancellation tombstone journal before
        // the editable draft row disappears.
        if (database.prepare_v2 ("SELECT account_id,expected_message_id FROM " +
                "remote_draft_upload_attempts WHERE draft_id=? ORDER BY revision",
                -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare attempted draft cleanup");
        statement.bind_text (1, draft_id); int attempt_row;
        while ((attempt_row = statement.step ()) == Sqlite.ROW) {
            queue_remote_draft_tombstone (statement.column_text (0),
                statement.column_text (1), permanent_tombstone);
            queued = true;
        }
        if (attempt_row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect attempted draft cleanup");
        delete_bound ("DELETE FROM remote_draft_upload_attempts WHERE draft_id=?", draft_id);

        if (remote_owned && mailbox_name != "" && remote_uid != "" &&
            remote_revision > 0) {
            string expected_message_id = remote_message_id;
            string expected_fingerprint = "";
            if (expected_message_id == "") {
                // Retain the exact imported content token even when verified
                // Mailficient extension headers let us reconstruct the ID.
                // It permits immediate cleanup of a cached stripped-ID copy.
                expected_fingerprint = remote_fingerprint;
                if (Uuid.string_is_valid (draft_id))
                    expected_message_id = Draft.remote_message_id_for (
                        draft_id, remote_revision);
            }
            queue_remote_draft_deletion (account_id, mailbox_name, remote_uid,
                expected_message_id, true, permanent_tombstone,
                expected_fingerprint);
            if (expected_message_id != "" || expected_fingerprint != "")
                queued = true;
        }
        return queued ? account_id : "";
    }

    private void notify_remote_draft_work (string account_id) {
        if (account_id == "") return;
        try {
            // Demo/temporary identities have no provider and must never
            // trigger a desktop background-access prompt.
            if (find_account (account_id) != null)
                remote_draft_work_queued (account_id);
        } catch (MailError error) {
            warning ("Could not inspect background Drafts activation: %s", error.message);
        }
    }

    private void queue_remote_draft_deletion (string account_id, string mailbox_name,
                                              string remote_uid, string expected_message_id,
                                              bool suppress_reimport = false,
                                              bool permanent_tombstone = false,
                                              string expected_fingerprint = "") throws MailError {
        purge_expired_transient_draft_tombstones ();
        string canonical_id = canonical_message_id (expected_message_id);
        string fingerprint = expected_fingerprint.strip ();
        if (mailbox_name == "" || remote_uid == "" ||
            (canonical_id == "" && fingerprint == "")) return;
        Sqlite.Statement statement;
        bool effective_suppression = suppress_reimport;
        bool effective_permanence = permanent_tombstone;
        var provisional_ids = new Gee.ArrayList<int64?> ();
        string existing_sql = "SELECT id,mailbox_name,remote_uid," +
            "expected_message_id,suppress_reimport,permanent_tombstone," +
            "completed_at,created_at,expected_fingerprint FROM " +
            "pending_remote_draft_deletions WHERE account_id=? AND ";
        if (canonical_id != "")
            existing_sql += "expected_message_id IN (?,?)";
        else
            existing_sql += "mailbox_name=? AND remote_uid=? " +
                "AND expected_message_id='' AND expected_fingerprint=?";
        if (database.prepare_v2 (existing_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect existing draft cleanup");
        statement.bind_text (1, account_id);
        if (canonical_id != "") {
            statement.bind_text (2, canonical_id);
            statement.bind_text (3, "<%s>".printf (canonical_id));
        } else {
            statement.bind_text (2, mailbox_name);
            statement.bind_text (3, remote_uid);
            statement.bind_text (4, fingerprint);
        }
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string existing_id = canonical_message_id (statement.column_text (3));
            bool same_identity = canonical_id != "" ? existing_id == canonical_id :
                existing_id == "" && statement.column_text (8) == fingerprint;
            if (!same_identity)
                continue;
            if (fingerprint == "" && statement.column_text (8) != "" &&
                statement.column_text (1) == mailbox_name &&
                statement.column_text (2) == remote_uid)
                fingerprint = statement.column_text (8);
            int64 completed_at = statement.column_int64 (6);
            int64 retention_time = completed_at == 0 ?
                statement.column_int64 (7) : completed_at;
            bool exact_pending = completed_at == 0 &&
                statement.column_text (1) != "" && statement.column_text (2) != "";
            bool active_suppression = statement.column_int (4) != 0 &&
                (statement.column_int (5) != 0 || exact_pending ||
                 retention_time > new DateTime.now_utc ().to_unix () -
                    TRANSIENT_DRAFT_TOMBSTONE_SECONDS);
            if (active_suppression) effective_suppression = true;
            if (statement.column_int (5) != 0) effective_permanence = true;
            if (statement.column_text (1) == "" && statement.column_text (2) == "")
                provisional_ids.add (statement.column_int64 (0));
        }
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect existing draft cleanup");
        // Replace a claim-time location-less tombstone now that either the
        // upload worker or a provider snapshot supplied the exact UID.
        foreach (var provisional_id in provisional_ids)
            delete_bound_int64 ("DELETE FROM pending_remote_draft_deletions WHERE id=?",
                provisional_id);
        const string sql = "INSERT OR IGNORE INTO pending_remote_draft_deletions(" +
            "account_id,mailbox_name,remote_uid,expected_message_id," +
            "expected_fingerprint,created_at," +
            "suppress_reimport,permanent_tombstone) " +
            "VALUES(?,?,?,?,?,strftime('%s','now'),?,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare remote draft cleanup");
        statement.bind_text (1, account_id); statement.bind_text (2, mailbox_name);
        statement.bind_text (3, remote_uid); statement.bind_text (4, canonical_id);
        statement.bind_text (5, fingerprint);
        statement.bind_int (6, effective_suppression ? 1 : 0);
        statement.bind_int (7, effective_permanence ? 1 : 0);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not preserve remote draft cleanup");
        if (database.prepare_v2 ("UPDATE pending_remote_draft_deletions " +
                "SET completed_at=0,created_at=strftime('%s','now')," +
                "expected_fingerprint=?," +
                "suppress_reimport=CASE WHEN suppress_reimport=1 OR ?=1 THEN 1 ELSE 0 END," +
                "permanent_tombstone=CASE WHEN permanent_tombstone=1 OR ?=1 " +
                "THEN 1 ELSE 0 END " +
                "WHERE account_id=? " +
                "AND mailbox_name=? AND remote_uid=? AND expected_message_id=? " +
                "AND (?<>'' OR expected_fingerprint=?)",
                -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare renewed draft cleanup");
        statement.bind_text (1, fingerprint);
        statement.bind_int (2, effective_suppression ? 1 : 0);
        statement.bind_int (3, effective_permanence ? 1 : 0);
        statement.bind_text (4, account_id); statement.bind_text (5, mailbox_name);
        statement.bind_text (6, remote_uid); statement.bind_text (7, canonical_id);
        statement.bind_text (8, canonical_id); statement.bind_text (9, fingerprint);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not renew remote draft cleanup");
        purge_cached_remote_draft_copy (account_id, mailbox_name, remote_uid,
            canonical_id, effective_suppression, fingerprint);
    }

    private void queue_remote_draft_tombstone (string account_id,
                                               string expected_message_id,
                                               bool permanent_tombstone) throws MailError {
        purge_expired_transient_draft_tombstones ();
        string canonical_id = canonical_message_id (expected_message_id);
        if (account_id == "" || canonical_id == "") return;
        Sqlite.Statement statement;
        const string sql = "INSERT OR IGNORE INTO pending_remote_draft_deletions(" +
            "account_id,mailbox_name,remote_uid,expected_message_id,created_at," +
            "suppress_reimport,permanent_tombstone) " +
            "VALUES(?,'','',?,strftime('%s','now'),1,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare in-flight draft discard");
        statement.bind_text (1, account_id); statement.bind_text (2, canonical_id);
        statement.bind_int (3, permanent_tombstone ? 1 : 0);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not preserve in-flight draft discard");
        if (database.prepare_v2 ("UPDATE pending_remote_draft_deletions " +
                "SET completed_at=0,created_at=strftime('%s','now')," +
                "suppress_reimport=1,permanent_tombstone=" +
                "CASE WHEN permanent_tombstone=1 OR ?=1 THEN 1 ELSE 0 END " +
                "WHERE account_id=? AND mailbox_name='' " +
                "AND remote_uid='' AND expected_message_id=?", -1,
                out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare in-flight draft tombstone");
        statement.bind_int (1, permanent_tombstone ? 1 : 0);
        statement.bind_text (2, account_id); statement.bind_text (3, canonical_id);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not preserve in-flight draft tombstone");
    }

    private void purge_expired_transient_draft_tombstones () throws MailError {
        execute ("DELETE FROM pending_remote_draft_deletions " +
            "WHERE suppress_reimport=1 AND permanent_tombstone=0 AND " +
            "((completed_at>0 AND completed_at<=strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string () + ") OR " +
            "(completed_at=0 AND mailbox_name='' AND remote_uid='' " +
            "AND created_at<=strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string () + "))");
    }

    private bool pending_remote_draft_identity (string account_id,
                                                string internet_message_id,
                                                string content_fingerprint,
                                                string mailbox_name,
                                                string remote_uid) throws MailError {
        string candidate_id = canonical_message_id (internet_message_id);
        string candidate_fingerprint = content_fingerprint.strip ();
        if (candidate_id == "" && candidate_fingerprint == "") return false;
        Sqlite.Statement statement;
        string sql = "SELECT expected_message_id,expected_fingerprint," +
            "mailbox_name,remote_uid FROM pending_remote_draft_deletions " +
            "WHERE account_id=? AND ";
        if (candidate_id != "")
            sql += "expected_message_id IN (?,?) AND ";
        else
            sql += "expected_message_id='' AND expected_fingerprint=? " +
                "AND mailbox_name=? AND remote_uid=? AND ";
        sql += "suppress_reimport=1 AND " +
            "(permanent_tombstone=1 OR " +
            "(completed_at=0 AND mailbox_name<>'' AND remote_uid<>'') OR " +
            "(CASE WHEN completed_at=0 THEN created_at ELSE completed_at END)>" +
            "strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string () + ")";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect discarded provider drafts");
        statement.bind_text (1, account_id);
        if (candidate_id != "") {
            statement.bind_text (2, candidate_id);
            statement.bind_text (3, "<%s>".printf (candidate_id));
        } else {
            statement.bind_text (2, candidate_fingerprint);
            statement.bind_text (3, mailbox_name);
            statement.bind_text (4, remote_uid);
        }
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string expected_id = canonical_message_id (statement.column_text (0));
            if (candidate_id != "" && candidate_id == expected_id)
                return true;
            if (candidate_id == "" && expected_id == "" &&
                candidate_fingerprint != "" &&
                candidate_fingerprint == statement.column_text (1) &&
                mailbox_name == statement.column_text (2) &&
                remote_uid == statement.column_text (3))
                return true;
        }
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect discarded provider drafts");
        return false;
    }

    private void purge_cached_remote_draft_copy (string account_id,
                                                 string mailbox_name,
                                                 string remote_uid,
                                                 string internet_message_id,
                                                 bool suppress_reimport,
                                                 string expected_fingerprint) throws MailError {
        string expected_id = canonical_message_id (internet_message_id);
        string fingerprint = expected_fingerprint.strip ();
        var ids = new Gee.HashSet<string> ();
        Sqlite.Statement statement; int row;

        // Message-ID is indexed. Query only Drafts/Archive copies so a Sent or
        // Inbox message that legitimately preserves the ID is never hidden.
        if (suppress_reimport && expected_id != "") {
            const string identity_sql = "SELECT m.id FROM cached_messages m " +
                "JOIN cached_mailboxes b ON b.id=m.mailbox_id " +
                "WHERE m.account_id=? AND b.role IN (?,?) " +
                "AND m.internet_message_id IN (?,?)";
            if (database.prepare_v2 (identity_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare discarded draft identity cleanup");
            statement.bind_text (1, account_id);
            statement.bind_int (2, (int) MailboxRole.DRAFTS);
            statement.bind_int (3, (int) MailboxRole.ARCHIVE);
            statement.bind_text (4, expected_id);
            statement.bind_text (5, "<%s>".printf (expected_id));
            while ((row = statement.step ()) == Sqlite.ROW)
                ids.add (statement.column_text (0));
            if (row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect discarded draft identities");

            // A provider can strip Message-ID from its All Mail view while
            // retaining Mailficient's UUID/revision headers. New cache rows
            // persist the verified derived identity so this remains indexed.
            const string managed_sql = "SELECT m.id FROM cached_messages m " +
                "JOIN cached_mailboxes b ON b.id=m.mailbox_id " +
                "WHERE m.account_id=? AND b.role IN (?,?) " +
                "AND m.managed_draft_identity<>'' " +
                "AND m.managed_draft_identity<>'!' " +
                "AND m.managed_draft_identity=?";
            if (database.prepare_v2 (managed_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare managed draft copy cleanup");
            statement.bind_text (1, account_id);
            statement.bind_int (2, (int) MailboxRole.DRAFTS);
            statement.bind_int (3, (int) MailboxRole.ARCHIVE);
            statement.bind_text (4, expected_id);
            while ((row = statement.step ()) == Sqlite.ROW)
                ids.add (statement.column_text (0));
            if (row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect managed draft copies");

            // Rows created before managed_draft_identity existed have an
            // empty migration marker. Parse their already-bounded raw headers
            // once on this rare explicit-discard path, then persist either the
            // verified identity or a negative marker for future indexed use.
            var migrated_identities = new Gee.HashMap<string, string> ();
            const string legacy_sql = "SELECT m.id,m.raw_headers," +
                "m.internet_message_id FROM cached_messages m " +
                "JOIN cached_mailboxes b ON b.id=m.mailbox_id " +
                "WHERE m.account_id=? AND b.role IN (?,?) " +
                "AND m.internet_message_id='' AND m.managed_draft_identity='' " +
                "AND m.raw_headers LIKE '%X-Mailficient-Draft-ID:%' " +
                "AND m.raw_headers LIKE '%X-Mailficient-Draft-Revision:%'";
            if (database.prepare_v2 (legacy_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare legacy managed draft cleanup");
            statement.bind_text (1, account_id);
            statement.bind_int (2, (int) MailboxRole.DRAFTS);
            statement.bind_int (3, (int) MailboxRole.ARCHIVE);
            while ((row = statement.step ()) == Sqlite.ROW) {
                string message_id = statement.column_text (0);
                string managed_identity = managed_draft_identity_from_cached_headers (
                    statement.column_text (1), statement.column_text (2));
                migrated_identities[message_id] = managed_identity;
                if (managed_identity == expected_id) ids.add (message_id);
            }
            if (row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect legacy managed draft copies");
            const string migrate_sql = "UPDATE cached_messages SET " +
                "managed_draft_identity=? WHERE id=? AND managed_draft_identity=''";
            if (database.prepare_v2 (migrate_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare managed draft cache migration");
            foreach (var message_id in migrated_identities.keys) {
                statement.bind_text (1, migrated_identities[message_id]);
                statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not migrate managed draft cache identity");
                statement.reset (); statement.clear_bindings ();
            }
            // Mark the remaining legacy no-ID rows in one bounded SQL update.
            // They have no complete managed header pair and need not be parsed
            // or accumulated in memory on every later Cancel.
            const string negative_sql = "UPDATE cached_messages SET " +
                "managed_draft_identity=? WHERE account_id=? " +
                "AND internet_message_id='' AND managed_draft_identity='' " +
                "AND mailbox_id IN (SELECT id FROM cached_mailboxes " +
                "WHERE account_id=? AND role IN (?,?))";
            if (database.prepare_v2 (negative_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare negative managed draft migration");
            statement.bind_text (1, NO_MANAGED_DRAFT_IDENTITY);
            statement.bind_text (2, account_id); statement.bind_text (3, account_id);
            statement.bind_int (4, (int) MailboxRole.DRAFTS);
            statement.bind_int (5, (int) MailboxRole.ARCHIVE);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not complete managed draft cache migration");
        }

        // The exact folder+UID lookup uses cached_mailboxes(account,remote)
        // and cached_messages(account,mailbox,uid) indexes. For a no-ID draft,
        // this row is the provider copy from which the editable mapping and
        // fingerprint were established; the retained tombstone itself never
        // falls back to UID alone.
        if (mailbox_name != "" && remote_uid != "") {
            const string location_sql = "SELECT m.id,m.internet_message_id," +
                "m.draft_content_fingerprint " +
                "FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id " +
                "WHERE m.account_id=? AND b.account_id=? AND b.remote_name=? " +
                "AND m.remote_uid=?";
            if (database.prepare_v2 (location_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare discarded draft location cleanup");
            statement.bind_text (1, account_id); statement.bind_text (2, account_id);
            statement.bind_text (3, mailbox_name); statement.bind_text (4, remote_uid);
            while ((row = statement.step ()) == Sqlite.ROW) {
                string candidate_id = canonical_message_id (statement.column_text (1));
                if ((expected_id != "" && candidate_id == expected_id) ||
                    (fingerprint != "" && candidate_id == "" &&
                     statement.column_text (2) == fingerprint))
                    ids.add (statement.column_text (0));
            }
            if (row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect the discarded draft location");
        }

        foreach (var id in ids) delete_cached_message (id);
    }

    private static string canonical_message_id (string value) {
        string result = value.strip ();
        if (result.length >= 2 && result.has_prefix ("<") &&
            result.has_suffix (">"))
            result = result.substring (1, result.length - 2).strip ();
        return result;
    }

    private static string managed_draft_identity_for_message (Message message) {
        return managed_draft_identity_from_cached_headers (
            message.raw_headers, message.internet_message_id);
    }

    private static string managed_draft_identity_from_cached_headers (
        string raw_headers, string internet_message_id) {
        string managed_id = raw_header_value (
            raw_headers, "X-Mailficient-Draft-ID");
        string revision_text = raw_header_value (
            raw_headers, "X-Mailficient-Draft-Revision");
        int64 revision = 0;
        if (!Uuid.string_is_valid (managed_id))
            return NO_MANAGED_DRAFT_IDENTITY;
        if (!int64.try_parse (revision_text, out revision) || revision <= 0)
            return NO_MANAGED_DRAFT_IDENTITY;
        string expected = Draft.remote_message_id_for (managed_id, revision);
        string actual = canonical_message_id (internet_message_id);
        // Extension headers only verify a managed identity when Message-ID is
        // absent or agrees exactly. Never let attacker-controlled conflicting
        // headers turn an unrelated cached message into a purge candidate.
        return actual == "" || actual == expected ? expected :
            NO_MANAGED_DRAFT_IDENTITY;
    }

    private static string raw_header_value (string raw_headers, string target) {
        string normalized = raw_headers.replace ("\r\n", "\n").replace ("\r", "\n");
        foreach (var line in normalized.split ("\n")) {
            if (line == "" || line[0] == ' ' || line[0] == '\t') continue;
            int separator = line.index_of_char (':');
            if (separator <= 0) continue;
            if (line.substring (0, separator).strip ().ascii_casecmp (target) != 0)
                continue;
            return line.substring (separator + 1).strip ();
        }
        return "";
    }

    private static string draft_location_key (string mailbox_name, string remote_uid) {
        return mailbox_name + "\x1f" + remote_uid;
    }

    private static string draft_fingerprint_location_key (string fingerprint,
                                                          string mailbox_name,
                                                          string remote_uid) {
        return fingerprint + "\x1e" + draft_location_key (mailbox_name, remote_uid);
    }

    private void load_remote_draft_tombstones (string account_id,
                                               Gee.Set<string> message_ids,
                                               Gee.Set<string> fingerprint_locations) throws MailError {
        Sqlite.Statement statement;
        string sql = "SELECT expected_message_id,expected_fingerprint," +
            "mailbox_name,remote_uid FROM pending_remote_draft_deletions " +
            "WHERE account_id=? AND suppress_reimport=1 AND " +
            "(permanent_tombstone=1 OR " +
            "(completed_at=0 AND mailbox_name<>'' AND remote_uid<>'') OR " +
            "(CASE WHEN completed_at=0 THEN created_at ELSE completed_at END)>" +
            "strftime('%s','now')-" +
            TRANSIENT_DRAFT_TOMBSTONE_SECONDS.to_string () + ")";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare discarded draft filtering");
        statement.bind_text (1, account_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string message_id = canonical_message_id (statement.column_text (0));
            if (message_id != "") message_ids.add (message_id);
            else {
                string fingerprint = statement.column_text (1);
                string mailbox_name = statement.column_text (2);
                string remote_uid = statement.column_text (3);
                if (fingerprint != "" && mailbox_name != "" && remote_uid != "")
                    fingerprint_locations.add (draft_fingerprint_location_key (
                        fingerprint, mailbox_name, remote_uid));
            }
        }
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not load discarded draft filtering");
    }

    public int draft_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM drafts", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count drafts");
        return statement.column_int (0);
    }

    public Gee.ArrayList<Message> list_saved_draft_messages () throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT d.id,d.account_id,d.recipients_to,d.subject,d.body_text,d.modified_at,EXISTS(SELECT 1 FROM draft_attachments a WHERE a.draft_id=d.id) FROM drafts d WHERE NOT EXISTS(SELECT 1 FROM outbox o WHERE o.draft_id=d.id) ORDER BY d.modified_at DESC";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare draft summary loading");
        var result = new Gee.ArrayList<Message> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string preview = statement.column_text (4).replace ("\n", " ").strip ();
            var date = new DateTime.from_unix_local (statement.column_int64 (5));
            string timestamp = date == null ? "Draft" : date.format ("%b %e").strip ();
            result.add (new Message ("local-draft:" + statement.column_text (0), "local-drafts", "Draft", "",
                statement.column_text (2), statement.column_text (3).strip () == "" ? "(No Subject)" : statement.column_text (3),
                preview, "", timestamp, false, false, statement.column_int (6) != 0, 1, false,
                statement.column_text (1)));
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load draft summaries");
        return result;
    }

    public int outbox_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM outbox", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count queued messages");
        return statement.column_int (0);
    }

    public Gee.ArrayList<Message> list_outbox_messages () throws MailError {
        recover_expired_outbox_claims ();
        Sqlite.Statement statement;
        const string sql = "SELECT d.id,d.account_id,d.recipients_to,d.subject,d.body_text,o.attempts,o.delivery_state,o.undo_until,EXISTS(SELECT 1 FROM draft_attachments a WHERE a.draft_id=d.id) FROM outbox o JOIN drafts d ON d.id=o.draft_id ORDER BY o.rowid DESC";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox summary loading");
        var result = new Gee.ArrayList<Message> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            int state = statement.column_int (6); string preview;
            if (state == (int) OutboxDeliveryState.QUEUED &&
                statement.column_int64 (7) > new DateTime.now_utc ().to_unix ())
                preview = "Undo Send available — open this message to cancel delivery";
            else if (state == (int) OutboxDeliveryState.SENDING)
                preview = "Delivery status uncertain — this message will not resend automatically";
            else if (state == (int) OutboxDeliveryState.ACCEPTED)
                preview = "Sent — waiting for local Outbox cleanup";
            else if (state == (int) OutboxDeliveryState.REJECTED)
                preview = "Rejected by the mail server — review and correct before trying again";
            else if (state == (int) OutboxDeliveryState.PREPARING)
                preview = "Preparing to send in the background";
            else
                preview = statement.column_int (5) > 0 ? "Send failed — Mailficient will retry automatically" : "Waiting to send";
            result.add (new Message ("local-outbox:" + statement.column_text (0), "local-outbox", "Outbox", "",
                statement.column_text (2), statement.column_text (3).strip () == "" ? "(No Subject)" : statement.column_text (3),
                preview, statement.column_text (4), "Queued", false, false, statement.column_int (8) != 0, 1, false,
                statement.column_text (1)));
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Outbox summaries");
        return result;
    }

    public int64? next_outbox_attempt (string account_id) throws MailError {
        recover_expired_outbox_claims ();
        Sqlite.Statement statement;
        const string sql = "SELECT MIN(CASE WHEN o.delivery_state=? THEN o.next_attempt_at ELSE o.lease_until END) " +
            "FROM outbox o JOIN drafts d ON d.id=o.draft_id WHERE d.account_id=? AND o.delivery_state IN (?,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox scheduling");
        statement.bind_int (1, (int) OutboxDeliveryState.QUEUED); statement.bind_text (2, account_id);
        statement.bind_int (3, (int) OutboxDeliveryState.QUEUED);
        statement.bind_int (4, (int) OutboxDeliveryState.PREPARING);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not inspect Outbox scheduling");
        if (statement.column_type (0) == Sqlite.NULL) return null;
        return statement.column_int64 (0);
    }

    public Gee.ArrayList<OutboxItem> list_outbox_items () throws MailError {
        recover_expired_outbox_claims ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT draft_id,attempts,next_attempt_at,last_error,delivery_state,undo_until FROM outbox ORDER BY rowid DESC", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox loading");
        var result = new Gee.ArrayList<OutboxItem> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            var draft = load_draft (statement.column_text (0));
            if (draft != null) result.add (new OutboxItem (draft, statement.column_int (1),
                statement.column_int64 (2), statement.column_text (3),
                (OutboxDeliveryState) statement.column_int (4),
                statement.column_int64 (5)));
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Outbox messages");
        return result;
    }

    public OutboxItem? find_outbox_item (string draft_id) throws MailError {
        recover_expired_outbox_claims ();
        Sqlite.Statement statement;
        const string sql = "SELECT attempts,next_attempt_at,last_error,delivery_state,undo_until FROM outbox WHERE draft_id=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox item loading");
        statement.bind_text (1, draft_id);
        int row = statement.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the Outbox item");
        int attempts = statement.column_int (0);
        int64 next_attempt_at = statement.column_int64 (1);
        string last_error = statement.column_text (2);
        var delivery_state = (OutboxDeliveryState) statement.column_int (3);
        int64 undo_until = statement.column_int64 (4);
        var draft = load_draft (draft_id);
        if (draft == null) return null;
        return new OutboxItem (draft, attempts, next_attempt_at, last_error,
            delivery_state, undo_until);
    }

    public int outbox_attempts (string draft_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT attempts FROM outbox WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare outbox status");
        statement.bind_text (1, draft_id);
        int result = statement.step ();
        if (result == Sqlite.DONE) return -1;
        if (result != Sqlite.ROW) throw new MailError.STORAGE ("Could not read outbox status");
        return statement.column_int (0);
    }

    public Gee.ArrayList<Draft> list_pending_sends (string account_id, bool due_only = true) throws MailError {
        recover_expired_outbox_claims ();
        Sqlite.Statement statement;
        string sql = "SELECT d.id FROM outbox o JOIN drafts d ON d.id=o.draft_id WHERE d.account_id=? AND o.delivery_state=" +
            ((int) OutboxDeliveryState.QUEUED).to_string () +
            (due_only ? " AND o.next_attempt_at<=strftime('%s','now')" : "") + " ORDER BY o.rowid";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued-message loading");
        statement.bind_text (1, account_id);
        var ids = new Gee.ArrayList<string> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load queued messages");
        var drafts = new Gee.ArrayList<Draft> ();
        foreach (var id in ids) {
            var draft = load_draft (id); if (draft != null) drafts.add (draft);
        }
        return drafts;
    }

    public Gee.ArrayList<Draft> list_accepted_sends (string account_id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT d.id FROM outbox o JOIN drafts d ON d.id=o.draft_id WHERE d.account_id=? AND o.delivery_state=2 ORDER BY o.rowid";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare accepted-message cleanup");
        statement.bind_text (1, account_id); var ids = new Gee.ArrayList<string> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load accepted messages");
        var drafts = new Gee.ArrayList<Draft> ();
        foreach (var id in ids) { var draft = load_draft (id); if (draft != null) drafts.add (draft); }
        return drafts;
    }

    public void save_account (AccountSettings account) throws MailError {
        account.validate ();
        Sqlite.Statement statement;
        const string sql = "INSERT OR REPLACE INTO accounts(id,display_name,email,incoming_host,incoming_port,incoming_encryption,incoming_username,outgoing_host,outgoing_port,outgoing_encryption,outgoing_username,authentication,online_account_path) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare account storage");
        statement.bind_text (1, account.id); statement.bind_text (2, account.display_name); statement.bind_text (3, account.email);
        statement.bind_text (4, account.incoming_host); statement.bind_int (5, (int) account.incoming_port); statement.bind_int (6, (int) account.incoming_encryption); statement.bind_text (7, account.incoming_username);
        statement.bind_text (8, account.outgoing_host); statement.bind_int (9, (int) account.outgoing_port); statement.bind_int (10, (int) account.outgoing_encryption); statement.bind_text (11, account.outgoing_username);
        statement.bind_int (12, (int) account.authentication); statement.bind_text (13, account.online_account_path);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save account settings");
    }

    public Gee.List<AccountSettings> list_accounts () throws MailError {
        var result = new Gee.ArrayList<AccountSettings> ();
        Sqlite.Statement statement;
        const string sql = "SELECT id,display_name,email,incoming_host,incoming_port,incoming_encryption,incoming_username,outgoing_host,outgoing_port,outgoing_encryption,outgoing_username,authentication,online_account_path FROM accounts ORDER BY display_name COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare account loading");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            var account = new AccountSettings ();
            account.id = statement.column_text (0); account.display_name = statement.column_text (1); account.email = statement.column_text (2);
            account.incoming_host = statement.column_text (3); account.incoming_port = (uint) statement.column_int (4); account.incoming_encryption = (EncryptionMode) statement.column_int (5); account.incoming_username = statement.column_text (6);
            account.outgoing_host = statement.column_text (7); account.outgoing_port = (uint) statement.column_int (8); account.outgoing_encryption = (EncryptionMode) statement.column_int (9); account.outgoing_username = statement.column_text (10);
            account.authentication = (AuthenticationMode) statement.column_int (11); account.online_account_path = statement.column_text (12);
            result.add (account);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load account settings");
        return result;
    }

    public AccountSettings? find_account (string id) throws MailError {
        foreach (var account in list_accounts ()) if (account.id == id) return account;
        return null;
    }

    public void delete_account (string id) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement cleanup;
            if (database.prepare_v2 ("INSERT OR IGNORE INTO pending_credential_cleanup(account_id,created_at) VALUES(?,strftime('%s','now'))", -1, out cleanup) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare secure account cleanup");
            cleanup.bind_text (1, id);
            if (cleanup.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve secure account cleanup");
            delete_bound ("DELETE FROM message_fts WHERE id IN (SELECT id FROM cached_messages WHERE account_id=?)", id);
            delete_bound ("DELETE FROM pending_mutations WHERE account_id=?", id);
            delete_bound ("DELETE FROM pending_transfers WHERE account_id=?", id);
            delete_bound ("DELETE FROM pending_deletions WHERE account_id=?", id);
            delete_bound ("DELETE FROM pending_folder_purges WHERE account_id=?", id);
            // Removing an account is local-only.  Do not contact the provider
            // later to delete Drafts that the user may still need there.
            delete_bound ("DELETE FROM pending_remote_draft_deletions WHERE account_id=?", id);
            delete_bound ("DELETE FROM remote_draft_upload_attempts WHERE account_id=?", id);
            delete_bound ("DELETE FROM cached_messages WHERE account_id=?", id);
            delete_bound ("DELETE FROM cached_mailboxes WHERE account_id=?", id);
            delete_bound ("DELETE FROM outbox WHERE draft_id IN (SELECT id FROM drafts WHERE account_id=?)", id);
            delete_bound ("DELETE FROM drafts WHERE account_id=?", id);
            delete_bound ("DELETE FROM preferences WHERE key=?", "signature." + id);
            delete_bound ("DELETE FROM preferences WHERE key=?", "signature-enabled." + id);
            delete_bound ("DELETE FROM accounts WHERE id=?", id);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public Gee.ArrayList<string> list_pending_credential_cleanups () throws MailError {
        var result = new Gee.ArrayList<string> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT account_id FROM pending_credential_cleanup ORDER BY created_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare secure cleanup loading");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) result.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load secure account cleanup");
        return result;
    }

    public void complete_credential_cleanup (string account_id) throws MailError {
        delete_bound ("DELETE FROM pending_credential_cleanup WHERE account_id=?", account_id);
    }

    public void queue_credential_cleanup (string account_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT OR IGNORE INTO pending_credential_cleanup(account_id,created_at) VALUES(?,strftime('%s','now'))", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare secure credential cleanup");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not queue secure credential cleanup");
    }

    private void delete_bound (string sql, string value) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare account data removal");
        statement.bind_text (1, value);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not remove account data");
    }

    private void delete_bound_int64 (string sql, int64 value) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare account data removal");
        statement.bind_int64 (1, value);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not remove account data");
    }

    public void cache_message (Message message) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            cache_message_row (message);
            execute ("COMMIT");
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
    }

    private void cache_message_row (Message message,
                                    string draft_content_fingerprint = "") throws MailError {
        reconcile_moved_message_identity (message);
        unowned Sqlite.Statement message_statement;
        Sqlite.Statement? owned_message_statement = null;
        if (bulk_sync_mode && bulk_message_statement != null)
            message_statement = bulk_message_statement;
        else {
            owned_message_statement = prepare_message_statement ();
            message_statement = owned_message_statement;
        }
        message_statement.bind_text (1, message.id); message_statement.bind_text (2, message.mailbox_id); message_statement.bind_text (3, message.sender_name); message_statement.bind_text (4, message.sender_address);
        message_statement.bind_text (5, message.recipients); message_statement.bind_text (6, message.subject); message_statement.bind_text (7, message.preview); message_statement.bind_text (8, message.body); message_statement.bind_text (9, message.timestamp);
        message_statement.bind_int (10, message.unread ? 1 : 0); message_statement.bind_int (11, message.flagged ? 1 : 0); message_statement.bind_int (12, message.has_attachment ? 1 : 0);
        message_statement.bind_int (13, (int) message.conversation_count); message_statement.bind_int (14, message.has_remote_content ? 1 : 0); message_statement.bind_text (15, message.body_html);
        message_statement.bind_text (16, message.account_id); message_statement.bind_text (17, message.remote_uid);
        message_statement.bind_text (18, message.internet_message_id);
        message_statement.bind_text (19, message.in_reply_to); message_statement.bind_text (20, message.references);
        message_statement.bind_int64 (21, message.date_unix);
        message_statement.bind_text (22, message.cc_recipients);
        message_statement.bind_text (23, message.security_status);
        message_statement.bind_text (24, message.flag_color);
        message_statement.bind_text (25, message.bcc_recipients);
        message_statement.bind_int64 (26, message.message_size);
        message_statement.bind_text (27, message.reply_to);
        message_statement.bind_text (28, message.authentication_results);
        message_statement.bind_text (29, message.list_unsubscribe);
        message_statement.bind_text (30, message.list_unsubscribe_post);
        message_statement.bind_text (31, MessageSecurityService.bounded_raw_headers (message.raw_headers));
        message_statement.bind_text (32, managed_draft_identity_for_message (message));
        message_statement.bind_text (33, draft_content_fingerprint.strip ());
        if (message_statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not cache the message");
        if (bulk_sync_mode) { message_statement.reset (); message_statement.clear_bindings (); }
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM message_fts WHERE id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not update the search index");
        statement.bind_text (1, message.id); if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the search index");
        if (database.prepare_v2 ("INSERT INTO message_fts(id,sender,recipients,subject,body) VALUES(?,?,?,?,?)", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare the search index");
        statement.bind_text (1, message.id); statement.bind_text (2, message.sender_name + " " + message.sender_address); statement.bind_text (3, message.recipients + " " + message.cc_recipients + " " + message.bcc_recipients); statement.bind_text (4, message.subject); statement.bind_text (5, message.body + " " + message.body_html);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not index the message");
        if (database.prepare_v2 ("DELETE FROM message_header_index WHERE message_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not update conversation indexing");
        statement.bind_text (1, message.id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update conversation indexing");
        var header_ids = new Gee.HashSet<string> ();
        foreach (var header in new string[] { message.internet_message_id, message.in_reply_to, message.references })
            foreach (var header_id in ConversationBuilder.header_ids (header)) header_ids.add (header_id);
        foreach (var header_id in header_ids) {
            if (database.prepare_v2 ("INSERT OR IGNORE INTO message_header_index(message_id,account_id,header_id) VALUES(?,?,?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare conversation indexing");
            statement.bind_text (1, message.id); statement.bind_text (2, message.account_id); statement.bind_text (3, header_id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not index conversation headers");
        }
        if (database.prepare_v2 ("DELETE FROM message_attachments WHERE message_id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not update cached attachments");
        statement.bind_text (1, message.id); if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update cached attachments");
        foreach (var attachment in message.attachments) {
            if (database.prepare_v2 ("INSERT INTO message_attachments(message_id,id,path,name,size,content_type,content_id,remote_part_index) VALUES(?,?,?,?,?,?,?,?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare a cached attachment");
            statement.bind_text (1, message.id); statement.bind_text (2, attachment.id); statement.bind_text (3, attachment.path);
            statement.bind_text (4, attachment.name); statement.bind_int64 (5, attachment.size); statement.bind_text (6, attachment.content_type);
            statement.bind_text (7, attachment.content_id);
            statement.bind_int (8, attachment.remote_part_index);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not cache an attachment");
        }
    }

    private Sqlite.Statement prepare_message_statement () throws MailError {
        Sqlite.Statement statement;
        const string sql = "INSERT INTO cached_messages(id,mailbox_id,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,body_html,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color,bcc_recipients,message_size,reply_to,authentication_results,list_unsubscribe,list_unsubscribe_post,raw_headers,managed_draft_identity,draft_content_fingerprint,content_extracted) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET mailbox_id=excluded.mailbox_id,sender_name=excluded.sender_name,sender_address=excluded.sender_address,recipients=excluded.recipients,subject=excluded.subject,preview=excluded.preview,body=excluded.body,timestamp=excluded.timestamp,unread=excluded.unread,flagged=excluded.flagged,has_attachment=excluded.has_attachment,conversation_count=excluded.conversation_count,has_remote_content=excluded.has_remote_content,body_html=excluded.body_html,account_id=excluded.account_id,remote_uid=excluded.remote_uid,internet_message_id=excluded.internet_message_id,in_reply_to=excluded.in_reply_to,references_header=excluded.references_header,date_unix=excluded.date_unix,cc_recipients=excluded.cc_recipients,security_status=excluded.security_status,bcc_recipients=excluded.bcc_recipients,message_size=excluded.message_size,reply_to=excluded.reply_to,authentication_results=excluded.authentication_results,list_unsubscribe=excluded.list_unsubscribe,list_unsubscribe_post=excluded.list_unsubscribe_post,raw_headers=excluded.raw_headers,managed_draft_identity=excluded.managed_draft_identity,draft_content_fingerprint=excluded.draft_content_fingerprint,content_extracted=1";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare message caching");
        return statement;
    }

    private void reconcile_moved_message_identity (Message incoming) throws MailError {
        if (incoming.account_id == "" || incoming.remote_uid == "") return;
        Sqlite.Statement statement;
        const string sql = "SELECT id FROM cached_messages WHERE account_id=? AND mailbox_id=? AND remote_uid=? AND id<>?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare moved-message reconciliation");
        statement.bind_text (1, incoming.account_id);
        statement.bind_text (2, incoming.mailbox_id);
        statement.bind_text (3, incoming.remote_uid);
        statement.bind_text (4, incoming.id);
        var replaced = new Gee.ArrayList<string> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            replaced.add (statement.column_text (0));
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not reconcile a moved message");
        foreach (var stale_id in replaced)
            if (!message_has_pending_operation (stale_id))
                delete_cached_message (stale_id);
    }

    public void store_sync_result (MailSyncResult snapshot) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            bulk_sync_mode = true;
            bulk_message_statement = prepare_message_statement ();
            var discarded_draft_ids = new Gee.HashSet<string> ();
            var discarded_draft_fingerprint_locations = new Gee.HashSet<string> ();
            load_remote_draft_tombstones (snapshot.account_id,
                discarded_draft_ids, discarded_draft_fingerprint_locations);
            var draft_container_ids = new Gee.HashSet<string> ();
            var remote_mailbox_names = new Gee.HashMap<string, string> ();
            foreach (var mailbox in snapshot.mailboxes) {
                remote_mailbox_names[mailbox.id] = mailbox.remote_name;
                if (mailbox.role == MailboxRole.DRAFTS ||
                    mailbox.role == MailboxRole.ARCHIVE)
                    draft_container_ids.add (mailbox.id);
            }
            // A provider may strip Message-ID while retaining Mailficient's
            // draft identity headers. RemoteDraftSnapshot verifies those
            // headers, so use its exact location only for this one batch; do
            // not retain a UID-only tombstone that could hide later UID reuse.
            var verified_discarded_locations = new Gee.HashSet<string> ();
            var draft_fingerprints_by_location = new Gee.HashMap<string, string> ();
            var verified_draft_copies = new Gee.ArrayList<RemoteDraftSnapshot> ();
            verified_draft_copies.add_all (snapshot.remote_drafts);
            verified_draft_copies.add_all (snapshot.verified_draft_copies);
            foreach (var remote_draft in verified_draft_copies) {
                string location_key = draft_location_key (
                    remote_draft.mailbox_name, remote_draft.remote_uid);
                if (remote_draft.content_fingerprint != "")
                    draft_fingerprints_by_location[location_key] =
                        remote_draft.content_fingerprint;
                string identity = remote_draft.internet_message_id;
                if (identity.strip () == "" && remote_draft.managed_by_mailficient)
                    identity = Draft.remote_message_id_for (remote_draft.draft.id,
                        remote_draft.draft.revision);
                identity = canonical_message_id (identity);
                bool discarded_identity = identity != "" &&
                    discarded_draft_ids.contains (identity);
                if (!discarded_identity && identity == "" &&
                    remote_draft.content_fingerprint != "")
                    discarded_identity = discarded_draft_fingerprint_locations.contains (
                        draft_fingerprint_location_key (
                            remote_draft.content_fingerprint,
                            remote_draft.mailbox_name, remote_draft.remote_uid));
                if (discarded_identity)
                    verified_discarded_locations.add (draft_location_key (
                        remote_draft.mailbox_name, remote_draft.remote_uid));
            }
            if (snapshot.folder_inventory_complete) prune_missing_mailboxes (snapshot);
            foreach (var mailbox in snapshot.mailboxes) cache_mailbox_row (mailbox);
            foreach (var mailbox in snapshot.mailboxes) {
                var remote_uids = snapshot.remote_uids_for (mailbox.id);
                if (remote_uids != null) prune_missing_messages (mailbox.id, remote_uids);
            }
            foreach (var message in snapshot.messages) {
                string message_id = canonical_message_id (message.internet_message_id);
                string remote_mailbox = remote_mailbox_names[message.mailbox_id] ?? "";
                string location_key = draft_location_key (
                    remote_mailbox, message.remote_uid);
                string verified_fingerprint =
                    draft_fingerprints_by_location[location_key] ?? "";
                bool discarded_draft = draft_container_ids.contains (message.mailbox_id) &&
                    message_id != "" &&
                    discarded_draft_ids.contains (message_id);
                if (!discarded_draft && message_id == "" &&
                    draft_container_ids.contains (message.mailbox_id)) {
                    if (remote_mailbox != "" && message.remote_uid != "")
                        discarded_draft = verified_discarded_locations.contains (
                            draft_location_key (remote_mailbox, message.remote_uid));
                }
                if (discarded_draft) delete_cached_message (message.id);
                else cache_message_row (message, verified_fingerprint);
            }
            foreach (var state in snapshot.states) update_remote_message_state (state);
            reapply_pending_state (snapshot.account_id);
            bulk_message_statement = null; bulk_sync_mode = false;
            execute ("COMMIT");
        } catch (MailError error) {
            bulk_message_statement = null; bulk_sync_mode = false;
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private void prune_missing_mailboxes (MailSyncResult snapshot) throws MailError {
        var present = new Gee.HashSet<string> ();
        foreach (var mailbox in snapshot.mailboxes) present.add (mailbox.id);
        var missing = new Gee.ArrayList<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id FROM cached_mailboxes WHERE account_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mailbox reconciliation");
        statement.bind_text (1, snapshot.account_id);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string id = statement.column_text (0); if (!present.contains (id)) missing.add (id);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not reconcile server mailboxes");
        foreach (var mailbox_id in missing) delete_cached_mailbox (mailbox_id);
    }

    private void delete_cached_mailbox (string mailbox_id) throws MailError {
        Sqlite.Statement statement;
        foreach (var sql in new string[] {
            "DELETE FROM pending_mutations WHERE message_id IN (SELECT id FROM cached_messages WHERE mailbox_id=?)",
            "DELETE FROM pending_transfers WHERE message_id IN (SELECT id FROM cached_messages WHERE mailbox_id=?)",
            "DELETE FROM message_fts WHERE id IN (SELECT id FROM cached_messages WHERE mailbox_id=?)",
            "DELETE FROM cached_messages WHERE mailbox_id=?",
            "DELETE FROM cached_mailboxes WHERE id=?"
        }) {
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare removed-mailbox cleanup");
            statement.bind_text (1, mailbox_id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not remove a deleted server mailbox");
        }
    }

    private void prune_missing_messages (string mailbox_id, Gee.Set<string> remote_uids) throws MailError {
        var missing = new Gee.ArrayList<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,remote_uid FROM cached_messages WHERE mailbox_id=? AND remote_uid<>''", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare message reconciliation");
        statement.bind_text (1, mailbox_id);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            string id = statement.column_text (0); string uid = statement.column_text (1);
            if (!remote_uids.contains (uid) && !message_has_pending_operation (id)) missing.add (id);
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not reconcile server messages");
        foreach (var id in missing) delete_cached_message (id);
    }

    private bool message_has_pending_operation (string id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM pending_mutations WHERE message_id=? UNION SELECT 1 FROM pending_transfers WHERE message_id=? LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect pending message changes");
        statement.bind_text (1, id); statement.bind_text (2, id);
        int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE) throw new MailError.STORAGE ("Could not inspect pending message changes");
        return row == Sqlite.ROW;
    }

    private void delete_cached_message (string id) throws MailError {
        Sqlite.Statement statement;
        foreach (var sql in new string[] { "DELETE FROM message_fts WHERE id=?", "DELETE FROM cached_messages WHERE id=?" }) {
            if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare deleted-message cleanup");
            statement.bind_text (1, id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not remove a deleted server message");
        }
    }

    private void update_remote_message_state (RemoteMessageState state) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE cached_messages SET unread=?,flagged=? WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare synchronized message state");
        statement.bind_int (1, state.unread ? 1 : 0); statement.bind_int (2, state.flagged ? 1 : 0);
        statement.bind_text (3, state.message_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update synchronized message state");
    }

    private void reapply_pending_state (string account_id) throws MailError {
        Sqlite.Statement statement;
        // Keep the server's authoritative mailbox total. Only adjust it by the
        // difference introduced by still-pending local operations; the cache can
        // intentionally contain fewer messages than the server reports.
        const string read_count_sql = "UPDATE cached_mailboxes SET unread_count=MAX(0,unread_count+COALESCE((" +
            "SELECT SUM(CASE WHEN p.value=1 AND m.unread=1 THEN -1 " +
            "WHEN p.value=0 AND m.unread=0 THEN 1 ELSE 0 END) " +
            "FROM pending_mutations p JOIN cached_messages m ON m.id=p.message_id " +
            "WHERE p.field=0 AND m.mailbox_id=cached_mailboxes.id),0)) WHERE account_id=?";
        if (database.prepare_v2 (read_count_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued unread-count restoration");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued unread counts");

        const string read_sql = "UPDATE cached_messages SET unread=CASE " +
            "(SELECT value FROM pending_mutations p WHERE p.message_id=cached_messages.id AND p.field=0) " +
            "WHEN 1 THEN 0 ELSE 1 END WHERE account_id=? AND EXISTS(" +
            "SELECT 1 FROM pending_mutations p WHERE p.message_id=cached_messages.id AND p.field=0)";
        if (database.prepare_v2 (read_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued read-state restoration");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued read states");

        const string flag_sql = "UPDATE cached_messages SET flagged=(" +
            "SELECT value FROM pending_mutations p WHERE p.message_id=cached_messages.id AND p.field=1) " +
            "WHERE account_id=? AND EXISTS(" +
            "SELECT 1 FROM pending_mutations p WHERE p.message_id=cached_messages.id AND p.field=1)";
        if (database.prepare_v2 (flag_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued flag-state restoration");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued flag states");

        const string move_source_count_sql = "UPDATE cached_mailboxes SET unread_count=MAX(0,unread_count-COALESCE((" +
            "SELECT COUNT(*) FROM pending_transfers p JOIN cached_messages m ON m.id=p.message_id " +
            "WHERE p.copy=0 AND p.account_id=cached_mailboxes.account_id " +
            "AND p.source_mailbox=cached_mailboxes.remote_name AND m.mailbox_id=cached_mailboxes.id AND m.unread=1),0)) " +
            "WHERE account_id=?";
        if (database.prepare_v2 (move_source_count_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued move source counts");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued move source counts");

        const string move_destination_count_sql = "UPDATE cached_mailboxes SET unread_count=unread_count+COALESCE((" +
            "SELECT COUNT(*) FROM pending_transfers p JOIN cached_messages m ON m.id=p.message_id " +
            "WHERE p.copy=0 AND p.account_id=cached_mailboxes.account_id " +
            "AND p.destination_mailbox=cached_mailboxes.remote_name AND m.mailbox_id<>cached_mailboxes.id AND m.unread=1),0) " +
            "WHERE account_id=?";
        if (database.prepare_v2 (move_destination_count_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued move destination counts");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued move destination counts");

        const string move_sql = "UPDATE cached_messages SET mailbox_id=(" +
            "SELECT b.id FROM pending_transfers p JOIN cached_mailboxes b " +
            "ON b.account_id=p.account_id AND b.remote_name=p.destination_mailbox " +
            "WHERE p.message_id=cached_messages.id AND p.copy=0 LIMIT 1) " +
            "WHERE account_id=? AND EXISTS(SELECT 1 FROM pending_transfers p JOIN cached_mailboxes b " +
            "ON b.account_id=p.account_id AND b.remote_name=p.destination_mailbox " +
            "WHERE p.message_id=cached_messages.id AND p.copy=0)";
        if (database.prepare_v2 (move_sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare queued move restoration");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not restore queued message moves");
    }

    private void cache_mailbox_row (Mailbox mailbox) throws MailError {
        Sqlite.Statement statement;
        const string sql = "INSERT OR REPLACE INTO cached_mailboxes(id,account_id,remote_name,name,icon_name,role,unread_count) VALUES(?,?,?,?,?,?,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare mailbox caching");
        statement.bind_text (1, mailbox.id); statement.bind_text (2, mailbox.account_id); statement.bind_text (3, mailbox.remote_name);
        statement.bind_text (4, mailbox.name); statement.bind_text (5, mailbox.icon_name); statement.bind_int (6, (int) mailbox.role); statement.bind_int (7, (int) mailbox.unread_count);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not cache a mailbox");
    }

    public Gee.ArrayList<Mailbox> list_cached_mailboxes () throws MailError {
        var result = new Gee.ArrayList<Mailbox> (); Sqlite.Statement statement;
        // The server's unread total can cover messages outside the bounded
        // local cache. Read the authoritative total instead of deriving it
        // from the currently cached message window.
        const string sql = "SELECT b.id,b.name,b.icon_name,b.role," +
            "b.unread_count," +
            "b.account_id,b.remote_name FROM cached_mailboxes b " +
            "ORDER BY b.account_id,CASE b.role WHEN 0 THEN 0 WHEN 4 THEN 1 WHEN 3 THEN 2 WHEN 5 THEN 3 WHEN 6 THEN 4 WHEN 7 THEN 5 ELSE 6 END,b.name COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare cached mailbox loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new Mailbox (statement.column_text (0), statement.column_text (1), statement.column_text (2), (MailboxRole) statement.column_int (3),
                (uint) statement.column_int (4), statement.column_text (5), statement.column_text (6)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load cached mailboxes");
        // A provider such as Gmail reports All Mail's unread count including
        // unread Inbox copies. Keep an account's Archive badge consistent
        // with the filtered Archive rows the user can actually open.
        foreach (var mailbox in result)
            if (mailbox.role == MailboxRole.ARCHIVE)
                mailbox.unread_count = archive_unread_count (mailbox.id);
        return result;
    }

    public Gee.ArrayList<Message> list_cached_messages (string mailbox_id,
                                                        int limit = MESSAGE_LIST_LIMIT,
                                                        int offset = 0,
                                                        bool unread_only = false,
                                                        MessageSortMode sort_mode = MessageSortMode.NEWEST) throws MailError {
        Sqlite.Statement statement;
        // Lists can contain tens of thousands of rows. Bodies, HTML, and
        // attachment objects are loaded only after selecting a message.
        const string columns = "m.id,m.mailbox_id,m.sender_name,m.sender_address,m.recipients,m.subject,m.preview,m.timestamp,m.unread,m.flagged,m.has_attachment,m.conversation_count,m.has_remote_content,m.account_id,m.remote_uid,m.internet_message_id,m.in_reply_to,m.references_header,m.date_unix,m.cc_recipients,m.flag_color,m.bcc_recipients,m.message_size";
        bool bind_mailbox = false;
        string predicate = cached_mailbox_predicate (mailbox_id, out bind_mailbox);
        if (unread_only) predicate += " AND m.unread=1";
        string grouping = is_grouped_smart_mailbox (mailbox_id) ?
            " GROUP BY m.account_id,COALESCE(NULLIF(m.internet_message_id,''),m.id)" : "";
        int bounded_limit = int.max (1, int.min (MESSAGE_LIST_LIMIT + 1, limit));
        int bounded_offset = int.max (0, offset);
        string sql = "SELECT %s FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE %s%s ORDER BY %s LIMIT %d OFFSET %d".printf (
            columns, predicate, grouping, message_order (sort_mode), bounded_limit, bounded_offset);
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare cached message loading");
        if (bind_mailbox) statement.bind_text (1, mailbox_id);
        var result = new Gee.ArrayList<Message> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (message_summary_from_row (statement));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load cached messages");
        return result;
    }

    public int count_cached_messages (string mailbox_id, bool unread_only = false) throws MailError {
        Sqlite.Statement statement; bool bind_mailbox = false;
        string predicate = cached_mailbox_predicate (mailbox_id, out bind_mailbox);
        if (unread_only) predicate += " AND m.unread=1";
        string sql = is_grouped_smart_mailbox (mailbox_id) ?
            "SELECT COUNT(*) FROM (SELECT 1 FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE %s GROUP BY m.account_id,COALESCE(NULLIF(m.internet_message_id,''),m.id))".printf (predicate) :
            "SELECT COUNT(*) FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE %s".printf (predicate);
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached message counting");
        if (bind_mailbox) statement.bind_text (1, mailbox_id);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count cached messages");
        return statement.column_int (0);
    }

    private static string cached_mailbox_predicate (string mailbox_id, out bool bind_mailbox) {
        string predicate; bind_mailbox = false;
        // Gmail stores one physical row per folder for the same logical
        // message. All Mail is exposed as role=ARCHIVE, but an Archive view
        // should contain only messages which no longer have an Inbox, Drafts,
        // Sent, Junk, or Trash owner. The account + Message-ID index keeps
        // this correlated check bounded, and blank Message-IDs remain visible rather than
        // risking a false match.
        string archived_only = "NOT EXISTS(" +
            "SELECT 1 FROM cached_messages other " +
            "JOIN cached_mailboxes other_box ON other_box.id=other.mailbox_id " +
            "WHERE other.account_id=m.account_id AND m.internet_message_id<>'' " +
            "AND other.internet_message_id=m.internet_message_id " +
            "AND other_box.role IN (0,3,4,5,6))";
        switch (mailbox_id) {
        case "unified-inbox": predicate = "b.role=0"; break;
        case "unified-vip": predicate = "EXISTS(SELECT 1 FROM vip_senders v WHERE v.address=m.sender_address COLLATE NOCASE)"; break;
        case "unified-flagged": predicate = "m.flagged=1"; break;
        case "unified-sent": predicate = "b.role=4"; break;
        case "unified-archive":
            predicate = "b.role=7 AND " + archived_only;
            break;
        case "unified-junk": predicate = "b.role=5"; break;
        case "unified-trash": predicate = "b.role=6"; break;
        case "unified-snoozed": predicate = "EXISTS(SELECT 1 FROM snoozed_messages s WHERE s.message_id=m.id AND s.until_unix>strftime('%s','now'))"; break;
        default:
            // Apply the same logical Archive semantics when the user expands
            // an account and opens its physical All Mail folder. Other folder
            // roles retain the exact mailbox query.
            predicate = "m.mailbox_id=? AND (b.role<>7 OR " + archived_only + ")";
            bind_mailbox = true;
            break;
        }
        if (mailbox_id != "unified-snoozed")
            predicate += " AND NOT EXISTS(SELECT 1 FROM snoozed_messages s WHERE s.message_id=m.id AND s.until_unix>strftime('%s','now'))";
        return predicate;
    }

    private static bool is_grouped_smart_mailbox (string mailbox_id) {
        return mailbox_id == "unified-vip" || mailbox_id == "unified-flagged";
    }

    private static string message_order (MessageSortMode mode) {
        switch (mode) {
        case MessageSortMode.OLDEST: return "m.date_unix ASC,m.rowid ASC";
        case MessageSortMode.SENDER: return "m.sender_name COLLATE NOCASE,m.date_unix DESC,m.rowid DESC";
        case MessageSortMode.SUBJECT: return "m.subject COLLATE NOCASE,m.date_unix DESC,m.rowid DESC";
        case MessageSortMode.UNREAD_FIRST: return "m.unread DESC,m.date_unix DESC,m.rowid DESC";
        case MessageSortMode.FLAGGED_FIRST: return "m.flagged DESC,m.date_unix DESC,m.rowid DESC";
        default: return "m.date_unix DESC,m.rowid DESC";
        }
    }

    public bool is_vip_sender (string address) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM vip_senders WHERE address=? COLLATE NOCASE LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect VIP senders");
        statement.bind_text (1, address.strip ()); int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE) throw new MailError.STORAGE ("Could not inspect VIP senders");
        return row == Sqlite.ROW;
    }

    public void set_vip_sender (string address, bool vip) throws MailError {
        string normalized = address.strip ().down ();
        if (!RecipientParser.is_valid_address (normalized)) throw new MailError.STORAGE ("The sender address is invalid");
        Sqlite.Statement statement;
        string sql = vip ? "INSERT OR IGNORE INTO vip_senders(address) VALUES(?)" : "DELETE FROM vip_senders WHERE address=? COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare the VIP sender change");
        statement.bind_text (1, normalized);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the VIP sender");
    }

    public bool is_remote_sender_trusted (string address) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM trusted_remote_senders WHERE address=? COLLATE NOCASE LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect trusted remote-content senders");
        statement.bind_text (1, address.strip ()); int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect trusted remote-content senders");
        return row == Sqlite.ROW;
    }

    public void set_remote_sender_trusted (string address, bool trusted) throws MailError {
        string normalized = address.strip ().down ();
        if (!RecipientParser.is_valid_address (normalized))
            throw new MailError.STORAGE ("The sender address is invalid");
        Sqlite.Statement statement;
        string sql = trusted ?
            "INSERT OR IGNORE INTO trusted_remote_senders(address,created_at) VALUES(?,strftime('%s','now'))" :
            "DELETE FROM trusted_remote_senders WHERE address=? COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the remote-content sender change");
        statement.bind_text (1, normalized);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not update the remote-content sender policy");
    }

    public Gee.List<string> list_trusted_remote_senders () throws MailError {
        var senders = new Gee.ArrayList<string> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT address FROM trusted_remote_senders ORDER BY address COLLATE NOCASE", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare trusted remote-content sender loading");
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) senders.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load trusted remote-content senders");
        return senders;
    }

    public bool is_safe_sender (string address) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM safe_senders WHERE address=? COLLATE NOCASE LIMIT 1", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect Safe Senders");
        statement.bind_text (1, address.strip ()); int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect Safe Senders");
        return row == Sqlite.ROW;
    }

    public void set_safe_sender (string address, bool safe) throws MailError {
        string normalized = MessageSecurityService.normalize_sender (address);
        if (!RecipientParser.is_valid_address (normalized))
            throw new MailError.STORAGE ("The sender address is invalid");
        Sqlite.Statement statement; string sql = safe ?
            "INSERT OR IGNORE INTO safe_senders(address,created_at) VALUES(?,strftime('%s','now'))" :
            "DELETE FROM safe_senders WHERE address=? COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare the Safe Sender change");
        statement.bind_text (1, normalized);
        if (statement.step () != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not update Safe Senders");
    }

    public Gee.List<string> list_safe_senders () throws MailError {
        var senders = new Gee.ArrayList<string> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT address FROM safe_senders ORDER BY address COLLATE NOCASE", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Safe Sender loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW) senders.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Safe Senders");
        return senders;
    }

    public uint smart_unread_count (string mailbox_id) throws MailError {
        Sqlite.Statement statement; string predicate;
        switch (mailbox_id) {
        case "unified-vip": predicate = "EXISTS(SELECT 1 FROM vip_senders v WHERE v.address=m.sender_address COLLATE NOCASE)"; break;
        case "unified-flagged": predicate = "m.flagged=1"; break;
        default: predicate = "0"; break;
        }
        string sql = is_grouped_smart_mailbox (mailbox_id) ?
            "SELECT COUNT(*) FROM (SELECT 1 FROM cached_messages m WHERE m.unread=1 AND %s GROUP BY m.account_id,COALESCE(NULLIF(m.internet_message_id,''),m.id))".printf (predicate) :
            "SELECT COUNT(*) FROM cached_messages m WHERE m.unread=1 AND %s".printf (predicate);
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare smart mailbox counting");
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count smart mailbox messages");
        return (uint) statement.column_int64 (0);
    }

    public Message? find_cached_message (string id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT id,mailbox_id,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,body_html,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color,bcc_recipients,message_size,reply_to,authentication_results,list_unsubscribe,list_unsubscribe_post,raw_headers FROM cached_messages WHERE id=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare cached message lookup");
        statement.bind_text (1, id); int row = statement.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not load the cached message");
        var message = message_from_row (statement); load_message_attachments (message);
        message.labels.add_all (labels_for_message (message.id)); return message;
    }

    public string remote_mailbox_for_message (string id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT b.remote_name FROM cached_messages m " +
            "JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE m.id=? LIMIT 1";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare remote attachment location");
        statement.bind_text (1, id);
        int row = statement.step ();
        if (row == Sqlite.DONE)
            throw new MailError.ATTACHMENT ("The source message is no longer available in the local cache");
        if (row != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not load the remote attachment location");
        return statement.column_text (0);
    }

    public Gee.List<Message> conversation_for (Message selected) throws MailError {
        var candidates = new Gee.ArrayList<Message> ();
        // Conversation membership is a graph over Message-ID, In-Reply-To,
        // and References.  Walk that graph through the small header index
        // instead of scanning every cached message in the account.
        bool indexed = false;
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT 1 FROM message_header_index WHERE account_id=? LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare conversation indexing lookup");
        statement.bind_text (1, selected.account_id);
        indexed = statement.step () == Sqlite.ROW;
        bool selected_indexed = false;
        if (database.prepare_v2 ("SELECT 1 FROM message_header_index WHERE message_id=? LIMIT 1", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare selected conversation lookup");
        statement.bind_text (1, selected.id);
        selected_indexed = statement.step () == Sqlite.ROW;
        var candidate_ids = new Gee.HashSet<string> ();
        var frontier = new Gee.HashSet<string> ();
        foreach (var header in new string[] { selected.internet_message_id, selected.in_reply_to, selected.references })
            foreach (var header_id in ConversationBuilder.header_ids (header)) frontier.add (header_id);
        if (indexed) {
            while (frontier.size > 0 && candidate_ids.size < MAX_CONVERSATION_MESSAGES * 4) {
                var placeholders = new StringBuilder ();
                for (int index = 0; index < frontier.size; index++) {
                    if (placeholders.len > 0) placeholders.append (",");
                    placeholders.append ("?");
                }
                string sql = "SELECT DISTINCT m.id,m.mailbox_id,m.sender_name,m.sender_address,m.recipients,m.subject,m.preview,m.timestamp,m.unread,m.flagged,m.has_attachment,m.conversation_count,m.has_remote_content,m.account_id,m.remote_uid,m.internet_message_id,m.in_reply_to,m.references_header,m.date_unix,m.cc_recipients,m.flag_color,m.bcc_recipients,m.message_size FROM cached_messages m JOIN message_header_index h ON h.message_id=m.id WHERE m.account_id=? AND h.header_id IN (" + placeholders.str + ")";
                if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare conversation loading");
                int bind = 1; statement.bind_text (bind++, selected.account_id);
                foreach (var header_id in frontier) statement.bind_text (bind++, header_id);
                var next_frontier = new Gee.HashSet<string> (); int row;
                while ((row = statement.step ()) == Sqlite.ROW) {
                    var candidate = message_summary_from_row (statement);
                    if (!candidate_ids.contains (candidate.id) && candidate.id != selected.id) {
                        candidate_ids.add (candidate.id); candidates.add (candidate);
                        foreach (var header in new string[] { candidate.internet_message_id, candidate.in_reply_to, candidate.references })
                            foreach (var header_id in ConversationBuilder.header_ids (header))
                                if (!frontier.contains (header_id)) next_frontier.add (header_id);
                    }
                }
                if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load conversation messages");
                frontier = next_frontier;
            }
        } else if (frontier.size > 0 || (indexed && !selected_indexed)) {
            // Caches created before the conversation index are still valid.
            // Use the old bounded fallback once; subsequent sync writes repair
            // the index for those messages.
            const string fallback_sql = "SELECT id,mailbox_id,sender_name,sender_address,recipients,subject,preview,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,flag_color,bcc_recipients,message_size FROM cached_messages WHERE account_id=? ORDER BY rowid";
            if (database.prepare_v2 (fallback_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare conversation fallback");
            statement.bind_text (1, selected.account_id); int row;
            while ((row = statement.step ()) == Sqlite.ROW) candidates.add (message_summary_from_row (statement));
            if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load conversation fallback");
        }
        var related = new ConversationBuilder ().build (candidates, selected);
        var result = new Gee.ArrayList<Message> ();
        foreach (var summary in related) {
            if (result.size >= MAX_CONVERSATION_MESSAGES) break;
            if (summary.id == selected.id) result.add (selected);
            else {
                var full = find_cached_message (summary.id);
                if (full != null) result.add (full);
            }
        }
        if (!contains_message_id (result, selected.id)) {
            if (result.size >= MAX_CONVERSATION_MESSAGES) result.remove_at (result.size - 1);
            result.add (selected);
        }
        return result;
    }

    private static bool contains_message_id (Gee.List<Message> messages, string id) {
        foreach (var message in messages) if (message.id == id) return true;
        return false;
    }

    private static Message message_summary_from_row (Sqlite.Statement statement) {
        var message = new Message (statement.column_text (0), statement.column_text (1),
            statement.column_text (2), statement.column_text (3), statement.column_text (4),
            statement.column_text (5), statement.column_text (6), "", statement.column_text (7),
            statement.column_int (8) != 0, statement.column_int (9) != 0,
            statement.column_int (10) != 0, (uint) statement.column_int (11),
            statement.column_int (12) != 0, statement.column_text (13),
            statement.column_text (14), statement.column_text (15), statement.column_text (16),
            statement.column_text (17), statement.column_int64 (18), statement.column_text (19),
            statement.column_text (20));
        message.bcc_recipients = statement.column_text (21);
        message.message_size = statement.column_int64 (22);
        return message;
    }

    private static Message message_from_row (Sqlite.Statement statement) {
        var message = new Message (statement.column_text (0), statement.column_text (1), statement.column_text (2), statement.column_text (3), statement.column_text (4),
            statement.column_text (5), statement.column_text (6), statement.column_text (7), statement.column_text (8), statement.column_int (9) != 0,
            statement.column_int (10) != 0, statement.column_int (11) != 0, (uint) statement.column_int (12), statement.column_int (13) != 0,
            statement.column_text (15), statement.column_text (16), statement.column_text (17), statement.column_text (18), statement.column_text (19), statement.column_int64 (20), statement.column_text (21), statement.column_text (23));
        message.body_html = statement.column_text (14); message.security_status = statement.column_text (22);
        message.bcc_recipients = statement.column_text (24); message.message_size = statement.column_int64 (25);
        message.reply_to = statement.column_text (26); message.authentication_results = statement.column_text (27);
        message.list_unsubscribe = statement.column_text (28); message.list_unsubscribe_post = statement.column_text (29);
        message.raw_headers = statement.column_text (30); return message;
    }

    private void load_message_attachments (Message message) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id,path,name,size,content_type,content_id,remote_part_index FROM message_attachments WHERE message_id=? ORDER BY rowid", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached attachment loading");
        statement.bind_text (1, message.id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            message.add_attachment (new Attachment (statement.column_text (0), statement.column_text (1),
                statement.column_text (2), statement.column_int64 (3), statement.column_text (4),
                statement.column_text (5), statement.column_int (6)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load cached attachments");
    }

    public uint unified_unread_count (MailboxRole role = MailboxRole.INBOX) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 (
                "SELECT COALESCE(SUM(unread_count),0) FROM cached_mailboxes WHERE role=?", -1,
                out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not count unread mail");
        statement.bind_int (1, (int) role);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count unread mail");
        return (uint) statement.column_int (0);
    }

    // Preserve the server's authoritative unread total for mail outside the
    // bounded local window, but subtract cached unread All Mail rows which are
    // hidden because their logical message is still owned by another standard
    // mailbox such as Inbox or Sent.
    // With an empty mailbox_id this returns the adjusted total for every
    // account; otherwise it returns the account Archive mailbox's badge.
    public uint archive_unread_count (string mailbox_id = "") throws MailError {
        Sqlite.Statement statement;
        string sql = "SELECT COALESCE(SUM(MAX(0,b.unread_count-(" +
            "SELECT COUNT(*) FROM cached_messages m WHERE m.mailbox_id=b.id AND m.unread=1 AND EXISTS(" +
            "SELECT 1 FROM cached_messages other " +
            "JOIN cached_mailboxes other_box ON other_box.id=other.mailbox_id " +
            "WHERE other.account_id=m.account_id AND m.internet_message_id<>'' " +
            "AND other.internet_message_id=m.internet_message_id " +
            "AND other_box.role IN (0,3,4,5,6))" +
            "))),0) FROM cached_mailboxes b WHERE b.role=7";
        if (mailbox_id != "") sql += " AND b.id=?";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not count visible unread Archive mail");
        if (mailbox_id != "") statement.bind_text (1, mailbox_id);
        if (statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count visible unread Archive mail");
        return (uint) statement.column_int (0);
    }

    public int cached_message_count (string account_id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM cached_messages WHERE account_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached message counting");
        statement.bind_text (1, account_id);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count cached messages");
        return statement.column_int (0);
    }

    public Gee.HashSet<string> cached_message_ids (string account_id) throws MailError {
        var ids = new Gee.HashSet<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT id FROM cached_messages WHERE account_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached message identity loading");
        statement.bind_text (1, account_id);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load cached message identities");
        return ids;
    }

    public Gee.HashSet<string> cached_extracted_message_ids (string account_id) throws MailError {
        var ids = new Gee.HashSet<string> ();
        Sqlite.Statement statement;
        if (database.prepare_v2 (
                "SELECT id FROM cached_messages WHERE account_id=? AND content_extracted=1",
                -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare extracted message identity loading");
        statement.bind_text (1, account_id);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not load extracted message identities");
        return ids;
    }

    public bool set_cached_read (string id, bool read) throws MailError {
        var changed_accounts = new Gee.HashSet<string> ();
        bool changed = false;
        execute ("BEGIN IMMEDIATE");
        try {
            foreach (var logical_id in logical_cached_message_ids (id)) {
                Sqlite.Statement lookup;
                if (database.prepare_v2 ("SELECT unread,mailbox_id FROM cached_messages WHERE id=?", -1, out lookup) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare cached read-state update");
                lookup.bind_text (1, logical_id);
                int row = lookup.step ();
                if (row != Sqlite.ROW && row != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not inspect cached read state");
                if (row == Sqlite.ROW) {
                    int previous = lookup.column_int (0);
                    string mailbox_id = lookup.column_text (1);
                    int unread = read ? 0 : 1;
                    if (previous == unread) continue;
                    changed = true;
                    update_cached_flag (logical_id, "unread", unread);
                    Sqlite.Statement count;
                    if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=MAX(0,unread_count+?) WHERE id=?", -1, out count) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not prepare mailbox unread-count update");
                    count.bind_int (1, unread - previous); count.bind_text (2, mailbox_id);
                    if (count.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not update the mailbox unread count");
                    string? changed_account = queue_message_state_rows (
                        logical_id, MessageStateField.READ, read);
                    if (changed_account != null) changed_accounts.add (changed_account);
                }
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        foreach (var account_id in changed_accounts) mutation_queued (account_id);
        return changed;
    }
    public bool set_cached_flagged (string id, bool flagged) throws MailError {
        var changed_accounts = new Gee.HashSet<string> ();
        bool changed = false;
        execute ("BEGIN IMMEDIATE");
        try {
            foreach (var logical_id in logical_cached_message_ids (id)) {
                Sqlite.Statement lookup;
                if (database.prepare_v2 ("SELECT flagged FROM cached_messages WHERE id=?", -1, out lookup) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare cached flag-state inspection");
                lookup.bind_text (1, logical_id);
                int row = lookup.step ();
                if (row != Sqlite.ROW && row != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not inspect cached flag state");
                if (row != Sqlite.ROW || (lookup.column_int (0) != 0) == flagged) continue;
                changed = true;
                update_cached_flag (logical_id, "flagged", flagged ? 1 : 0);
                string? changed_account = queue_message_state_rows (
                    logical_id, MessageStateField.FLAGGED, flagged);
                if (changed_account != null) changed_accounts.add (changed_account);
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        foreach (var account_id in changed_accounts) mutation_queued (account_id);
        return changed;
    }

    public bool set_cached_flag_color (string id, string color) throws MailError {
        var changed_accounts = new Gee.HashSet<string> ();
        bool changed = false;
        execute ("BEGIN IMMEDIATE");
        try {
            foreach (var logical_id in logical_cached_message_ids (id)) {
                Sqlite.Statement lookup;
                if (database.prepare_v2 ("SELECT flagged,flag_color FROM cached_messages WHERE id=?", -1, out lookup) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare flag color inspection");
                lookup.bind_text (1, logical_id);
                int row = lookup.step ();
                if (row != Sqlite.ROW && row != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not inspect flag color");
                if (row != Sqlite.ROW) continue;
                bool was_flagged = lookup.column_int (0) != 0;
                if (was_flagged && lookup.column_text (1) == color) continue;
                changed = true;
                Sqlite.Statement statement;
                if (database.prepare_v2 ("UPDATE cached_messages SET flag_color=?,flagged=1 WHERE id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare flag color update");
                statement.bind_text (1, color); statement.bind_text (2, logical_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not update flag color");
                if (!was_flagged) {
                    string? changed_account = queue_message_state_rows (
                        logical_id, MessageStateField.FLAGGED, true);
                    if (changed_account != null) changed_accounts.add (changed_account);
                }
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        foreach (var account_id in changed_accounts) mutation_queued (account_id);
        return changed;
    }

    // Gmail and some other providers cache the same logical email in Inbox,
    // All Mail, and label folders. A state action applies to every physical
    // copy so grouped favorites cannot be kept alive by a stale sibling.
    private Gee.ArrayList<string> logical_cached_message_ids (string id) throws MailError {
        var ids = new Gee.ArrayList<string> ();
        Sqlite.Statement statement;
        const string sql = "SELECT sibling.id FROM cached_messages selected " +
            "JOIN cached_messages sibling ON sibling.account_id=selected.account_id " +
            "AND ((selected.internet_message_id<>'' AND sibling.internet_message_id=selected.internet_message_id) " +
            "OR sibling.id=selected.id) WHERE selected.id=? ORDER BY sibling.id";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare logical message state update");
        statement.bind_text (1, id);
        int row;
        while ((row = statement.step ()) == Sqlite.ROW) ids.add (statement.column_text (0));
        if (row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not resolve logical message copies");
        return ids;
    }

    private void update_cached_flag (string id, string column, int value) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE cached_messages SET " + column + "=? WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached message state update");
        statement.bind_int (1, value); statement.bind_text (2, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update cached message state");
    }

    private string? queue_message_state_rows (string id, MessageStateField field, bool value) throws MailError {
        Sqlite.Statement lookup;
        const string lookup_sql = "SELECT m.account_id,b.remote_name,m.remote_uid FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE m.id=? AND m.account_id<>'' AND m.remote_uid<>''";
        if (database.prepare_v2 (lookup_sql, -1, out lookup) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare an offline mail change");
        lookup.bind_text (1, id); int row = lookup.step ();
        if (row == Sqlite.DONE) return null;
        if (row != Sqlite.ROW) throw new MailError.STORAGE ("Could not preserve the offline mail change");
        string account_id = lookup.column_text (0); string mailbox_name = lookup.column_text (1); string remote_uid = lookup.column_text (2);
        Sqlite.Statement statement;
        const string sql = "INSERT INTO pending_mutations(message_id,account_id,mailbox_name,remote_uid,field,value,created_at) VALUES(?,?,?,?,?,?,strftime('%s','now')) ON CONFLICT(message_id,field) DO UPDATE SET account_id=excluded.account_id,mailbox_name=excluded.mailbox_name,remote_uid=excluded.remote_uid,value=excluded.value,created_at=excluded.created_at";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare an offline mail change");
        statement.bind_text (1, id); statement.bind_text (2, account_id); statement.bind_text (3, mailbox_name); statement.bind_text (4, remote_uid);
        statement.bind_int (5, (int) field); statement.bind_int (6, value ? 1 : 0);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the offline mail change");
        return account_id;
    }

    public Gee.ArrayList<PendingMutation> list_pending_mutations (string account_id) throws MailError {
        var result = new Gee.ArrayList<PendingMutation> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT message_id,account_id,mailbox_name,remote_uid,field,value FROM pending_mutations WHERE account_id=? ORDER BY created_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare pending mail changes");
        statement.bind_text (1, account_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new PendingMutation (statement.column_text (0), statement.column_text (1), statement.column_text (2), statement.column_text (3),
                (MessageStateField) statement.column_int (4), statement.column_int (5) != 0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load pending mail changes");
        return result;
    }

    public void complete_pending_mutation (PendingMutation mutation) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM pending_mutations WHERE message_id=? AND field=? AND value=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare pending mail change completion");
        statement.bind_text (1, mutation.message_id); statement.bind_int (2, (int) mutation.field); statement.bind_int (3, mutation.value ? 1 : 0);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not complete the pending mail change");
    }

    public int pending_mutation_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM pending_mutations", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count pending mail changes");
        return statement.column_int (0);
    }

    public void queue_message_transfer (string message_id, MailboxRole destination_role, bool copy) throws MailError {
        Sqlite.Statement statement;
        const string lookup = "SELECT destination.id FROM cached_messages m JOIN cached_mailboxes destination ON destination.account_id=m.account_id AND destination.role=? WHERE m.id=? ORDER BY CASE WHEN destination.remote_name LIKE '.#evolution/%' THEN 1 ELSE 0 END,destination.remote_name COLLATE NOCASE LIMIT 1";
        if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare a message move");
        statement.bind_int (1, (int) destination_role); statement.bind_text (2, message_id);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("The destination mailbox is unavailable for this account");
        queue_message_transfer_to (message_id, statement.column_text (0), copy);
    }

    public void queue_junk_classification (string message_id, bool junk,
                                           bool remember_sender = true) throws MailError {
        execute ("BEGIN IMMEDIATE");
        string account_id = "";
        try {
            Sqlite.Statement statement;
            const string lookup = "SELECT m.account_id,source.remote_name,m.remote_uid,destination.id,destination.remote_name,m.sender_address FROM cached_messages m JOIN cached_mailboxes source ON source.id=m.mailbox_id JOIN cached_mailboxes destination ON destination.account_id=m.account_id AND destination.role=? WHERE m.id=? AND m.account_id<>'' AND m.remote_uid<>'' ORDER BY CASE WHEN destination.remote_name LIKE '.#evolution/%' THEN 1 ELSE 0 END,destination.remote_name COLLATE NOCASE LIMIT 1";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare junk classification");
            statement.bind_int (1, (int) (junk ? MailboxRole.JUNK : MailboxRole.INBOX));
            statement.bind_text (2, message_id);
            if (statement.step () != Sqlite.ROW)
                throw new MailError.STORAGE (junk ? "The Junk mailbox is unavailable for this account" :
                    "The Inbox is unavailable for this account");
            account_id = statement.column_text (0);
            string source_name = statement.column_text (1);
            string remote_uid = statement.column_text (2);
            string destination_id = statement.column_text (3);
            string destination_name = statement.column_text (4);
            string sender_address = statement.column_text (5);

            const string mutation_sql = "INSERT INTO pending_mutations(message_id,account_id,mailbox_name,remote_uid,field,value,created_at) VALUES(?,?,?,?,?,?,strftime('%s','now')) ON CONFLICT(message_id,field) DO UPDATE SET account_id=excluded.account_id,mailbox_name=excluded.mailbox_name,remote_uid=excluded.remote_uid,value=excluded.value,created_at=excluded.created_at";
            foreach (var field in new MessageStateField[] { MessageStateField.JUNK, MessageStateField.NOT_JUNK }) {
                if (database.prepare_v2 (mutation_sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not preserve junk classification");
                statement.bind_text (1, message_id); statement.bind_text (2, account_id);
                statement.bind_text (3, source_name); statement.bind_text (4, remote_uid);
                statement.bind_int (5, (int) field);
                bool enabled = field == MessageStateField.JUNK ? junk : !junk;
                statement.bind_int (6, enabled ? 1 : 0);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not preserve junk classification");
            }

            // Preserve the original source and UID when an offline user changes
            // their mind before the first transfer reaches the server.
            const string transfer_sql = "INSERT INTO pending_transfers(message_id,account_id,source_mailbox,destination_mailbox,remote_uid,copy,created_at) VALUES(?,?,?,?,?,0,strftime('%s','now')) ON CONFLICT(message_id) DO UPDATE SET destination_mailbox=excluded.destination_mailbox,copy=0,created_at=excluded.created_at";
            if (database.prepare_v2 (transfer_sql, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not preserve the junk mailbox move");
            statement.bind_text (1, message_id); statement.bind_text (2, account_id);
            statement.bind_text (3, source_name); statement.bind_text (4, destination_name);
            statement.bind_text (5, remote_uid);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve the junk mailbox move");

            if (database.prepare_v2 ("UPDATE cached_messages SET mailbox_id=? WHERE id=?", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the local junk mailbox move");
            statement.bind_text (1, destination_id); statement.bind_text (2, message_id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not update the local junk mailbox move");
            if (junk && remember_sender) {
                try { add_junk_rule (JunkRuleKind.ADDRESS, sender_address); }
                catch (MailError error) {
                    warning ("Could not remember junk sender %s: %s",
                        sender_address, error.message);
                }
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        mutation_queued (account_id);
    }

    public void queue_message_transfer_to (string message_id, string destination_id, bool copy) throws MailError {
        execute ("BEGIN IMMEDIATE");
        string account_id;
        try {
            Sqlite.Statement statement;
            const string lookup = "SELECT m.account_id,source.id,source.remote_name,m.remote_uid,destination.remote_name,m.unread FROM cached_messages m JOIN cached_mailboxes source ON source.id=m.mailbox_id JOIN cached_mailboxes destination ON destination.id=? AND destination.account_id=m.account_id WHERE m.id=? LIMIT 1";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare a message transfer");
            statement.bind_text (1, destination_id); statement.bind_text (2, message_id);
            if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("The destination mailbox is unavailable for this account");
            account_id = statement.column_text (0); string source_id = statement.column_text (1);
            string source_name = statement.column_text (2); string remote_uid = statement.column_text (3);
            string destination_name = statement.column_text (4); bool unread = statement.column_int (5) != 0;
            const string insert = "INSERT INTO pending_transfers(message_id,account_id,source_mailbox,destination_mailbox,remote_uid,copy,created_at) VALUES(?,?,?,?,?,?,strftime('%s','now')) ON CONFLICT(message_id) DO UPDATE SET destination_mailbox=excluded.destination_mailbox,copy=excluded.copy,created_at=excluded.created_at";
            if (database.prepare_v2 (insert, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not preserve the message move");
            statement.bind_text (1, message_id); statement.bind_text (2, account_id); statement.bind_text (3, source_name); statement.bind_text (4, destination_name);
            statement.bind_text (5, remote_uid); statement.bind_int (6, copy ? 1 : 0);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the message move");
            if (copy) {
                // A copy has no destination row until the server operation is
                // flushed. Keep a local optimistic copy so the destination
                // favorite reflects the action immediately. The synthetic id
                // is replaced naturally when the next sync sees the server's
                // destination UID.
                string copy_id = "%s:copy:%s".printf (message_id, Uuid.string_random ());
                const string copy_message = "INSERT INTO cached_messages(" +
                    "id,mailbox_id,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged," +
                    "has_attachment,conversation_count,has_remote_content,body_html,account_id,remote_uid,internet_message_id," +
                    "in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color,bcc_recipients,message_size," +
                    "reply_to,authentication_results,list_unsubscribe,list_unsubscribe_post,raw_headers,managed_draft_identity," +
                    "draft_content_fingerprint,content_extracted) " +
                    "SELECT ?,?,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged,has_attachment," +
                    "conversation_count,has_remote_content,body_html,account_id,remote_uid," +
                    "internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color,bcc_recipients,message_size," +
                    "reply_to,authentication_results,list_unsubscribe,list_unsubscribe_post,raw_headers,managed_draft_identity," +
                    "draft_content_fingerprint,content_extracted " +
                    "FROM cached_messages WHERE id=?";
                if (database.prepare_v2 (copy_message, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the local message copy");
                statement.bind_text (1, copy_id); statement.bind_text (2, destination_id); statement.bind_text (3, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not create the local message copy");

                const string copy_index = "INSERT INTO message_fts(id,sender,recipients,subject,body) " +
                    "SELECT ?,sender,recipients,subject,body FROM message_fts WHERE id=?";
                if (database.prepare_v2 (copy_index, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the copied search index");
                statement.bind_text (1, copy_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not copy the search index");

                const string copy_headers = "INSERT INTO message_header_index(message_id,account_id,header_id) " +
                    "SELECT ?,account_id,header_id FROM message_header_index WHERE message_id=?";
                if (database.prepare_v2 (copy_headers, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare copied conversation indexing");
                statement.bind_text (1, copy_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not copy conversation indexing");

                const string copy_attachments = "INSERT INTO message_attachments(message_id,id,path,name,size,content_type,content_id,remote_part_index) " +
                    "SELECT ?,id,path,name,size,content_type,content_id,remote_part_index FROM message_attachments WHERE message_id=?";
                if (database.prepare_v2 (copy_attachments, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare copied attachments");
                statement.bind_text (1, copy_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not copy attachments");

                if (database.prepare_v2 ("UPDATE pending_transfers SET message_id=? WHERE message_id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not associate the local message copy");
                statement.bind_text (1, copy_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not associate the local message copy");
            } else {
                if (database.prepare_v2 ("UPDATE cached_messages SET mailbox_id=? WHERE id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare the local message move");
                statement.bind_text (1, destination_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the local message move");
            }
            if (unread) {
                if (copy) {
                    if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=unread_count+1 WHERE id=?", -1, out statement) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not update the copied mailbox count");
                    statement.bind_text (1, destination_id);
                    if (statement.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not update the copied mailbox count");
                } else if (source_id != destination_id) {
                    if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=MAX(0,unread_count-1) WHERE id=?", -1, out statement) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not update the source mailbox count");
                    statement.bind_text (1, source_id);
                    if (statement.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not update the source mailbox count");
                    if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=unread_count+1 WHERE id=?", -1, out statement) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not update the destination mailbox count");
                    statement.bind_text (1, destination_id);
                    if (statement.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not update the destination mailbox count");
                }
            }
            execute ("COMMIT");
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
        mutation_queued (account_id);
    }

    public void undo_queued_transfer (string message_id, string original_mailbox_id) throws MailError {
        execute ("BEGIN IMMEDIATE");
        bool was_pending = false;
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("SELECT 1 FROM pending_transfers WHERE message_id=? LIMIT 1", -1,
                                     out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not inspect the queued message move");
            statement.bind_text (1, message_id); was_pending = statement.step () == Sqlite.ROW;
            if (was_pending) {
                delete_bound ("DELETE FROM pending_transfers WHERE message_id=?", message_id);
                if (database.prepare_v2 ("DELETE FROM pending_mutations WHERE message_id=? AND field IN (?,?)",
                                         -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not cancel queued junk state");
                statement.bind_text (1, message_id);
                statement.bind_int (2, (int) MessageStateField.JUNK);
                statement.bind_int (3, (int) MessageStateField.NOT_JUNK);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not cancel queued junk state");
                if (database.prepare_v2 ("UPDATE cached_messages SET mailbox_id=? WHERE id=?", -1,
                                         out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not restore the message location");
                statement.bind_text (1, original_mailbox_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE || database.changes () != 1)
                    throw new MailError.STORAGE ("Could not restore the message location");
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        // If the server operation already left the queue, undo is a normal
        // durable move back to the original mailbox.
        if (!was_pending) queue_message_transfer_to (message_id, original_mailbox_id, false);
    }

    public void queue_permanent_delete (string message_id) throws MailError {
        execute ("BEGIN IMMEDIATE"); string account_id = "";
        try {
            Sqlite.Statement statement;
            const string lookup = "SELECT m.account_id,b.remote_name,m.remote_uid,b.role FROM cached_messages m JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE m.id=? LIMIT 1";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare permanent deletion");
            statement.bind_text (1, message_id);
            if (statement.step () != Sqlite.ROW)
                throw new MailError.STORAGE ("The message is no longer available");
            account_id = statement.column_text (0); string mailbox_name = statement.column_text (1);
            string remote_uid = statement.column_text (2); var role = (MailboxRole) statement.column_int (3);
            if (role != MailboxRole.TRASH && role != MailboxRole.JUNK)
                throw new MailError.STORAGE ("Only messages in Trash or Junk can be deleted permanently");
            const string insert = "INSERT OR REPLACE INTO pending_deletions(message_id,account_id,mailbox_name,remote_uid,created_at) VALUES(?,?,?,?,strftime('%s','now'))";
            if (database.prepare_v2 (insert, -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not preserve permanent deletion");
            statement.bind_text (1, message_id); statement.bind_text (2, account_id);
            statement.bind_text (3, mailbox_name); statement.bind_text (4, remote_uid);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not preserve permanent deletion");
            delete_bound ("DELETE FROM message_fts WHERE id=?", message_id);
            delete_bound ("DELETE FROM cached_messages WHERE id=?", message_id);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        mutation_queued (account_id);
    }

    public Gee.ArrayList<PendingDeletion> list_pending_deletions (string account_id) throws MailError {
        var result = new Gee.ArrayList<PendingDeletion> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT message_id,account_id,mailbox_name,remote_uid FROM pending_deletions WHERE account_id=? ORDER BY created_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare pending deletions");
        statement.bind_text (1, account_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new PendingDeletion (statement.column_text (0), statement.column_text (1),
                statement.column_text (2), statement.column_text (3)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load pending deletions");
        return result;
    }

    public void complete_pending_deletion (PendingDeletion deletion) throws MailError {
        delete_bound ("DELETE FROM pending_deletions WHERE message_id=?", deletion.message_id);
    }

    public void queue_role_purge (MailboxRole role) throws MailError {
        if (role != MailboxRole.TRASH && role != MailboxRole.JUNK)
            throw new MailError.STORAGE ("Only Trash or Junk can be emptied");
        foreach (var mailbox in list_cached_mailboxes ())
            if (mailbox.role == role) queue_mailbox_purge (mailbox.id);
    }

    public void queue_mailbox_purge (string mailbox_id) throws MailError {
        execute ("BEGIN IMMEDIATE"); string account_id = "";
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("SELECT account_id,remote_name,role FROM cached_mailboxes WHERE id=?", -1,
                                     out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare folder emptying");
            statement.bind_text (1, mailbox_id);
            if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("The folder is unavailable");
            account_id = statement.column_text (0); string mailbox_name = statement.column_text (1);
            var role = (MailboxRole) statement.column_int (2);
            if (role != MailboxRole.TRASH && role != MailboxRole.JUNK)
                throw new MailError.STORAGE ("Only Trash or Junk can be emptied");
            if (database.prepare_v2 ("INSERT OR REPLACE INTO pending_folder_purges(account_id,mailbox_name,created_at) VALUES(?,?,strftime('%s','now'))", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not preserve folder emptying");
            statement.bind_text (1, account_id); statement.bind_text (2, mailbox_name);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve folder emptying");
            if (database.prepare_v2 ("DELETE FROM message_fts WHERE id IN (SELECT id FROM cached_messages WHERE mailbox_id=?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not clear the folder search index");
            statement.bind_text (1, mailbox_id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not clear the folder search index");
            delete_bound ("DELETE FROM cached_messages WHERE mailbox_id=?", mailbox_id);
            if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=0 WHERE id=?", -1,
                                     out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the emptied folder unread-count update");
            statement.bind_text (1, mailbox_id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not reset the emptied folder unread count");
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        mutation_queued (account_id);
    }

    public Gee.ArrayList<PendingFolderPurge> list_pending_folder_purges (string account_id) throws MailError {
        var result = new Gee.ArrayList<PendingFolderPurge> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT account_id,mailbox_name FROM pending_folder_purges WHERE account_id=? ORDER BY created_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare pending folder emptying");
        statement.bind_text (1, account_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new PendingFolderPurge (statement.column_text (0), statement.column_text (1)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load pending folder emptying");
        return result;
    }

    public void complete_pending_folder_purge (PendingFolderPurge purge) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM pending_folder_purges WHERE account_id=? AND mailbox_name=?", -1,
                                 out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare folder-empty completion");
        statement.bind_text (1, purge.account_id); statement.bind_text (2, purge.mailbox_name);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not complete folder emptying");
    }

    public Gee.ArrayList<PendingTransfer> list_pending_transfers (string account_id) throws MailError {
        var result = new Gee.ArrayList<PendingTransfer> (); Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT message_id,account_id,source_mailbox,destination_mailbox,remote_uid,copy FROM pending_transfers WHERE account_id=? ORDER BY created_at", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare pending message moves");
        statement.bind_text (1, account_id); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new PendingTransfer (statement.column_text (0), statement.column_text (1), statement.column_text (2),
                statement.column_text (3), statement.column_text (4), statement.column_int (5) != 0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load pending message moves");
        return result;
    }

    public void complete_pending_transfer (PendingTransfer transfer, string? destination_uid = null) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            if (!transfer.copy && destination_uid != null && destination_uid != "") {
                if (database.prepare_v2 ("UPDATE cached_messages SET remote_uid=? WHERE id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the moved message identity");
                statement.bind_text (1, destination_uid); statement.bind_text (2, transfer.message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the moved message identity");

                if (database.prepare_v2 ("UPDATE pending_mutations SET mailbox_name=?,remote_uid=? WHERE message_id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare pending state after a move");
                statement.bind_text (1, transfer.destination_mailbox); statement.bind_text (2, destination_uid);
                statement.bind_text (3, transfer.message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve pending state after a move");

                if (database.prepare_v2 ("UPDATE pending_deletions SET mailbox_name=?,remote_uid=? WHERE message_id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare deletion after a move");
                statement.bind_text (1, transfer.destination_mailbox); statement.bind_text (2, destination_uid);
                statement.bind_text (3, transfer.message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve deletion after a move");

                // If the user moved the message again while this server request
                // was in flight, chain the queued operation from its new real
                // location instead of retrying the already accepted move.
                if (database.prepare_v2 ("UPDATE pending_transfers SET source_mailbox=?,remote_uid=? WHERE message_id=? AND destination_mailbox<>?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare a chained message move");
                statement.bind_text (1, transfer.destination_mailbox); statement.bind_text (2, destination_uid);
                statement.bind_text (3, transfer.message_id); statement.bind_text (4, transfer.destination_mailbox);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve a chained message move");
            }
            if (transfer.copy && destination_uid != null && destination_uid != "") {
                if (database.prepare_v2 ("UPDATE cached_messages SET remote_uid=? WHERE id=?", -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare the copied message identity");
                statement.bind_text (1, destination_uid); statement.bind_text (2, transfer.message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the copied message identity");
            } else if (transfer.copy) {
                // Without UIDPLUS the accepted copy has no stable destination
                // identity yet. Let the next mailbox sync install the server
                // row instead of retaining a duplicate optimistic row.
                foreach (var sql in new string[] {
                    "DELETE FROM message_fts WHERE id=?",
                    "DELETE FROM message_header_index WHERE message_id=?",
                    "DELETE FROM message_attachments WHERE message_id=?",
                    "DELETE FROM cached_messages WHERE id=?"
                }) {
                    if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not remove the temporary message copy");
                    statement.bind_text (1, transfer.message_id);
                    if (statement.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not remove the temporary message copy");
                }
            }
            if (database.prepare_v2 ("DELETE FROM pending_transfers WHERE message_id=? AND destination_mailbox=? AND copy=?", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare message move completion");
            statement.bind_text (1, transfer.message_id); statement.bind_text (2, transfer.destination_mailbox);
            statement.bind_int (3, transfer.copy ? 1 : 0);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not complete the message move");
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public int pending_transfer_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM pending_transfers", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count pending message moves");
        return statement.column_int (0);
    }

    public void clear_demo_data () throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            execute (
            "DELETE FROM outbox WHERE draft_id IN (SELECT id FROM drafts WHERE account_id='demo-account');" +
            "DELETE FROM drafts WHERE account_id='demo-account';" +
            "DELETE FROM message_fts WHERE id IN (SELECT id FROM cached_messages WHERE account_id IN ('','demo-account'));" +
            "DELETE FROM cached_messages WHERE account_id IN ('','demo-account');");
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public Gee.List<Message> search_messages (SearchQuery query,
                                              int limit = MESSAGE_LIST_LIMIT,
                                              int offset = 0,
                                              MessageSortMode sort_mode = MessageSortMode.NEWEST) throws MailError {
        var sql = new StringBuilder ("SELECT m.id,m.mailbox_id,m.sender_name,m.sender_address,m.recipients,m.subject,m.preview,m.timestamp,m.unread,m.flagged,m.has_attachment,m.conversation_count,m.has_remote_content,m.account_id,m.remote_uid,m.internet_message_id,m.in_reply_to,m.references_header,m.date_unix,m.cc_recipients,m.flag_color,m.bcc_recipients,m.message_size FROM cached_messages m JOIN message_fts f ON f.id=m.id LEFT JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE 1=1");
        var values = new Gee.ArrayList<string> ();
        append_search_predicates (sql, query, values);
        int bounded_limit = int.max (1, int.min (MESSAGE_LIST_LIMIT + 1, limit));
        int bounded_offset = int.max (0, offset);
        sql.append_printf (" ORDER BY %s LIMIT %d OFFSET %d", message_order (sort_mode), bounded_limit, bounded_offset);
        Sqlite.Statement statement;
        if (database.prepare_v2 (sql.str, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare cached-mail search");
        for (int index = 0; index < values.size; index++) statement.bind_text (index + 1, values[index]);
        var result = new Gee.ArrayList<Message> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW)
            result.add (message_summary_from_row (statement));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Cached-mail search failed");
        return result;
    }

    public int count_search_messages (SearchQuery query) throws MailError {
        var sql = new StringBuilder ("SELECT COUNT(*) FROM cached_messages m JOIN message_fts f ON f.id=m.id LEFT JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE 1=1");
        var values = new Gee.ArrayList<string> ();
        append_search_predicates (sql, query, values);
        Sqlite.Statement statement;
        if (database.prepare_v2 (sql.str, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare cached-mail search counting");
        for (int index = 0; index < values.size; index++) statement.bind_text (index + 1, values[index]);
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count cached-mail search results");
        return statement.column_int (0);
    }

    private static void append_search_predicates (StringBuilder sql, SearchQuery query,
                                                   Gee.ArrayList<string> values) {
        if (query.clauses.size > 0) {
            sql.append (" AND (");
            for (int clause_index = 0; clause_index < query.clauses.size; clause_index++) {
                if (clause_index > 0) sql.append (" OR ");
                sql.append ("("); var clause = query.clauses[clause_index];
                for (int term_index = 0; term_index < clause.terms.size; term_index++) {
                    if (term_index > 0) sql.append (" AND ");
                    append_search_term (sql, clause.terms[term_index], values);
                }
                sql.append (")");
            }
            sql.append (")");
        } else {
            if (query.text != "") { sql.append (" AND message_fts MATCH ?"); values.add (quote_fts (query.text)); }
            if (query.sender != null) { sql.append (" AND lower(m.sender_name || ' ' || m.sender_address) LIKE ? ESCAPE '\\'"); values.add (like_value (query.sender)); }
            if (query.recipient != null) { sql.append (" AND lower(m.recipients || ' ' || m.cc_recipients || ' ' || m.bcc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (query.recipient)); }
            if (query.cc != null) { sql.append (" AND lower(m.cc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (query.cc)); }
            if (query.bcc != null) { sql.append (" AND lower(m.bcc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (query.bcc)); }
            if (query.subject != null) { sql.append (" AND lower(m.subject) LIKE ? ESCAPE '\\'"); values.add (like_value (query.subject)); }
            if (query.mailbox != null) { sql.append (" AND (lower(m.mailbox_id)=? OR lower(b.name)=? OR lower(b.remote_name)=?)"); values.add (query.mailbox.down ()); values.add (query.mailbox.down ()); values.add (query.mailbox.down ()); }
            if (query.label != null) { sql.append (" AND EXISTS(SELECT 1 FROM message_labels ml JOIN mail_labels l ON l.id=ml.label_id WHERE ml.message_id=m.id AND lower(l.name)=?)"); values.add (query.label.down ()); }
            if (query.after_unix != null) { sql.append (" AND m.date_unix>=CAST(? AS INTEGER)"); values.add (((int64) query.after_unix).to_string ()); }
            if (query.before_unix != null) { sql.append (" AND m.date_unix<CAST(? AS INTEGER)"); values.add (((int64) query.before_unix).to_string ()); }
        }
        // These properties are also public overrides used by unread-only
        // views and account-scoped Run Now, so apply them after parsed clauses.
        // Parsed account terms already live in the authoritative clause tree
        // (where they can be negated or combined with OR). The scalar-only
        // form remains the account override used by rule Run Now.
        if (query.account != null && query.clauses.size == 0) {
            sql.append (" AND m.account_id=?"); values.add (query.account);
        }
        if (query.unread != null) sql.append (query.unread ? " AND m.unread=1" : " AND m.unread=0");
        if (query.flagged != null) sql.append (query.flagged ? " AND m.flagged=1" : " AND m.flagged=0");
        if (query.has_attachment != null) sql.append (query.has_attachment ? " AND m.has_attachment=1" : " AND m.has_attachment=0");
    }

    private static void append_search_term (StringBuilder sql, SearchTerm term,
                                            Gee.ArrayList<string> values) {
        if (term.negated) sql.append ("NOT (");
        switch (term.field) {
        case SearchField.ANY:
            // FTS5 MATCH cannot safely sit below every SQL OR/NOT shape. A
            // correlated ID subquery preserves advanced boolean semantics.
            sql.append ("m.id IN (SELECT id FROM message_fts WHERE message_fts MATCH ?)");
            values.add (quote_fts_term (term.value, term.exact)); break;
        case SearchField.SENDER:
            sql.append ("lower(m.sender_name || ' ' || m.sender_address) LIKE ? ESCAPE '\\'"); values.add (like_value (term.value)); break;
        case SearchField.RECIPIENT:
            sql.append ("lower(m.recipients || ' ' || m.cc_recipients || ' ' || m.bcc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (term.value)); break;
        case SearchField.CC:
            sql.append ("lower(m.cc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (term.value)); break;
        case SearchField.BCC:
            sql.append ("lower(m.bcc_recipients) LIKE ? ESCAPE '\\'"); values.add (like_value (term.value)); break;
        case SearchField.SUBJECT:
            sql.append ("lower(m.subject) LIKE ? ESCAPE '\\'"); values.add (like_value (term.value)); break;
        case SearchField.MAILBOX:
            sql.append ("(lower(m.mailbox_id)=? OR lower(b.name)=? OR lower(b.remote_name)=?)");
            values.add (term.value.down ()); values.add (term.value.down ()); values.add (term.value.down ()); break;
        case SearchField.ACCOUNT:
            sql.append ("(lower(m.account_id)=? OR EXISTS(SELECT 1 FROM accounts a WHERE a.id=m.account_id AND (lower(a.email) LIKE ? ESCAPE '\\' OR lower(a.display_name) LIKE ? ESCAPE '\\')))" );
            values.add (term.value.down ()); values.add (like_value (term.value)); values.add (like_value (term.value)); break;
        case SearchField.LABEL:
            sql.append ("EXISTS(SELECT 1 FROM message_labels ml JOIN mail_labels l ON l.id=ml.label_id WHERE ml.message_id=m.id AND lower(l.name)=?)"); values.add (term.value.down ()); break;
        case SearchField.UNREAD: sql.append (term.value == "1" ? "m.unread=1" : "m.unread=0"); break;
        case SearchField.FLAGGED: sql.append (term.value == "1" ? "m.flagged=1" : "m.flagged=0"); break;
        case SearchField.HAS_ATTACHMENT: sql.append (term.value == "1" ? "m.has_attachment=1" : "m.has_attachment=0"); break;
        case SearchField.ATTACHMENT_NAME:
            sql.append ("EXISTS(SELECT 1 FROM message_attachments ma WHERE ma.message_id=m.id AND lower(ma.name) LIKE ? ESCAPE '\\')"); values.add (like_value (term.value)); break;
        case SearchField.ATTACHMENT_TYPE:
            sql.append ("EXISTS(SELECT 1 FROM message_attachments ma WHERE ma.message_id=m.id AND lower(ma.content_type) LIKE ? ESCAPE '\\')"); values.add (like_value (term.value)); break;
        case SearchField.AFTER:
            sql.append ("m.date_unix>=CAST(? AS INTEGER)"); values.add (term.value); break;
        case SearchField.BEFORE:
            sql.append ("m.date_unix<CAST(? AS INTEGER)"); values.add (term.value); break;
        case SearchField.DATE_RANGE: {
            string[] bounds = term.value.split (":", 2);
            if (bounds.length == 2) {
                sql.append ("(m.date_unix>=CAST(? AS INTEGER) AND m.date_unix<CAST(? AS INTEGER))");
                values.add (bounds[0]); values.add (bounds[1]);
            } else sql.append ("1=1");
            break;
        }
        case SearchField.MESSAGE_SIZE:
            if (term.comparison == SearchComparison.GREATER_THAN) sql.append ("m.message_size>CAST(? AS INTEGER)");
            else if (term.comparison == SearchComparison.LESS_THAN) sql.append ("m.message_size<CAST(? AS INTEGER)");
            else sql.append ("m.message_size=CAST(? AS INTEGER)");
            values.add (term.value); break;
        }
        if (term.negated) sql.append (")");
    }

    private static string quote_fts (string input) {
        var terms = new StringBuilder ();
        foreach (string part in input.split (" ")) {
            string clean = part.strip (); if (clean == "") continue;
            if (terms.len > 0) terms.append_c (' ');
            terms.append_c ('"');
            terms.append (clean.replace ("\"", "\"\""));
            terms.append_c ('"');
            // FTS5 prefix matching keeps incremental search useful while the
            // user is still typing (for example, "proj" matches "project").
            terms.append_c ('*');
        }
        return terms.str;
    }

    private static string quote_fts_term (string input, bool exact) {
        if (!exact) return quote_fts (input);
        return "\"" + input.replace ("\"", "\"\"") + "\"";
    }

    private static string like_value (string input) {
        return "%" + input.down ().replace ("\\", "\\\\").replace ("%", "\\%").replace ("_", "\\_") + "%";
    }
}
}
