namespace Mailficient {
public enum MessageSortMode { NEWEST, OLDEST, SENDER, SUBJECT, UNREAD_FIRST, FLAGGED_FIRST }

public class MessageSorter : Object {
    public Gee.ArrayList<Message> sort (Gee.List<Message> source, MessageSortMode mode) {
        var result = new Gee.ArrayList<Message> (); result.add_all (source);
        switch (mode) {
        case MessageSortMode.OLDEST:
            var reversed = new Gee.ArrayList<Message> ();
            for (int index = result.size - 1; index >= 0; index--) reversed.add (result[index]);
            return reversed;
        case MessageSortMode.SENDER:
            result.sort ((a, b) => a.sender_name.collate (b.sender_name)); break;
        case MessageSortMode.SUBJECT:
            result.sort ((a, b) => normalized_subject (a.subject).collate (normalized_subject (b.subject))); break;
        case MessageSortMode.UNREAD_FIRST:
            result.sort ((a, b) => a.unread == b.unread ? 0 : (a.unread ? -1 : 1)); break;
        case MessageSortMode.FLAGGED_FIRST:
            result.sort ((a, b) => a.flagged == b.flagged ? 0 : (a.flagged ? -1 : 1)); break;
        default: break;
        }
        return result;
    }

    private static string normalized_subject (string subject) {
        string value = subject.strip ().down ();
        while (value.has_prefix ("re:") || value.has_prefix ("fwd:") || value.has_prefix ("fw:")) {
            int colon = value.index_of_char (':'); value = value.substring (colon + 1).strip ();
        }
        return value;
    }
}
}
