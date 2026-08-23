namespace Mailficient {
public interface AccountStore : Object {
    public abstract void save_account (AccountSettings account) throws MailError;
}
}
