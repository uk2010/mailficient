namespace Mailficient {
public class RemoteContentPolicy : Object {
    public signal void changed ();
    private CacheDatabase cache;

    public RemoteContentPolicy (CacheDatabase cache) {
        this.cache = cache;
    }

    public bool is_sender_trusted (string address) {
        try {
            // "Safe Sender" is the stronger, user-facing trust decision. It
            // therefore includes the narrower permission to load that
            // sender's remote images. Keep the dedicated remote-content list
            // for people who only want to allow images while retaining the
            // automatic sender-warning card.
            return cache.is_safe_sender (address) ||
                cache.is_remote_sender_trusted (address);
        }
        catch (Error error) {
            warning ("Could not inspect the remote-content sender policy: %s", error.message);
            return false;
        }
    }

    public void trust_sender (string address) throws MailError {
        cache.set_remote_sender_trusted (address, true);
        changed ();
    }

    public void forget_sender (string address) throws MailError {
        cache.set_remote_sender_trusted (address, false);
        changed ();
    }

    public Gee.List<string> trusted_senders () throws MailError {
        return cache.list_trusted_remote_senders ();
    }
}
}
