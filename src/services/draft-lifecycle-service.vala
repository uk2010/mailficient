namespace Mailficient {
public class DraftLifecycleService : Object {
    private CacheDatabase cache;
    private AttachmentService attachments;

    public DraftLifecycleService (CacheDatabase cache, AttachmentService attachments) {
        this.cache = cache;
        this.attachments = attachments;
    }

    public void discard (Draft draft) throws MailError {
        // The durable record is authoritative. Never remove files first: a
        // failed SQLite transaction must leave a completely reopenable draft.
        cache.delete_draft (draft.id);
        foreach (var attachment in draft.attachments) {
            try { attachments.remove_private_copy (attachment); }
            catch (Error error) {
                // The draft is already discarded. A private orphan is safer
                // than claiming the draft still exists; startup maintenance
                // retries cleanup without touching paths outside our store.
                warning ("Discarded draft attachment cleanup remains pending: %s", error.message);
            }
        }
    }
}
}
