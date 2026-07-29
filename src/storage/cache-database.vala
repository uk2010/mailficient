namespace Mailficient {
public class CacheDatabase : Object, AccountStore {
    public const int MESSAGE_LIST_LIMIT = 500;
    public const int MAX_CONVERSATION_MESSAGES = 100;
    // Recipient completion is invoked from GTK entry change handlers.  Never
    // walk an unbounded mailbox here: a large local archive would otherwise
    // make the compose window (and its Send button) appear to hang.
    public const int RECIPIENT_CANDIDATE_MESSAGE_LIMIT = 500;
    public signal void mutation_queued (string account_id);
    private Sqlite.Database database;

    public CacheDatabase (string path) throws MailError {
        if (Sqlite.Database.open (path, out database) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not open the mail cache");
        execute ("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
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
            "CREATE TABLE IF NOT EXISTS junk_rules(id INTEGER PRIMARY KEY AUTOINCREMENT,kind INTEGER NOT NULL,pattern TEXT NOT NULL COLLATE NOCASE,UNIQUE(kind,pattern));" +
            "CREATE TABLE IF NOT EXISTS mail_labels(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE COLLATE NOCASE,color TEXT NOT NULL);" +
            "CREATE TABLE IF NOT EXISTS mail_rules(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,account_id TEXT NOT NULL," +
            "field INTEGER NOT NULL,pattern TEXT NOT NULL,action INTEGER NOT NULL,value TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1);" +
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
            "CREATE TABLE IF NOT EXISTS cached_messages(" +
            "id TEXT PRIMARY KEY, mailbox_id TEXT NOT NULL, sender_name TEXT NOT NULL, sender_address TEXT NOT NULL, recipients TEXT NOT NULL," +
            "subject TEXT NOT NULL, preview TEXT NOT NULL, body TEXT NOT NULL, timestamp TEXT NOT NULL, unread INTEGER NOT NULL, flagged INTEGER NOT NULL," +
            "has_attachment INTEGER NOT NULL, conversation_count INTEGER NOT NULL, has_remote_content INTEGER NOT NULL, body_html TEXT NOT NULL," +
            "content_extracted INTEGER NOT NULL DEFAULT 0);" +
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
        ensure_column ("accounts", "authentication", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("accounts", "online_account_path", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("message_attachments", "content_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("message_attachments", "remote_part_index", "INTEGER NOT NULL DEFAULT 0");
        ensure_column ("draft_attachments", "content_id", "TEXT NOT NULL DEFAULT ''");
        ensure_column ("outbox", "delivery_state", "INTEGER NOT NULL DEFAULT 0");
        execute ("CREATE INDEX IF NOT EXISTS cached_messages_mailbox_date ON cached_messages(mailbox_id,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_mailbox_unread_date ON cached_messages(mailbox_id,unread DESC,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_messages_mailbox_flagged_date ON cached_messages(mailbox_id,flagged DESC,date_unix DESC);" +
            "CREATE INDEX IF NOT EXISTS cached_mailboxes_role_id ON cached_mailboxes(role,id);");
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
        if (database.prepare_v2 ("SELECT id,name,account_id,field,pattern,action,value,enabled FROM mail_rules ORDER BY name COLLATE NOCASE", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mail-rule loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new MailRule (statement.column_int64 (0), statement.column_text (1), statement.column_text (2),
                (MailRuleField) statement.column_int (3), statement.column_text (4),
                (MailRuleAction) statement.column_int (5), statement.column_text (6), statement.column_int (7) != 0));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load mail rules"); return result;
    }

    public void add_mail_rule (string name, string account_id, MailRuleField field, string pattern,
                               MailRuleAction action, string value = "") throws MailError {
        string clean_name = name.strip (); string clean_pattern = pattern.strip ();
        if (clean_name == "" || clean_pattern == "") throw new MailError.STORAGE ("Rule name and match text are required");
        if (action == MailRuleAction.LABEL && value.strip () == "") throw new MailError.STORAGE ("Enter a label for this rule");
        Sqlite.Statement statement;
        if (database.prepare_v2 ("INSERT INTO mail_rules(name,account_id,field,pattern,action,value,enabled) VALUES(?,?,?,?,?,?,1)", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mail-rule storage");
        statement.bind_text (1, clean_name); statement.bind_text (2, account_id);
        statement.bind_int (3, (int) field); statement.bind_text (4, clean_pattern);
        statement.bind_int (5, (int) action); statement.bind_text (6, value.strip ());
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the mail rule");
    }

    public void remove_mail_rule (int64 id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("DELETE FROM mail_rules WHERE id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare mail-rule deletion");
        statement.bind_int64 (1, id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not delete the mail rule");
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

    private void execute (string sql) throws MailError {
        string? message = null;
        if (database.exec (sql, null, out message) != Sqlite.OK)
            throw new MailError.STORAGE (message ?? "The mail cache could not be updated");
    }

    public void save_draft (Draft draft) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            save_draft_rows (draft);
            execute ("COMMIT"); draft.mark_saved ();
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
    }

    private void save_draft_rows (Draft draft) throws MailError {
        Sqlite.Statement statement;
        const string sql = "INSERT OR REPLACE INTO drafts(id,account_id,recipients_to,cc,bcc,subject,body_text,in_reply_to,references_header,modified_at,body_html,body_format,security_protocol,sign_message,encrypt_message,security_identity) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare draft save");
        statement.bind_text (1, draft.id); statement.bind_text (2, draft.account_id); statement.bind_text (3, draft.to);
        statement.bind_text (4, draft.cc); statement.bind_text (5, draft.bcc); statement.bind_text (6, draft.subject);
        statement.bind_text (7, draft.body_text); statement.bind_text (8, draft.in_reply_to); statement.bind_text (9, draft.references); statement.bind_int64 (10, draft.modified_at);
        statement.bind_text (11, draft.body_html); statement.bind_text (12, draft.body_format);
        statement.bind_int (13, (int) draft.security_protocol); statement.bind_int (14, draft.sign_message ? 1 : 0);
        statement.bind_int (15, draft.encrypt_message ? 1 : 0); statement.bind_text (16, draft.security_identity);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save the draft");
        if (database.prepare_v2 ("DELETE FROM draft_attachments WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare attachment storage");
        statement.bind_text (1, draft.id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update draft attachments");
        foreach (var attachment in draft.attachments) {
            if (database.prepare_v2 ("INSERT INTO draft_attachments(draft_id,id,path,name,size,content_type,content_id) VALUES(?,?,?,?,?,?,?)", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare attachment storage");
            statement.bind_text (1, draft.id); statement.bind_text (2, attachment.id); statement.bind_text (3, attachment.path);
            statement.bind_text (4, attachment.name); statement.bind_int64 (5, attachment.size); statement.bind_text (6, attachment.content_type);
            statement.bind_text (7, attachment.content_id);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not save a draft attachment");
        }
    }

    public Draft? load_draft (string id) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT account_id,recipients_to,cc,bcc,subject,body_text,in_reply_to,references_header,modified_at,body_html,body_format,security_protocol,sign_message,encrypt_message,security_identity FROM drafts WHERE id=?", -1, out statement) != Sqlite.OK)
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
        if (database.prepare_v2 ("SELECT id,path,name,size,content_type,content_id FROM draft_attachments WHERE draft_id=? ORDER BY rowid", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare draft attachment loading");
        statement.bind_text (1, id);
        while ((result = statement.step ()) == Sqlite.ROW)
            draft.attachments.add (new Attachment (statement.column_text (0), statement.column_text (1), statement.column_text (2), statement.column_int64 (3), statement.column_text (4), statement.column_text (5)));
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

    public void queue_for_sending (Draft draft, int64 not_before = 0) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            save_draft_rows (draft);
            Sqlite.Statement statement;
            if (database.prepare_v2 ("INSERT INTO outbox(id,draft_id,attempts,next_attempt_at,last_error,delivery_state) VALUES(?,?,0,?,'',0) ON CONFLICT(draft_id) DO UPDATE SET next_attempt_at=excluded.next_attempt_at,delivery_state=0", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare the outbox item");
            statement.bind_text (1, draft.id); statement.bind_text (2, draft.id); statement.bind_int64 (3, int64.max (0, not_before));
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not queue the message for sending");
            execute ("COMMIT"); draft.mark_saved ();
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public void record_send_failure (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,next_attempt_at=strftime('%s','now')+MIN(3600,60*(1 << MIN(attempts,6))),last_error=?,delivery_state=0 WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare send failure storage");
        statement.bind_text (1, detail); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the send failure");
    }

    public void record_send_uncertain (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,last_error=?,delivery_state=1 WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare uncertain delivery storage");
        statement.bind_text (1, detail); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve uncertain delivery status");
    }

    public void record_send_rejection (string draft_id, string detail) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET attempts=attempts+1,next_attempt_at=0,last_error=?,delivery_state=? WHERE draft_id=?", -1, out statement) != Sqlite.OK)
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

    public void mark_send_started (string draft_id) throws MailError {
        set_outbox_delivery_state (draft_id, OutboxDeliveryState.SENDING);
    }

    public void mark_send_accepted (string draft_id) throws MailError {
        set_outbox_delivery_state (draft_id, OutboxDeliveryState.ACCEPTED);
    }

    private void set_outbox_delivery_state (string draft_id, OutboxDeliveryState state) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("UPDATE outbox SET delivery_state=? WHERE draft_id=?", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox delivery state");
        statement.bind_int (1, (int) state); statement.bind_text (2, draft_id);
        if (statement.step () != Sqlite.DONE || database.changes () != 1)
            throw new MailError.STORAGE ("Could not preserve Outbox delivery state");
    }

    public void delete_draft (string id) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            delete_bound ("DELETE FROM outbox WHERE draft_id=?", id);
            delete_bound ("DELETE FROM drafts WHERE id=?", id);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    public int draft_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM drafts", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count drafts");
        return statement.column_int (0);
    }

    public int outbox_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COUNT(*) FROM outbox", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count queued messages");
        return statement.column_int (0);
    }

    public Gee.ArrayList<OutboxItem> list_outbox_items () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT draft_id,attempts,next_attempt_at,last_error,delivery_state FROM outbox ORDER BY rowid DESC", -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare Outbox loading");
        var result = new Gee.ArrayList<OutboxItem> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            var draft = load_draft (statement.column_text (0));
            if (draft != null) result.add (new OutboxItem (draft, statement.column_int (1),
                statement.column_int64 (2), statement.column_text (3),
                (OutboxDeliveryState) statement.column_int (4)));
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load Outbox messages");
        return result;
    }

    public OutboxItem? find_outbox_item (string draft_id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT attempts,next_attempt_at,last_error,delivery_state FROM outbox WHERE draft_id=?";
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
        var draft = load_draft (draft_id);
        if (draft == null) return null;
        return new OutboxItem (draft, attempts, next_attempt_at, last_error, delivery_state);
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
        Sqlite.Statement statement;
        string sql = "SELECT d.id FROM outbox o JOIN drafts d ON d.id=o.draft_id WHERE d.account_id=? AND o.delivery_state=0" +
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

    public void cache_message (Message message) throws MailError {
        execute ("BEGIN IMMEDIATE");
        try {
            cache_message_row (message);
            execute ("COMMIT");
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
    }

    private void cache_message_row (Message message) throws MailError {
        reconcile_moved_message_identity (message);
        Sqlite.Statement statement;
        const string sql = "INSERT INTO cached_messages(id,mailbox_id,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,body_html,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color,content_extracted) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET mailbox_id=excluded.mailbox_id,sender_name=excluded.sender_name,sender_address=excluded.sender_address,recipients=excluded.recipients,subject=excluded.subject,preview=excluded.preview,body=excluded.body,timestamp=excluded.timestamp,unread=excluded.unread,flagged=excluded.flagged,has_attachment=excluded.has_attachment,conversation_count=excluded.conversation_count,has_remote_content=excluded.has_remote_content,body_html=excluded.body_html,account_id=excluded.account_id,remote_uid=excluded.remote_uid,internet_message_id=excluded.internet_message_id,in_reply_to=excluded.in_reply_to,references_header=excluded.references_header,date_unix=excluded.date_unix,cc_recipients=excluded.cc_recipients,security_status=excluded.security_status,content_extracted=1";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare message caching");
        statement.bind_text (1, message.id); statement.bind_text (2, message.mailbox_id); statement.bind_text (3, message.sender_name); statement.bind_text (4, message.sender_address);
        statement.bind_text (5, message.recipients); statement.bind_text (6, message.subject); statement.bind_text (7, message.preview); statement.bind_text (8, message.body); statement.bind_text (9, message.timestamp);
        statement.bind_int (10, message.unread ? 1 : 0); statement.bind_int (11, message.flagged ? 1 : 0); statement.bind_int (12, message.has_attachment ? 1 : 0);
        statement.bind_int (13, (int) message.conversation_count); statement.bind_int (14, message.has_remote_content ? 1 : 0); statement.bind_text (15, message.body_html);
        statement.bind_text (16, message.account_id); statement.bind_text (17, message.remote_uid);
        statement.bind_text (18, message.internet_message_id);
        statement.bind_text (19, message.in_reply_to); statement.bind_text (20, message.references);
        statement.bind_int64 (21, message.date_unix);
        statement.bind_text (22, message.cc_recipients);
        statement.bind_text (23, message.security_status);
        statement.bind_text (24, message.flag_color);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not cache the message");
        if (database.prepare_v2 ("DELETE FROM message_fts WHERE id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not update the search index");
        statement.bind_text (1, message.id); if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the search index");
        if (database.prepare_v2 ("INSERT INTO message_fts(id,sender,recipients,subject,body) VALUES(?,?,?,?,?)", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare the search index");
        statement.bind_text (1, message.id); statement.bind_text (2, message.sender_name + " " + message.sender_address); statement.bind_text (3, message.recipients + " " + message.cc_recipients); statement.bind_text (4, message.subject); statement.bind_text (5, message.body + " " + message.body_html);
        if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not index the message");
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
            if (snapshot.folder_inventory_complete) prune_missing_mailboxes (snapshot);
            foreach (var mailbox in snapshot.mailboxes) cache_mailbox_row (mailbox);
            foreach (var mailbox in snapshot.mailboxes) {
                var remote_uids = snapshot.remote_uids_for (mailbox.id);
                if (remote_uids != null) prune_missing_messages (mailbox.id, remote_uids);
            }
            foreach (var message in snapshot.messages) cache_message_row (message);
            foreach (var state in snapshot.states) update_remote_message_state (state);
            reapply_pending_state (snapshot.account_id);
            execute ("COMMIT");
        } catch (MailError error) { try { execute ("ROLLBACK"); } catch (MailError ignored) { } throw error; }
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
        const string sql = "SELECT id,name,icon_name,role,unread_count,account_id,remote_name FROM cached_mailboxes ORDER BY account_id,CASE role WHEN 0 THEN 0 WHEN 4 THEN 1 WHEN 3 THEN 2 WHEN 5 THEN 3 WHEN 6 THEN 4 WHEN 7 THEN 5 ELSE 6 END,name COLLATE NOCASE";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare cached mailbox loading");
        int row; while ((row = statement.step ()) == Sqlite.ROW)
            result.add (new Mailbox (statement.column_text (0), statement.column_text (1), statement.column_text (2), (MailboxRole) statement.column_int (3),
                (uint) statement.column_int (4), statement.column_text (5), statement.column_text (6)));
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load cached mailboxes");
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
        const string columns = "m.id,m.mailbox_id,m.sender_name,m.sender_address,m.recipients,m.subject,m.preview,m.timestamp,m.unread,m.flagged,m.has_attachment,m.conversation_count,m.has_remote_content,m.account_id,m.remote_uid,m.internet_message_id,m.in_reply_to,m.references_header,m.date_unix,m.cc_recipients,m.flag_color";
        bool bind_mailbox = false;
        string predicate = cached_mailbox_predicate (mailbox_id, out bind_mailbox);
        if (unread_only) predicate += " AND m.unread=1";
        string grouping = mailbox_id == "unified-vip" ?
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
        string sql = mailbox_id == "unified-vip" ?
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
        switch (mailbox_id) {
        case "unified-inbox": predicate = "b.role=0"; break;
        case "unified-vip": predicate = "EXISTS(SELECT 1 FROM vip_senders v WHERE v.address=m.sender_address COLLATE NOCASE)"; break;
        case "unified-flagged": predicate = "m.flagged=1"; break;
        case "unified-sent": predicate = "b.role=4"; break;
        case "unified-archive": predicate = "b.role=7"; break;
        case "unified-junk": predicate = "b.role=5"; break;
        case "unified-trash": predicate = "b.role=6"; break;
        case "unified-snoozed": predicate = "EXISTS(SELECT 1 FROM snoozed_messages s WHERE s.message_id=m.id AND s.until_unix>strftime('%s','now'))"; break;
        default: predicate = "m.mailbox_id=?"; bind_mailbox = true; break;
        }
        if (mailbox_id != "unified-snoozed")
            predicate += " AND NOT EXISTS(SELECT 1 FROM snoozed_messages s WHERE s.message_id=m.id AND s.until_unix>strftime('%s','now'))";
        return predicate;
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

    public uint smart_unread_count (string mailbox_id) throws MailError {
        Sqlite.Statement statement; string predicate;
        switch (mailbox_id) {
        case "unified-vip": predicate = "EXISTS(SELECT 1 FROM vip_senders v WHERE v.address=m.sender_address COLLATE NOCASE)"; break;
        case "unified-flagged": predicate = "m.flagged=1"; break;
        default: predicate = "0"; break;
        }
        string sql = mailbox_id == "unified-vip" ?
            "SELECT COUNT(*) FROM (SELECT 1 FROM cached_messages m WHERE m.unread=1 AND %s GROUP BY m.account_id,COALESCE(NULLIF(m.internet_message_id,''),m.id))".printf (predicate) :
            "SELECT COUNT(*) FROM cached_messages m WHERE m.unread=1 AND %s".printf (predicate);
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare smart mailbox counting");
        if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("Could not count smart mailbox messages");
        return (uint) statement.column_int64 (0);
    }

    public Message? find_cached_message (string id) throws MailError {
        Sqlite.Statement statement;
        const string sql = "SELECT id,mailbox_id,sender_name,sender_address,recipients,subject,preview,body,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,body_html,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,security_status,flag_color FROM cached_messages WHERE id=?";
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
        Sqlite.Statement statement;
        const string sql = "SELECT id,mailbox_id,sender_name,sender_address,recipients,subject,preview,timestamp,unread,flagged,has_attachment,conversation_count,has_remote_content,account_id,remote_uid,internet_message_id,in_reply_to,references_header,date_unix,cc_recipients,flag_color FROM cached_messages WHERE account_id=? ORDER BY rowid";
        if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not prepare conversation loading");
        statement.bind_text (1, selected.account_id); var candidates = new Gee.ArrayList<Message> (); int row;
        while ((row = statement.step ()) == Sqlite.ROW) {
            candidates.add (message_summary_from_row (statement));
        }
        if (row != Sqlite.DONE) throw new MailError.STORAGE ("Could not load conversation messages");
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
        return new Message (statement.column_text (0), statement.column_text (1),
            statement.column_text (2), statement.column_text (3), statement.column_text (4),
            statement.column_text (5), statement.column_text (6), "", statement.column_text (7),
            statement.column_int (8) != 0, statement.column_int (9) != 0,
            statement.column_int (10) != 0, (uint) statement.column_int (11),
            statement.column_int (12) != 0, statement.column_text (13),
            statement.column_text (14), statement.column_text (15), statement.column_text (16),
            statement.column_text (17), statement.column_int64 (18), statement.column_text (19),
            statement.column_text (20));
    }

    private static Message message_from_row (Sqlite.Statement statement) {
        var message = new Message (statement.column_text (0), statement.column_text (1), statement.column_text (2), statement.column_text (3), statement.column_text (4),
            statement.column_text (5), statement.column_text (6), statement.column_text (7), statement.column_text (8), statement.column_int (9) != 0,
            statement.column_int (10) != 0, statement.column_int (11) != 0, (uint) statement.column_int (12), statement.column_int (13) != 0,
            statement.column_text (15), statement.column_text (16), statement.column_text (17), statement.column_text (18), statement.column_text (19), statement.column_int64 (20), statement.column_text (21), statement.column_text (23));
        message.body_html = statement.column_text (14); message.security_status = statement.column_text (22); return message;
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

    public uint unified_unread_count () throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 ("SELECT COALESCE(SUM(unread_count),0) FROM cached_mailboxes WHERE role=0", -1, out statement) != Sqlite.OK || statement.step () != Sqlite.ROW)
            throw new MailError.STORAGE ("Could not count unread mail");
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

    public void set_cached_read (string id, bool read) throws MailError {
        string? changed_account = null;
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement lookup;
            if (database.prepare_v2 ("SELECT unread,mailbox_id FROM cached_messages WHERE id=?", -1, out lookup) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare cached read-state update");
            lookup.bind_text (1, id);
            int row = lookup.step ();
            if (row != Sqlite.ROW && row != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not inspect cached read state");
            if (row == Sqlite.ROW) {
                int previous = lookup.column_int (0);
                string mailbox_id = lookup.column_text (1);
                int unread = read ? 0 : 1;
                if (previous != unread) {
                    update_cached_flag (id, "unread", unread);
                    Sqlite.Statement count;
                    if (database.prepare_v2 ("UPDATE cached_mailboxes SET unread_count=MAX(0,unread_count+?) WHERE id=?", -1, out count) != Sqlite.OK)
                        throw new MailError.STORAGE ("Could not prepare mailbox unread-count update");
                    count.bind_int (1, unread - previous); count.bind_text (2, mailbox_id);
                    if (count.step () != Sqlite.DONE)
                        throw new MailError.STORAGE ("Could not update the mailbox unread count");
                    changed_account = queue_message_state_rows (id, MessageStateField.READ, read);
                }
            }
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        if (changed_account != null) mutation_queued (changed_account);
    }
    public void set_cached_flagged (string id, bool flagged) throws MailError {
        string? changed_account = null;
        execute ("BEGIN IMMEDIATE");
        try {
            update_cached_flag (id, "flagged", flagged ? 1 : 0);
            changed_account = queue_message_state_rows (id, MessageStateField.FLAGGED, flagged);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        if (changed_account != null) mutation_queued (changed_account);
    }

    public void set_cached_flag_color (string id, string color) throws MailError {
        string? changed_account = null;
        execute ("BEGIN IMMEDIATE");
        try {
            Sqlite.Statement statement;
            if (database.prepare_v2 ("UPDATE cached_messages SET flag_color=?,flagged=1 WHERE id=?", -1, out statement) != Sqlite.OK)
                throw new MailError.STORAGE ("Could not prepare flag color update");
            statement.bind_text (1, color); statement.bind_text (2, id);
            if (statement.step () != Sqlite.DONE)
                throw new MailError.STORAGE ("Could not update flag color");
            changed_account = queue_message_state_rows (id, MessageStateField.FLAGGED, true);
            execute ("COMMIT");
        } catch (MailError error) {
            try { execute ("ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
        if (changed_account != null) mutation_queued (changed_account);
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
            const string lookup = "SELECT m.account_id,source.remote_name,m.remote_uid,destination.remote_name FROM cached_messages m JOIN cached_mailboxes source ON source.id=m.mailbox_id JOIN cached_mailboxes destination ON destination.id=? AND destination.account_id=m.account_id WHERE m.id=? LIMIT 1";
            if (database.prepare_v2 (lookup, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare a message transfer");
            statement.bind_text (1, destination_id); statement.bind_text (2, message_id);
            if (statement.step () != Sqlite.ROW) throw new MailError.STORAGE ("The destination mailbox is unavailable for this account");
            account_id = statement.column_text (0); string source_name = statement.column_text (1); string remote_uid = statement.column_text (2);
            string destination_name = statement.column_text (3);
            const string insert = "INSERT INTO pending_transfers(message_id,account_id,source_mailbox,destination_mailbox,remote_uid,copy,created_at) VALUES(?,?,?,?,?,?,strftime('%s','now')) ON CONFLICT(message_id) DO UPDATE SET destination_mailbox=excluded.destination_mailbox,copy=excluded.copy,created_at=excluded.created_at";
            if (database.prepare_v2 (insert, -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not preserve the message move");
            statement.bind_text (1, message_id); statement.bind_text (2, account_id); statement.bind_text (3, source_name); statement.bind_text (4, destination_name);
            statement.bind_text (5, remote_uid); statement.bind_int (6, copy ? 1 : 0);
            if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not preserve the message move");
            if (!copy) {
                if (database.prepare_v2 ("UPDATE cached_messages SET mailbox_id=? WHERE id=?", -1, out statement) != Sqlite.OK) throw new MailError.STORAGE ("Could not prepare the local message move");
                statement.bind_text (1, destination_id); statement.bind_text (2, message_id);
                if (statement.step () != Sqlite.DONE) throw new MailError.STORAGE ("Could not update the local message move");
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
        var sql = new StringBuilder ("SELECT m.id,m.mailbox_id,m.sender_name,m.sender_address,m.recipients,m.subject,m.preview,m.timestamp,m.unread,m.flagged,m.has_attachment,m.conversation_count,m.has_remote_content,m.account_id,m.remote_uid,m.internet_message_id,m.in_reply_to,m.references_header,m.date_unix,m.cc_recipients,m.flag_color FROM cached_messages m JOIN message_fts f ON f.id=m.id LEFT JOIN cached_mailboxes b ON b.id=m.mailbox_id WHERE 1=1");
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
        if (query.text != "") { sql.append (" AND message_fts MATCH ?"); values.add (quote_fts (query.text)); }
        if (query.sender != null) { sql.append (" AND lower(m.sender_name || ' ' || m.sender_address) LIKE ?"); values.add ("%" + query.sender.down () + "%"); }
        if (query.recipient != null) { sql.append (" AND lower(m.recipients || ' ' || m.cc_recipients) LIKE ?"); values.add ("%" + query.recipient.down () + "%"); }
        if (query.mailbox != null) { sql.append (" AND (lower(m.mailbox_id)=? OR lower(b.name)=? OR lower(b.remote_name)=?)"); values.add (query.mailbox.down ()); values.add (query.mailbox.down ()); values.add (query.mailbox.down ()); }
        if (query.label != null) { sql.append (" AND EXISTS(SELECT 1 FROM message_labels ml JOIN mail_labels l ON l.id=ml.label_id WHERE ml.message_id=m.id AND lower(l.name)=?)"); values.add (query.label.down ()); }
        if (query.unread != null) sql.append (query.unread ? " AND m.unread=1" : " AND m.unread=0");
        if (query.flagged != null) sql.append (query.flagged ? " AND m.flagged=1" : " AND m.flagged=0");
        if (query.has_attachment != null) sql.append (query.has_attachment ? " AND m.has_attachment=1" : " AND m.has_attachment=0");
        if (query.after_unix != null) { sql.append (" AND m.date_unix>=CAST(? AS INTEGER)"); values.add (((int64) query.after_unix).to_string ()); }
        if (query.before_unix != null) { sql.append (" AND m.date_unix<CAST(? AS INTEGER)"); values.add (((int64) query.before_unix).to_string ()); }
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
}
}
