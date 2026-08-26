namespace Mailficient {
// Camel IMAPX owns the protocol-level IDLE command and its connection manager.
// Keeping Inbox open and observing its change signal is the public Camel API
// needed to receive those push updates without reaching into IMAPX internals.
internal class CamelLiveMailWatch : Object {
    public signal void mail_changed ();
    public signal void unavailable ();

    public string account_id { get; construct; }

    private Camel.Store? store;
    private Camel.Folder? inbox;
    private string inbox_full_name;
    private ulong folder_changed_handler;
    private ulong folder_deleted_handler;
    private ulong folder_opened_handler;
    private ulong connection_status_handler;
    private bool detached;
    private bool reported_unavailable;

    private CamelLiveMailWatch (string account_id, Camel.Store store, Camel.Folder inbox) {
        Object (account_id: account_id);
        this.store = store;
        this.inbox = inbox;
        this.inbox_full_name = inbox.get_full_name ();
        attach ();
    }

    public static async CamelLiveMailWatch create (string account_id, Camel.Store store,
                                                    Cancellable? cancellable = null) throws Error {
        bool idle_enabled = enable_idle (store);
        var provider_inbox = yield store.get_inbox_folder (Priority.DEFAULT, cancellable);
        if (provider_inbox == null)
            throw new MailError.CONNECTION ("The incoming-mail Inbox is not currently available");
        // The special-folder vfunc can return an object outside CamelStore's
        // canonical folder bag. Resolve its provider-derived full name through
        // the public get_folder API before attaching; folder_opened rebinding
        // below remains a fallback for later cache/object replacement.
        var inbox = yield store.get_folder (provider_inbox.get_full_name (),
            Camel.StoreGetFolderFlags.NONE, Priority.DEFAULT, cancellable);
        if (inbox == null)
            throw new MailError.CONNECTION ("The incoming-mail Inbox could not be opened");
        // Opening a cached IMAPX folder alone need not select it remotely.
        // Refresh once so the provider has a selected Inbox on which it can
        // schedule IDLE after its normal two-second command-coalescing delay.
        yield inbox.refresh_info (Priority.DEFAULT, cancellable);
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        debug ("Live Inbox watch ready for %s: folder=%p use-idle=%s connection-status=%d",
            account_id, (void*) inbox, idle_enabled.to_string (),
            (int) store.get_connection_status ());
        return new CamelLiveMailWatch (account_id, store, inbox);
    }

    public void detach () {
        if (detached) return;
        detached = true;
        if (inbox != null) {
            if (folder_changed_handler != 0) inbox.disconnect (folder_changed_handler);
            if (folder_deleted_handler != 0) inbox.disconnect (folder_deleted_handler);
        }
        if (store != null && connection_status_handler != 0)
            SignalHandler.disconnect (store, connection_status_handler);
        if (store != null && folder_opened_handler != 0)
            SignalHandler.disconnect (store, folder_opened_handler);
        folder_changed_handler = 0;
        folder_deleted_handler = 0;
        folder_opened_handler = 0;
        connection_status_handler = 0;
        inbox = null;
        store = null;
    }

    ~CamelLiveMailWatch () {
        detach ();
    }

    internal static bool enable_idle (Camel.Store store) {
        var settings = store.ref_settings ();
        if (settings.get_class ().find_property ("use-idle") == null) return false;
        Value enabled = Value (typeof (bool));
        enabled.set_boolean (true);
        settings.set_property ("use-idle", enabled);
        return true;
    }

    internal static bool change_requires_sync (Camel.FolderChangeInfo changes) {
        // Some IMAPX/server combinations surface a new EXISTS as an updated
        // summary UID rather than added/recent. External flag changes and
        // removals also require a bounded cache reconciliation; the sync
        // service's known-ID check still decides whether to notify the user.
        return changes.changed ();
    }

    private void attach () {
        if (inbox == null || store == null) return;
        weak CamelLiveMailWatch weak_watch = this;
        attach_inbox_signals ();
        folder_opened_handler = store.folder_opened.connect ((folder) => {
            if (weak_watch != null) weak_watch.observe_opened_folder (folder);
        });
        connection_status_handler = store.notify["connection-status"].connect ((property) => {
            if (weak_watch == null || weak_watch.store == null) return;
            var status = weak_watch.store.get_connection_status ();
            debug ("Incoming connection status for %s changed to %d",
                weak_watch.account_id, (int) status);
            if (status == Camel.ServiceConnectionStatus.CONNECTED)
                weak_watch.reported_unavailable = false;
            else if (status == Camel.ServiceConnectionStatus.DISCONNECTED)
                weak_watch.report_unavailable ();
        });
    }

    private void attach_inbox_signals () {
        if (inbox == null) return;
        weak CamelLiveMailWatch weak_watch = this;
        folder_changed_handler = inbox.changed.connect ((changes) => {
            var watch = weak_watch;
            if (watch == null || watch.detached) return;
            debug ("Inbox activity for %s on %p: added=%u changed=%u recent=%u removed=%u",
                watch.account_id, (void*) watch.inbox,
                changes.get_added_uids ().length,
                changes.get_changed_uids ().length,
                changes.get_recent_uids ().length,
                changes.get_removed_uids ().length);
            if (change_requires_sync (changes)) watch.mail_changed ();
        });
        folder_deleted_handler = inbox.deleted.connect (() => {
            var watch = weak_watch;
            if (watch != null) watch.report_unavailable ();
        });
    }

    private void observe_opened_folder (Camel.Folder folder) {
        if (detached) return;
        string opened_name = folder.get_full_name ();
        bool is_inbox = opened_name.ascii_casecmp (inbox_full_name) == 0;
        if (!is_inbox) return;
        debug ("Store opened folder for %s: name=%s folder=%p watched=%p inbox=%s",
            account_id, opened_name, (void*) folder, (void*) inbox,
            is_inbox.to_string ());
        if (folder == inbox) return;

        if (inbox != null) {
            if (folder_changed_handler != 0) inbox.disconnect (folder_changed_handler);
            if (folder_deleted_handler != 0) inbox.disconnect (folder_deleted_handler);
        }
        folder_changed_handler = 0;
        folder_deleted_handler = 0;
        inbox = folder;
        attach_inbox_signals ();
        debug ("Rebound live Inbox watch for %s to folder=%p",
            account_id, (void*) inbox);
    }

    private void report_unavailable () {
        if (detached || reported_unavailable) return;
        reported_unavailable = true;
        unavailable ();
    }
}
}
