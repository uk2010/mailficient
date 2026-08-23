namespace Mailficient {
public class GnomeAddressBookProvider : Object, ContactSuggestionProvider {
    private E.SourceRegistry? registry;
    private Gee.ArrayList<E.BookClient> clients = new Gee.ArrayList<E.BookClient> ();
    private bool initialized;
    private bool initializing;
    private signal void initialization_finished ();

    public async Gee.List<Recipient> suggest (string query, uint limit,
                                              Cancellable? cancellable = null) throws Error {
        var result = new Gee.ArrayList<Recipient> ();
        string normalized_query = query.strip ();
        if (normalized_query.length == 1 || limit == 0) return result;
        yield ensure_clients (cancellable);
        var addresses = new Gee.HashSet<string> ();
        string expression = normalized_query == "" ?
            E.BookQuery.field_exists (E.ContactField.EMAIL).to_string () :
            E.BookQuery.any_field_contains (normalized_query).to_string ();

        foreach (var client in clients) {
            if (result.size >= limit) break;
            try {
                GLib.SList<string> matching_uids;
                yield client.get_contacts_uids (expression, cancellable, out matching_uids);
                uint inspected = 0;
                foreach (var uid in matching_uids) {
                    if (result.size >= limit || inspected++ >= 200) break;
                    E.Contact contact;
                    yield client.get_contact (uid, cancellable, out contact);
                    add_contact (result, addresses, contact, limit);
                }
            } catch (Error error) {
                if (error is IOError.CANCELLED) throw error;
                warning ("Could not search a GNOME address book: %s", error.message);
            }
        }
        return result;
    }

    private async void ensure_clients (Cancellable? cancellable) throws Error {
        if (initialized) return;
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        if (initializing) {
            ulong handler = 0;
            handler = initialization_finished.connect (() => {
                disconnect (handler); ensure_clients.callback ();
            });
            yield;
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (initialized) return;
            // The previous initializer failed before publishing clients.  Let
            // this request make a fresh, serialized attempt.
            yield ensure_clients (cancellable); return;
        }
        initializing = true;
        clients.clear ();
        try {
            // Client discovery is shared by picker and autocomplete requests.
            // Do not bind it to one short-lived search cancellable: cancelling
            // that search must not tear down clients another request is using.
            registry = yield new E.SourceRegistry (null);
            foreach (var source in registry.list_enabled (E.SOURCE_EXTENSION_ADDRESS_BOOK)) {
                var attempt = new Cancellable ();
                bool timed_out = false;
                uint timeout_source = 0;
                // A disabled or unreachable address book must not hold the
                // Contacts picker behind several sequential five-second
                // connection attempts.
                timeout_source = Timeout.add (1500, () => {
                    timeout_source = 0; timed_out = true; attempt.cancel (); return Source.REMOVE;
                });
                try {
                    clients.add (yield E.BookClient.connect (source, 3, attempt));
                } catch (Error error) {
                    if (!timed_out)
                        warning ("Could not open one GNOME address book: %s", error.message);
                }
                if (timeout_source != 0) Source.remove (timeout_source);
            }
            initialized = true;
        } finally {
            initializing = false; initialization_finished ();
        }
        if (cancellable != null) cancellable.set_error_if_cancelled ();
    }

    private static void add_contact (Gee.ArrayList<Recipient> result,
                                     Gee.HashSet<string> addresses, E.Contact contact,
                                     uint limit) {
        string name = contact.get<string> (E.ContactField.FULL_NAME) ?? "";
        foreach (var attribute in ((E.VCard) contact).get_attributes ()) {
            if (attribute.get_name ().ascii_casecmp (E.EVC_EMAIL) != 0) continue;
            foreach (var value in attribute.get_values ()) {
                string address = value.strip ().down ();
                if (result.size >= limit || !RecipientParser.is_valid_address (address) ||
                    addresses.contains (address)) continue;
                addresses.add (address); result.add (new Recipient (name.strip (), address));
            }
        }
    }
}
}
