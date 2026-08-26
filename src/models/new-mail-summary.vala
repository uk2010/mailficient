namespace Mailficient {
public class NewMailSummary : Object {
    public const int MAX_SAMPLE_MESSAGES = 5;

    public string account_id { get; construct; }
    public string account_label { get; construct; }
    public int total { get; private set; default = 0; }
    public Gee.ArrayList<Message> samples { get; private set;
        default = new Gee.ArrayList<Message> (); }

    private Gee.HashSet<string> message_ids = new Gee.HashSet<string> ();

    public NewMailSummary (string account_id, string account_label = "") {
        Object (account_id: account_id, account_label: account_label);
    }

    public bool add (Message message) {
        if (!message_ids.add (message.id)) return false;
        total++;
        if (samples.size < MAX_SAMPLE_MESSAGES) samples.add (message);
        return true;
    }

    public void merge (NewMailSummary other) {
        if (other.account_id != account_id) return;
        // Every source summary is itself bounded, so this retains at most five
        // Message bodies while still carrying the exact unique arrival count
        // across multi-session history backfill.
        foreach (var message in other.samples) add (message);
        int omitted = int.max (0, other.total - other.samples.size);
        total += omitted;
    }

    public bool has_overflow () {
        return total > samples.size;
    }
}
}
