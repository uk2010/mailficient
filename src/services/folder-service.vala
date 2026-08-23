namespace Mailficient {
public class FolderService : Object {
    private CacheDatabase cache;
    private MailEngine? engine;
    private AccountSyncService? sync_service;

    public FolderService (CacheDatabase cache, MailEngine? engine, AccountSyncService? sync_service) {
        this.cache = cache; this.engine = engine; this.sync_service = sync_service;
    }

    public async void create (string account_id, string parent_name, string name,
                              Cancellable? cancellable = null) throws Error {
        validate_name (name);
        var account = require_account (account_id); var backend = require_engine ();
        yield backend.connect_incoming_account (account, cancellable);
        yield backend.create_folder (account_id, parent_name, name.strip (), cancellable);
        if (sync_service != null) yield sync_service.sync_account (account, cancellable);
    }

    public async void rename (Mailbox mailbox, string name, Cancellable? cancellable = null) throws Error {
        if (mailbox.role != MailboxRole.CUSTOM) throw new MailError.INVALID_ACCOUNT ("System mailboxes cannot be renamed");
        validate_name (name);
        var account = require_account (mailbox.account_id); var backend = require_engine ();
        yield backend.connect_incoming_account (account, cancellable);
        yield backend.rename_folder (mailbox.account_id, mailbox.remote_name, mailbox.name, name.strip (), cancellable);
        if (sync_service != null) yield sync_service.sync_account (account, cancellable);
    }

    public async void delete (Mailbox mailbox, Cancellable? cancellable = null) throws Error {
        if (mailbox.role != MailboxRole.CUSTOM) throw new MailError.INVALID_ACCOUNT ("System mailboxes cannot be deleted");
        var account = require_account (mailbox.account_id); var backend = require_engine ();
        yield backend.connect_incoming_account (account, cancellable);
        yield backend.delete_folder (mailbox.account_id, mailbox.remote_name, cancellable);
        if (sync_service != null) yield sync_service.sync_account (account, cancellable);
    }

    public static void validate_name (string name) throws MailError {
        string value = name.strip ();
        if (value == "") throw new MailError.INVALID_ACCOUNT ("Enter a folder name");
        if (value.length > 120) throw new MailError.INVALID_ACCOUNT ("Folder names must be 120 characters or fewer");
        for (int index = 0; index < value.length; index++)
            if (value[index] < 32 || value[index] == 127)
                throw new MailError.INVALID_ACCOUNT ("Folder names cannot contain control characters");
    }

    private AccountSettings require_account (string account_id) throws Error {
        var account = cache.find_account (account_id);
        if (account == null) throw new MailError.CONNECTION ("The folder account is no longer configured");
        return account;
    }

    private MailEngine require_engine () throws Error {
        if (engine == null) throw new MailError.CONNECTION ("Live folder management is unavailable in this build");
        return engine;
    }
}
}
