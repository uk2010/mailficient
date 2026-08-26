namespace Mailficient {
public enum MailSearchScope { CURRENT_FOLDER, CURRENT_ACCOUNT, ALL_MAIL }

public class MailSearchService : Object {
    private CacheDatabase cache;
    private RemoteMailSearchProvider? remote_provider;
    private MailEngine? engine;

    public MailSearchService (CacheDatabase cache,
                              RemoteMailSearchProvider? remote_provider = null,
                              MailEngine? engine = null) {
        this.cache = cache; this.remote_provider = remote_provider; this.engine = engine;
    }

    public bool server_search_available { get { return remote_provider != null && engine != null; } }

    public Gee.List<Message> search (string input, int limit = CacheDatabase.MESSAGE_LIST_LIMIT,
                                     int offset = 0, bool unread_only = false,
                                     MessageSortMode sort_mode = MessageSortMode.NEWEST) throws MailError {
        var query = SearchQuery.parse (input);
        if (unread_only) query.unread = true;
        return cache.search_messages (query, limit, offset, sort_mode);
    }

    public int count (string input, bool unread_only = false) throws MailError {
        var query = SearchQuery.parse (input);
        if (unread_only) query.unread = true;
        return cache.count_search_messages (query);
    }

    public async int fetch_from_server (string input, MailSearchScope scope,
                                        string current_mailbox_id = "",
                                        int maximum_messages = 200,
                                        Cancellable? cancellable = null) throws Error {
        if (remote_provider == null || engine == null)
            throw new MailError.CONNECTION ("Server search is unavailable in this build");
        if (input.strip ().length < 2)
            throw new MailError.INVALID_MESSAGE ("Enter at least two characters before searching the server");
        int remaining = int.max (1, int.min (200, maximum_messages));
        var query = SearchQuery.parse (input); string expression = ServerSearchExpression.build (query);
        var mailboxes = eligible_mailboxes (query, scope, current_mailbox_id);
        if (mailboxes.size == 0)
            throw new MailError.INVALID_MESSAGE ("No synchronized mail folder matches this search scope");
        var connected = new Gee.HashSet<string> (); int installed = 0;
        foreach (var mailbox in mailboxes) {
            if (remaining <= 0) break;
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (connected.add (mailbox.account_id)) {
                var account = cache.find_account (mailbox.account_id);
                if (account == null) continue;
                yield engine.connect_incoming_account (account, cancellable);
            }
            var messages = yield remote_provider.search_remote (mailbox, expression, remaining, cancellable);
            foreach (var message in messages) {
                bool new_to_cache = cache.find_cached_message (message.id) == null;
                cache.cache_message (message);
                if (new_to_cache) installed++;
                remaining--;
                if (remaining <= 0) break;
            }
        }
        return installed;
    }

    private Gee.ArrayList<Mailbox> eligible_mailboxes (SearchQuery query, MailSearchScope scope,
                                                       string current_mailbox_id) throws MailError {
        var result = new Gee.ArrayList<Mailbox> (); var all = cache.list_cached_mailboxes ();
        string active_account = "";
        foreach (var mailbox in all) if (mailbox.id == current_mailbox_id) active_account = mailbox.account_id;
        if (scope == MailSearchScope.CURRENT_ACCOUNT && active_account == "")
            throw new MailError.INVALID_MESSAGE (
                "Choose a folder from the account you want to search");
        foreach (var mailbox in all) {
            if (scope == MailSearchScope.CURRENT_FOLDER && mailbox.id != current_mailbox_id) continue;
            if (scope == MailSearchScope.CURRENT_ACCOUNT && active_account != "" && mailbox.account_id != active_account) continue;
            if (query.account != null && !account_matches (mailbox.account_id, query.account)) continue;
            if (query.mailbox != null && mailbox.id.down () != query.mailbox.down () &&
                mailbox.name.down () != query.mailbox.down () && mailbox.remote_name.down () != query.mailbox.down ()) continue;
            result.add (mailbox);
        }
        return result;
    }

    private bool account_matches (string account_id, string requested) throws MailError {
        if (account_id.down () == requested.down ()) return true;
        var account = cache.find_account (account_id); if (account == null) return false;
        return account.email.down ().contains (requested.down ()) ||
            account.display_name.down ().contains (requested.down ());
    }
}
}
