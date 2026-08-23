namespace Mailficient {
public class Recipient : Object {
    public string name { get; construct; }
    public string address { get; construct; }
    public Recipient (string name, string address) { Object (name: name, address: address.down ()); }
    public string formatted () {
        if (name == "") return address;
        string display = name;
        if (display.contains (",") || display.contains ("\"") || display.contains ("<") || display.contains (">"))
            display = "\"%s\"".printf (display.replace ("\\", "\\\\").replace ("\"", "\\\""));
        return "%s <%s>".printf (display, address);
    }
}

public class RecipientParser : Object {
    private static Regex? address_expression;

    public static bool is_valid_address (string value) {
        try {
            if (address_expression == null)
                address_expression = new Regex ("^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$", RegexCompileFlags.CASELESS);
            return ((Regex) address_expression).match (value.strip ());
        } catch (RegexError error) { return false; }
    }

    public static Gee.List<Recipient> parse (string value) throws MailError {
        var result = new Gee.ArrayList<Recipient> ();
        foreach (string raw in split_recipients (value)) {
            string item = raw.strip (); if (item == "") continue;
            string name = ""; string address = item;
            int open = item.last_index_of_char ('<'); int close = item.last_index_of_char ('>');
            if (open >= 0 && close > open) {
                name = item.substring (0, open).strip ();
                if (name.length >= 2 && name.has_prefix ("\"") && name.has_suffix ("\""))
                    name = name.substring (1, name.length - 2).replace ("\\\"", "\"").replace ("\\\\", "\\");
                address = item.substring (open + 1, close - open - 1).strip ();
            }
            if (!is_valid_address (address)) throw new MailError.INVALID_MESSAGE ("Invalid recipient: %s".printf (item));
            result.add (new Recipient (name, address));
        }
        if (result.size == 0) throw new MailError.INVALID_MESSAGE ("At least one recipient is required");
        return result;
    }

    private static Gee.List<string> split_recipients (string value) {
        var result = new Gee.ArrayList<string> (); var current = new StringBuilder ();
        bool quoted = false; bool escaped = false; int angle_depth = 0;
        for (int index = 0; index < value.length; index++) {
            char character = value[index];
            if (escaped) { current.append_c (character); escaped = false; continue; }
            if (quoted && character == '\\') { current.append_c (character); escaped = true; continue; }
            if (character == '\"') quoted = !quoted;
            else if (!quoted && character == '<') angle_depth++;
            else if (!quoted && character == '>' && angle_depth > 0) angle_depth--;
            if (character == ',' && !quoted && angle_depth == 0) {
                result.add (current.str); current = new StringBuilder (); continue;
            }
            current.append_c (character);
        }
        result.add (current.str); return result;
    }
}
}
