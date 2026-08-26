namespace Mailficient {
public interface RemoteMailSearchProvider : Object {
    public abstract async Gee.List<Message> search_remote (
        Mailbox mailbox, string expression, int limit,
        Cancellable? cancellable = null) throws Error;
}
}
