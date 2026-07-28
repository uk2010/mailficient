using Mailficient;

int main (string[] args) {
    string query = args.length > 1 ? args[1] : "com";
    var provider = new GnomeAddressBookProvider ();
    var loop = new MainLoop (); int status = 0;
    provider.suggest.begin (query, 50, null, (object, result) => {
        try {
            var contacts = provider.suggest.end (result);
            stdout.printf ("Mailficient provider matches: %d\n", contacts.size);
        } catch (Error error) {
            stderr.printf ("Mailficient provider failed: %s\n", error.message); status = 1;
        }
        loop.quit ();
    });
    loop.run (); return status;
}
