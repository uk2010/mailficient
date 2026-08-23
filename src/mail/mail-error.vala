namespace Mailficient {
public errordomain MailError {
    INVALID_ACCOUNT,
    INVALID_MESSAGE,
    AUTHENTICATION,
    CONNECTION,
    TLS,
    OFFLINE,
    TIMEOUT,
    RATE_LIMITED,
    PARTIAL_SYNC,
    STORAGE,
    ATTACHMENT,
    SEND_FAILED,
    SEND_REJECTED,
    DELIVERY_UNCERTAIN,
    CANCELLED
}

public class UserFacingError : Object {
    public string title { get; construct; }
    public string description { get; construct; }
    public string suggestion { get; construct; }
    public string technical_detail { get; construct; }

    public UserFacingError (string title, string description, string suggestion, string technical_detail = "") {
        Object (title: title, description: description, suggestion: suggestion,
                technical_detail: technical_detail);
    }

    public static UserFacingError from_error (Error error) {
        if (error is MailError.AUTHENTICATION)
            return new UserFacingError ("Sign-in failed", "The server did not accept the account credentials.", "Check the username and app password, then try again.", error.message);
        if (error is MailError.TLS)
            return new UserFacingError ("Secure connection failed", "Mailficient could not verify the server’s identity.", "Check the server address. Do not bypass certificate warnings.", error.message);
        if (error is MailError.OFFLINE)
            return new UserFacingError ("You’re offline", "Mailficient will continue using cached messages.", "Reconnect to send and receive new mail.", error.message);
        if (error is MailError.TIMEOUT)
            return new UserFacingError ("The server took too long", "The mail server did not respond in time.", "Check the connection and try again.", error.message);
        if (error is MailError.RATE_LIMITED)
            return new UserFacingError ("The mail server is busy",
                "The provider is temporarily limiting how often Mailficient can connect or send.",
                "Wait a few minutes. Queued mail and synchronization will retry automatically.",
                error.message);
        if (error is MailError.PARTIAL_SYNC)
            return new UserFacingError ("Some mail could not be updated",
                "Mailficient saved everything the server returned successfully and kept older cached mail for the parts that failed.",
                "Choose Get Mail to retry. Expand Technical Details to see which folders were affected.",
                error.message);
        if (error is MailError.CONNECTION)
            return new UserFacingError ("Could not reach the mail server", "Mailficient could not establish the requested connection.", "Check the server address and your internet connection.", error.message);
        if (error is MailError.SEND_FAILED)
            return new UserFacingError ("Message was not sent", "The message remains safely queued in Outbox.", "Open Outbox to review it, then retry when the server is available.", error.message);
        if (error is MailError.SEND_REJECTED)
            return new UserFacingError ("Mail server rejected the message",
                "The message remains safely stored in Outbox and will not retry automatically.",
                "Open Outbox, review the server’s reason, correct the message, and try again.",
                error.message);
        if (error is MailError.DELIVERY_UNCERTAIN)
            return new UserFacingError ("Delivery status is uncertain", "The server connection ended before Mailficient could confirm the result.", "Review the message in Outbox before choosing to send it again.", error.message);
        if (error is MailError.INVALID_ACCOUNT)
            return new UserFacingError ("Account settings need attention", error.message, "Correct the highlighted account details and try again.", error.message);
        if (error is MailError.INVALID_MESSAGE)
            return new UserFacingError ("Message needs attention", error.message, "Correct the recipient or add message content, then try again.", error.message);
        if (error is MailError.CANCELLED)
            return new UserFacingError ("Operation cancelled", "No server changes were completed.", "Try again when ready.", error.message);
        if (error is MailError.STORAGE)
            return new UserFacingError ("Local mail data is unavailable", "Mailficient could not read or update its local cache.", "Check available disk space and restart Mailficient.", error.message);
        if (error is MailError.ATTACHMENT)
            return new UserFacingError ("Attachment operation failed",
                "Mailficient could not safely prepare or copy the attachment.",
                "Check the file or destination. In a draft, remove the attachment and add it again.",
                error.message);
        return new UserFacingError ("Mail operation failed", "The requested operation could not be completed.", "Try again in a moment.", error.message);
    }
}
}
