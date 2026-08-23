namespace Mailficient {
public interface CredentialStore : Object {
    public abstract async void store_password (string account_id, string protocol, string password, Cancellable? cancellable = null) throws Error;
    public abstract async string? lookup_password (string account_id, string protocol, Cancellable? cancellable = null) throws Error;
    public abstract async void clear_account (string account_id, Cancellable? cancellable = null) throws Error;
}
}
