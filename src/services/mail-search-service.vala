namespace Mailficient {
public class MailSearchService : Object {
    private CacheDatabase cache;

    public MailSearchService (CacheDatabase cache) {
        this.cache = cache;
    }

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
}
}
