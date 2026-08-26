namespace Mailficient {
public enum LiveSyncReason { ARRIVAL, RECONNECT }

public class LiveMailCoordinator : Object {
    // IMAP IDLE already coalesces its command activity. A short UI-side
    // debounce still folds duplicate folder signals together without making
    // a newly arrived message wait nearly another second before sync starts.
    internal const uint ARRIVAL_DEBOUNCE_MILLISECONDS = 250;
    internal const uint RECONNECT_INITIAL_SECONDS = 5;
    internal const uint RECONNECT_MAX_SECONDS = 300;

    public signal void sync_requested (string account_id, LiveSyncReason reason);

    private Gee.HashMap<string, uint> pending_sources = new Gee.HashMap<string, uint> ();
    // A successful foreground sync makes a pending reconnect unnecessary, but
    // it must not consume an IDLE arrival that was reported after that sync
    // began. Keep the pending source's kind separate from the source id so the
    // completion path can distinguish those cases.
    private Gee.HashSet<string> pending_arrivals = new Gee.HashSet<string> ();
    private Gee.HashMap<string, int> reconnect_attempts = new Gee.HashMap<string, int> ();
    private Gee.HashSet<string> suppressed_accounts = new Gee.HashSet<string> ();

    public void live_mail_changed (string account_id) {
        if (!valid_account (account_id) || suppressed_accounts.contains (account_id)) return;
        clear_pending (account_id);
        reconnect_attempts.unset (account_id);
        pending_arrivals.add (account_id);
        pending_sources[account_id] = Timeout.add (ARRIVAL_DEBOUNCE_MILLISECONDS, () => {
            pending_sources.unset (account_id);
            pending_arrivals.remove (account_id);
            if (!suppressed_accounts.contains (account_id))
                sync_requested (account_id, LiveSyncReason.ARRIVAL);
            return Source.REMOVE;
        });
    }

    public void live_mail_unavailable (string account_id) {
        if (!valid_account (account_id) || suppressed_accounts.contains (account_id) ||
            pending_sources.has_key (account_id)) return;
        int attempt = reconnect_attempts.has_key (account_id) ? reconnect_attempts[account_id] : 0;
        reconnect_attempts[account_id] = attempt + 1;
        pending_sources[account_id] = Timeout.add_seconds (reconnect_delay_for (attempt), () => {
            pending_sources.unset (account_id);
            if (!suppressed_accounts.contains (account_id))
                sync_requested (account_id, LiveSyncReason.RECONNECT);
            return Source.REMOVE;
        });
    }

    public void sync_succeeded (string account_id) {
        if (!pending_arrivals.contains (account_id)) clear_pending (account_id);
        reconnect_attempts.unset (account_id);
    }

    public void sync_failed (string account_id, bool retryable) {
        if (retryable) live_mail_unavailable (account_id);
        else {
            clear_pending (account_id);
            reconnect_attempts.unset (account_id);
        }
    }

    public void suppress_account (string account_id) {
        if (!valid_account (account_id)) return;
        suppressed_accounts.add (account_id);
        clear_pending (account_id);
        reconnect_attempts.unset (account_id);
    }

    public void resume_account (string account_id) {
        suppressed_accounts.remove (account_id);
    }

    public void cancel_all () {
        var account_ids = new Gee.ArrayList<string> ();
        account_ids.add_all (pending_sources.keys);
        foreach (var account_id in account_ids) clear_pending (account_id);
        reconnect_attempts.clear ();
    }

    internal bool has_pending (string account_id) {
        return pending_sources.has_key (account_id);
    }

    internal int reconnect_attempt (string account_id) {
        return reconnect_attempts.has_key (account_id) ? reconnect_attempts[account_id] : 0;
    }

    internal static uint reconnect_delay_for (int attempt) {
        int bounded_attempt = int.max (0, int.min (attempt, 30));
        uint64 delay = RECONNECT_INITIAL_SECONDS;
        for (int index = 0; index < bounded_attempt && delay < RECONNECT_MAX_SECONDS; index++)
            delay = uint64.min (delay * 2, RECONNECT_MAX_SECONDS);
        return (uint) delay;
    }

    private void clear_pending (string account_id) {
        pending_arrivals.remove (account_id);
        uint source = pending_sources.has_key (account_id) ? pending_sources[account_id] : 0;
        pending_sources.unset (account_id);
        if (source != 0) Source.remove (source);
    }

    private static bool valid_account (string account_id) {
        return account_id.strip () != "";
    }
}
}
