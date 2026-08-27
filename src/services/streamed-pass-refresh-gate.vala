namespace Mailficient {
// Tracks whether a streamed backend pass has already published its early UI
// refresh. A pass may contain dozens of small durable batches; callers wake on
// the first batch and again at the pass boundary, then start cleanly for the
// next bounded history session.
internal class StreamedPassRefreshGate : Object {
    private Gee.HashSet<string> active_accounts = new Gee.HashSet<string> ();

    // Returns true only for the first message batch in the current pass.
    public bool begin_batch (string account_id) {
        return active_accounts.add (account_id);
    }

    // Returns true when the pass contained at least one message batch. This
    // both requests its final checkpoint and clears the account for a later
    // pass, logical completion, failure, or cancellation.
    public bool finish_pass (string account_id) {
        return active_accounts.remove (account_id);
    }

    internal bool is_active (string account_id) {
        return active_accounts.contains (account_id);
    }
}
}
