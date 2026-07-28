namespace Mailficient {
public class ConversationBuilder : Object {
    public Gee.ArrayList<Message> build (Gee.Iterable<Message> candidates, Message selected) {
        // Keep a reply graph, not a bucket of coincidentally equal IDs.
        // Some bulk senders reuse one Message-ID for multiple independent
        // deliveries, so equality of Message-ID alone is not a relationship.
        var member_ids = new Gee.HashSet<string> ();
        var member_references = new Gee.HashSet<string> ();
        add_ids (member_ids, selected.internet_message_id);
        add_ids (member_references, selected.in_reply_to);
        add_ids (member_references, selected.references);
        var result = new Gee.ArrayList<Message> ();
        result.add (selected);
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (var candidate in candidates) {
                if (contains_message (result, candidate.id) || candidate.account_id != selected.account_id) continue;
                bool related = message_points_to (candidate, member_ids) ||
                    referenced_by_members (candidate, member_references);
                if (!related) continue;
                result.add (candidate); changed = true;
                add_ids (member_ids, candidate.internet_message_id);
                add_ids (member_references, candidate.in_reply_to);
                add_ids (member_references, candidate.references);
            }
        }
        result.sort ((a, b) => reference_depth (a) - reference_depth (b));
        return result;
    }

    private static bool referenced_by_members (Message message, Gee.Set<string> references) {
        foreach (var id in header_ids (message.internet_message_id))
            if (references.contains (id)) return true;
        return false;
    }

    private static bool message_points_to (Message message, Gee.Set<string> ids) {
        foreach (var id in header_ids (message.in_reply_to + " " + message.references))
            if (ids.contains (id)) return true;
        return false;
    }

    private static void add_ids (Gee.Set<string> ids, string header) {
        foreach (var id in header_ids (header)) ids.add (id);
    }

    private static Gee.ArrayList<string> header_ids (string header) {
        var result = new Gee.ArrayList<string> ();
        foreach (var token in header.replace ("\t", " ").split (" ")) {
            string value = token.strip ().replace (",", "");
            if (value != "") result.add (value);
        }
        return result;
    }

    private static int reference_depth (Message message) {
        return header_ids (message.references).size + (message.in_reply_to == "" ? 0 : 1);
    }

    private static bool contains_message (Gee.List<Message> messages, string id) {
        foreach (var message in messages) if (message.id == id) return true;
        return false;
    }
}
}
