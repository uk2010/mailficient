namespace Mailficient {
public class ReplyRecipientService : Object {
    public ReplyRecipients build (Message source, string own_address) {
        string own = own_address.strip ().down ();
        var candidates = new Gee.ArrayList<Recipient> ();
        var seen = new Gee.HashSet<string> ();
        if (own != "") seen.add (own);

        add_address (candidates, seen, source.sender_name, source.sender_address);
        add_list (candidates, seen, source.recipients);
        add_list (candidates, seen, source.cc_recipients);

        if (candidates.size == 0) return new ReplyRecipients (source.sender_address, "");
        var to = candidates[0];
        var cc = new StringBuilder ();
        for (int index = 1; index < candidates.size; index++) {
            if (cc.len > 0) cc.append (", ");
            cc.append (candidates[index].formatted ());
        }
        return new ReplyRecipients (to.formatted (), cc.str);
    }

    private static void add_list (Gee.ArrayList<Recipient> output, Gee.Set<string> seen,
                                  string value) {
        if (value.strip () == "") return;
        try {
            foreach (var recipient in RecipientParser.parse (value))
                add_address (output, seen, recipient.name, recipient.address);
        } catch (Error error) {
            // A malformed historic header should not prevent replying to the
            // valid addresses that were already recovered.
        }
    }

    private static void add_address (Gee.ArrayList<Recipient> output, Gee.Set<string> seen,
                                     string name, string address) {
        string normalized = address.strip ().down ();
        if (!RecipientParser.is_valid_address (normalized) || seen.contains (normalized)) return;
        seen.add (normalized);
        output.add (new Recipient (name.strip (), normalized));
    }
}
}
