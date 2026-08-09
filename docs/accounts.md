# Accounts

Standard IMAP/SMTP accounts require the email address, display name, servers, ports, encryption modes, usernames, and a password or app password. Prefer IMAP over TLS on port 993 and provider-recommended SMTP submission settings.

Open Mailficient’s top-right menu and choose **Accounts**. The account manager lists configured accounts and provides add, edit, and remove controls. **Test and Add Account** validates the form and tests both IMAP and SMTP under an isolated temporary identity before persisting the account. Editing retains the existing password when its password field is blank and does not disconnect the working account unless the replacement settings pass that candidate test. If the final connection or local database write fails, Mailficient restores the previous credentials and reconnects the previous settings. Temporary credential cleanup is journaled and retried if Secret Service is unavailable. Gmail and Outlook server presets are filled after a valid address is entered, but these providers may reject password authentication unless an app password or OAuth is enabled.

Downloaded Apple `.mobileconfig` files can be imported from **Accounts → Import Apple Configuration Profile**. Mailficient accepts plain XML profiles and cryptographically valid signed CMS profiles, reads IMAP/SMTP settings from Apple Mail payloads, and opens the normal account form for review and connection testing. If the profile omits a password, enter it in the review form. Any password included in a profile is handled only as a candidate credential and is stored in Secret Service after the servers validate it.

If a server presents an invalid certificate, setup remains on the account form and shows a secure-connection warning with the host and validation reason. Correct the server address or contact the provider; Mailficient intentionally provides no certificate-warning bypass.

Removing an account asks for confirmation, disconnects its Camel session, clears its Secret Service entries, and transactionally removes its cached mail, pending operations, local drafts, and Outbox entries. It does not delete mail from the provider. Removing the final account returns Mailficient to its no-accounts state with an Add Email Account action; sample mail is never inserted in normal use.

Use the folder button beside an account in the mailbox sidebar to create a server mailbox. Right-click a custom mailbox to create a subfolder, rename it, or delete it. System mailboxes such as Inbox, Sent, and Trash are protected from rename and deletion. Deleting a custom mailbox requires confirmation because the server may also delete the messages it contains.

The folder button in the message toolbar lists every other mailbox in the selected message's account under separate **Move to** and **Copy to** sections. Both operations are written to the local queue first, so a move is reflected immediately and survives a restart or temporary connection failure.

Mailficient supports Gmail and Microsoft OAuth through **GNOME Online Accounts** on GNOME desktops. First add the Google or Microsoft identity in **Settings → Online Accounts** and enable Mail. Then open Mailficient’s **Accounts** window, choose **Add from GNOME Online Accounts**, and connect the identity. Mailficient reads the advertised IMAP/SMTP settings and requests short-lived OAuth tokens over the session bus. Tokens are kept only in process memory and are never copied into Mailficient’s database or Secret Service.

Direct in-application OAuth registration is not included. That optional alternative still requires provider registrations:

- Google: create an OAuth desktop client in Google Cloud Console, configure the consent screen, enable Gmail/IMAP access for the account, and provide the client ID. Desktop clients use PKCE and must not embed a client secret.
- Microsoft: register a public desktop client in Microsoft Entra, allow the native-client redirect URI, enable the IMAP/SMTP delegated scopes, and provide the application/client ID and tenant policy.

No shared client secret, password, or token is committed to this repository. On non-GNOME desktops, use a provider-supported app password where available or a standard IMAP/SMTP provider until a desktop account broker is integrated there.
