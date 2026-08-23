namespace Mailficient {
public class MailSyncResult : Object {
    public string account_id { get; construct; }
    public Gee.ArrayList<Mailbox> mailboxes { get; private set; default = new Gee.ArrayList<Mailbox> (); }
    public Gee.ArrayList<Message> messages { get; private set; default = new Gee.ArrayList<Message> (); }
    public Gee.ArrayList<RemoteMessageState> states { get; private set; default = new Gee.ArrayList<RemoteMessageState> (); }
    public Gee.ArrayList<string> issues { get; private set; default = new Gee.ArrayList<string> (); }
    public bool folder_inventory_complete { get; set; default = false; }
    public bool more_messages_available { get; set; default = false; }
    public int messages_to_download { get; set; default = 0; }
    public Error? terminal_error;
    private Gee.HashMap<string, Gee.HashSet<string>> remote_uids = new Gee.HashMap<string, Gee.HashSet<string>> ();

    public MailSyncResult (string account_id) {
        Object (account_id: account_id);
    }

    public void record_remote_uid (string mailbox_id, string uid) {
        var inventory = remote_uids[mailbox_id];
        if (inventory == null) {
            inventory = new Gee.HashSet<string> ();
            remote_uids[mailbox_id] = inventory;
        }
        inventory.add (uid);
    }

    public Gee.Set<string>? remote_uids_for (string mailbox_id) {
        return remote_uids[mailbox_id];
    }

    public void record_issue (string scope, Error error) {
        if (issues.size >= 20) return;
        string clean_scope = scope.strip () == "" ? "Mail account" : scope.strip ();
        issues.add ("%s: %s".printf (clean_scope, error.message));
    }

    public string issue_summary () {
        var summary = new StringBuilder ();
        foreach (var issue in issues) {
            if (summary.len > 0) summary.append_c ('\n');
            summary.append (issue);
        }
        if (issues.size >= 20) summary.append ("\nAdditional synchronization errors were omitted.");
        return summary.str;
    }
}
}
