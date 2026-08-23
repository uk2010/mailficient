namespace Mailficient {
internal class DemoOnlineAccountService : Object, OnlineAccountService {
    public async Gee.List<OnlineMailAccount> list_mail_accounts (Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        var accounts = new Gee.ArrayList<OnlineMailAccount> ();
        accounts.add (new OnlineMailAccount (
            "/org/gnome/OnlineAccounts/Accounts/demo_google", "Google", "Alex Morgan",
            "alex.morgan@gmail.com", "imap.gmail.com", "alex.morgan@gmail.com", true, false,
            "smtp.gmail.com", "alex.morgan@gmail.com", false, true));
        accounts.add (new OnlineMailAccount (
            "/org/gnome/OnlineAccounts/Accounts/demo_microsoft", "Microsoft 365", "Alex Morgan — Work",
            "alex@northstar.example", "outlook.office365.com", "alex@northstar.example", true, false,
            "smtp.office365.com", "alex@northstar.example", false, true));
        return accounts;
    }

    public async OAuthAccessToken request_access_token (string object_path,
                                                        Cancellable? cancellable = null) throws Error {
        throw new MailError.AUTHENTICATION ("Demo Online Accounts do not issue access tokens");
    }
}
}
