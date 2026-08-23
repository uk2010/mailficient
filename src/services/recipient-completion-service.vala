namespace Mailficient {
public class RecipientCompletionService : Object {
    private CacheDatabase cache;
    private ContactSuggestionProvider? address_book;
    private Gee.List<Recipient>? cached_candidates;

    public RecipientCompletionService (CacheDatabase cache,
                                       ContactSuggestionProvider? address_book = null) {
        this.cache = cache; this.address_book = address_book;
    }

    public bool has_address_book { get { return address_book != null; } }

    public Gee.List<Recipient> suggest (string input, int cursor_position, string account_id = "", uint limit = 6) {
        string query = fragment (input, cursor_position).down ();
        var result = new Gee.ArrayList<Recipient> ();
        if (query == "") return result;
        string own_address = "";
        try { var own = cache.find_account (account_id); if (own != null) own_address = own.email.down (); }
        catch (Error error) { warning ("Could not resolve the compose identity for completion: %s", error.message); }
        try {
            if (cached_candidates == null) cached_candidates = cache.recipient_candidates ();
            foreach (var candidate in cached_candidates) {
                if (candidate.address == own_address) continue;
                string searchable = (candidate.name + " " + candidate.address).down ();
                if (searchable.contains (query)) result.add (candidate);
            }
        } catch (Error error) { warning ("Could not load recipient suggestions: %s", error.message); }
        result.sort ((left, right) => {
            int left_score = score (left, query); int right_score = score (right, query);
            if (left_score != right_score) return left_score - right_score;
            return left.formatted ().collate (right.formatted ());
        });
        while (result.size > limit) result.remove_at (result.size - 1);
        return result;
    }

    public async Gee.List<Recipient> suggest_with_contacts (string input, int cursor_position,
        string account_id = "", uint limit = 6, Cancellable? cancellable = null) throws Error {
        var result = new Gee.ArrayList<Recipient> ();
        var seen = new Gee.HashSet<string> ();
        foreach (var candidate in suggest (input, cursor_position, account_id, limit)) {
            result.add (candidate); seen.add (candidate.address.down ());
        }
        if (address_book == null || result.size >= limit) return result;
        string query = fragment (input, cursor_position).down ();
        if (query.length < 2) return result;
        string own_address = "";
        try { var own = cache.find_account (account_id); if (own != null) own_address = own.email.down (); }
        catch (Error error) { warning ("Could not resolve the compose identity for contact completion: %s", error.message); }
        foreach (var candidate in yield address_book.suggest (query, limit, cancellable)) {
            string address = candidate.address.down ();
            if (address == own_address || seen.contains (address)) continue;
            result.add (candidate); seen.add (address);
        }
        result.sort ((left, right) => {
            int left_score = score (left, query); int right_score = score (right, query);
            if (left_score != right_score) return left_score - right_score;
            return left.formatted ().collate (right.formatted ());
        });
        while (result.size > limit) result.remove_at (result.size - 1);
        return result;
    }

    public void invalidate () { cached_candidates = null; }

    public static string fragment (string input, int cursor_position) {
        int end = int.min (int.max (cursor_position, 0), input.length); int start = end;
        bool quoted = false;
        while (start > 0) {
            char character = input[start - 1];
            if (character == '\"') quoted = !quoted;
            if (character == ',' && !quoted) break;
            start--;
        }
        return input.substring (start, end - start).strip ();
    }

    public static string complete (string input, int cursor_position, Recipient recipient,
                                   out int new_cursor_position) {
        int end = int.min (int.max (cursor_position, 0), input.length); int start = end;
        bool quoted = false;
        while (start > 0) {
            char character = input[start - 1];
            if (character == '\"') quoted = !quoted;
            if (character == ',' && !quoted) break;
            start--;
        }
        while (start < end && (input[start] == ' ' || input[start] == '\t')) start++;
        string insertion = recipient.formatted () + ", ";
        string updated = input.substring (0, start) + insertion + input.substring (end);
        new_cursor_position = start + insertion.length; return updated;
    }

    private static int score (Recipient recipient, string query) {
        if (recipient.address.down ().has_prefix (query)) return 0;
        if (recipient.name.down ().has_prefix (query)) return 1;
        if (recipient.address.down ().contains (query)) return 2;
        return 3;
    }
}
}
