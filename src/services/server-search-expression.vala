namespace Mailficient {
public class ServerSearchExpression : Object {
    public static string build (SearchQuery query) {
        if (query.clauses.size == 0) return "(match-all #t)";
        var alternatives = new Gee.ArrayList<string> ();
        foreach (var clause in query.clauses) {
            var conditions = new Gee.ArrayList<string> ();
            foreach (var term in clause.terms) conditions.add (for_term (term));
            alternatives.add (join (conditions, "and"));
        }
        // Camel evaluates header/body/status predicates in single-message
        // mode only when they are below match-all. IMAPX returns an empty UID
        // list for a bare header-contains expression even when the server has
        // a matching message, so every generated query needs this outer
        // search operator.
        string predicate = alternatives.size == 1 ? alternatives[0] :
            join (alternatives, "or");
        return "(match-all %s)".printf (predicate);
    }

    private static string for_term (SearchTerm term) {
        string value = quote (term.value); string expression; bool supported = true;
        switch (term.field) {
        case SearchField.SENDER: expression = "(header-contains \"From\" %s)".printf (value); break;
        case SearchField.RECIPIENT:
            expression = "(or (header-contains \"To\" %s) (header-contains \"Cc\" %s) (header-contains \"Bcc\" %s))".printf (value, value, value); break;
        case SearchField.CC: expression = "(header-contains \"Cc\" %s)".printf (value); break;
        case SearchField.BCC: expression = "(header-contains \"Bcc\" %s)".printf (value); break;
        case SearchField.SUBJECT: expression = "(header-contains \"Subject\" %s)".printf (value); break;
        case SearchField.ANY:
            expression = "(or (header-contains \"From\" %s) (header-contains \"To\" %s) (header-contains \"Cc\" %s) (header-contains \"Subject\" %s) (body-contains %s))".printf (value, value, value, value, value); break;
        case SearchField.UNREAD:
            expression = term.value == "1" ? "(not (system-flag \"Seen\"))" : "(system-flag \"Seen\")"; break;
        case SearchField.FLAGGED:
            expression = term.value == "1" ? "(system-flag \"Flagged\")" : "(not (system-flag \"Flagged\"))"; break;
        case SearchField.AFTER: expression = "(>= (get-sent-date) %s)".printf (term.value); break;
        case SearchField.BEFORE: expression = "(< (get-sent-date) %s)".printf (term.value); break;
        case SearchField.DATE_RANGE: {
            string[] bounds = term.value.split (":", 2);
            expression = bounds.length == 2 ?
                "(and (>= (get-sent-date) %s) (< (get-sent-date) %s))".printf (
                    bounds[0], bounds[1]) : "#t";
            supported = bounds.length == 2;
            break;
        }
        case SearchField.MESSAGE_SIZE:
            if (term.comparison == SearchComparison.GREATER_THAN) expression = "(> (get-size) %s)".printf (term.value);
            else if (term.comparison == SearchComparison.LESS_THAN) expression = "(< (get-size) %s)".printf (term.value);
            else expression = "(= (get-size) %s)".printf (term.value);
            break;
        // Folder/account scopes choose the remote folder before this
        // expression is sent. Local-only metadata is filtered after bounded
        // remote candidates have been cached.
        default: expression = "#t"; supported = false; break;
        }
        // Account, folder, label, and attachment metadata are resolved by
        // folder selection or by the private local index after bounded remote
        // candidates arrive. Negating an unsupported term must not turn the
        // server expression into `#f`, which would discard every candidate.
        if (!supported) return expression;
        return term.negated ? "(not %s)".printf (expression) : expression;
    }

    private static string join (Gee.List<string> expressions, string operation) {
        if (expressions.size == 0) return "#t";
        if (expressions.size == 1) return expressions[0];
        var result = new StringBuilder ("(" + operation);
        foreach (var expression in expressions) result.append (" " + expression);
        result.append_c (')'); return result.str;
    }

    private static string quote (string value) {
        string clean = value.replace ("\\", "\\\\").replace ("\"", "\\\"")
            .replace ("\r", " ").replace ("\n", " ");
        return "\"" + clean + "\"";
    }
}
}
