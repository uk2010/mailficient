namespace Mailficient {
public class ToolbarLayout : Object {
    public const string DEFAULT_LAYOUT =
        "compose,flex,reply-group,mail-actions,move,flag,flex,search,sort";

    public static Gee.ArrayList<string> parse (string serialized) {
        var result = new Gee.ArrayList<string> ();
        var unique = new Gee.HashSet<string> ();
        foreach (var raw in serialized.split (",")) {
            string id = raw.strip ();
            if (!is_valid (id)) continue;
            if (id != "space" && id != "flex" && unique.contains (id)) continue;
            result.add (id);
            if (id != "space" && id != "flex") unique.add (id);
        }
        return result;
    }

    public static string serialize (Gee.List<string> items) {
        var serialized = new StringBuilder ();
        foreach (var id in items) {
            if (serialized.len > 0) serialized.append_c (',');
            serialized.append (id);
        }
        return serialized.str;
    }

    public static bool is_repeatable (string id) {
        return id == "space" || id == "flex";
    }

    public static bool is_valid (string id) {
        switch (id) {
        case "sidebar":
        case "refresh":
        case "compose":
        case "reply-group":
        case "mail-actions":
        case "reply":
        case "reply-all":
        case "forward":
        case "archive":
        case "trash":
        case "junk":
        case "move":
        case "flag":
        case "toggle-read":
        case "labels":
        case "snooze":
        case "print":
        case "search":
        case "sort":
        case "space":
        case "flex":
            return true;
        default:
            return false;
        }
    }

    public static string label (string id) {
        switch (id) {
        case "sidebar": return "Sidebar";
        case "refresh": return "Get Mail";
        case "compose": return "New Message";
        case "reply-group": return "Reply · Reply All · Forward";
        case "mail-actions": return "Archive · Delete · Junk";
        case "reply": return "Reply";
        case "reply-all": return "Reply All";
        case "forward": return "Forward";
        case "archive": return "Archive";
        case "trash": return "Delete";
        case "junk": return "Junk";
        case "move": return "Move";
        case "flag": return "Flag";
        case "toggle-read": return "Unread / Read";
        case "labels": return "Labels";
        case "snooze": return "Snooze";
        case "print": return "Print";
        case "search": return "Search";
        case "sort": return "Sort";
        case "space": return "Space";
        case "flex": return "Flexible Space";
        default: return id;
        }
    }

    public static string icon_name (string id) {
        switch (id) {
        case "sidebar": return "sidebar-show-symbolic";
        case "refresh": return "view-refresh-symbolic";
        case "compose": return "document-edit-symbolic";
        case "reply-group":
        case "reply": return "mail-reply-sender-symbolic";
        case "reply-all": return "mail-reply-all-symbolic";
        case "forward": return "mail-forward-symbolic";
        case "mail-actions":
        case "archive": return "package-x-generic-symbolic";
        case "trash": return "user-trash-symbolic";
        case "junk": return "dialog-warning-symbolic";
        case "move": return "folder-symbolic";
        case "flag": return "mailficient-flag-symbolic";
        case "toggle-read": return "mail-unread-symbolic";
        case "labels": return "tag-symbolic";
        case "snooze": return "alarm-symbolic";
        case "print": return "printer-symbolic";
        case "search": return "system-search-symbolic";
        case "sort": return "view-sort-descending-symbolic";
        case "space": return "toolbar-space-symbolic";
        case "flex": return "pan-end-symbolic";
        default: return "applications-system-symbolic";
        }
    }

    public static string[] palette_items () {
        return {
            "reply-group", "archive", "trash", "junk", "mail-actions",
            "reply", "reply-all", "forward", "flag", "move",
            "compose", "refresh", "print", "toggle-read", "labels",
            "snooze", "search", "sort", "sidebar", "space", "flex"
        };
    }
}
}
