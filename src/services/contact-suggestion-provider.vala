namespace Mailficient {
public interface ContactSuggestionProvider : Object {
    public abstract async Gee.List<Recipient> suggest (string query, uint limit,
        Cancellable? cancellable = null) throws Error;
}
}
