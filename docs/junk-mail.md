# Junk mail

Use the warning icon in the message toolbar to mark a message as junk. Mailficient sets the server's Junk and NotJunk flags and moves the message to the account's Junk folder. In Junk, the same control marks the message as not junk and returns it to that account's Inbox.

These changes are written to the local operation queue before the interface updates. If the account is offline, Mailficient retries the flags and folder move during the next successful synchronization.

Preferences → Junk supports exact email-address and entire-domain rules. Rules are case-insensitive and apply to newly synchronized Inbox messages. They remain local to Mailficient, while each resulting classification is also sent to the provider so server-side spam learning can use it where supported.

Removing a rule stops future matches. It does not automatically restore messages already moved to Junk. Mailficient does not run a separate probabilistic content classifier; the configured provider remains responsible for its own spam scoring.
