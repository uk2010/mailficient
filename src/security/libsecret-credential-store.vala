namespace Mailficient {
public class LibsecretCredentialStore : Object, CredentialStore {
    private Secret.Schema schema;

    public LibsecretCredentialStore () {
        var types = new HashTable<string, Secret.SchemaAttributeType> (str_hash, str_equal);
        types.insert ("account", Secret.SchemaAttributeType.STRING);
        types.insert ("protocol", Secret.SchemaAttributeType.STRING);
        schema = new Secret.Schema.newv ("com.local.Mailficient.Credential", Secret.SchemaFlags.NONE, types);
    }

    private HashTable<string, string> attributes (string account_id, string protocol) {
        var values = new HashTable<string, string> (str_hash, str_equal);
        values.insert ("account", account_id); values.insert ("protocol", protocol); return values;
    }

    public async void store_password (string account_id, string protocol, string password, Cancellable? cancellable = null) throws Error {
        if (password == "") throw new MailError.AUTHENTICATION ("An empty password cannot be stored");
        yield Secret.password_storev (schema, attributes (account_id, protocol), Secret.COLLECTION_DEFAULT,
            "Mailficient password for %s".printf (account_id), password, cancellable);
    }

    public async string? lookup_password (string account_id, string protocol, Cancellable? cancellable = null) throws Error {
        return yield Secret.password_lookupv (schema, attributes (account_id, protocol), cancellable);
    }

    public async void clear_account (string account_id, Cancellable? cancellable = null) throws Error {
        var values = new HashTable<string, string> (str_hash, str_equal); values.insert ("account", account_id);
        yield Secret.password_clearv (schema, values, cancellable);
    }
}
}
