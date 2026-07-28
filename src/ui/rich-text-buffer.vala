namespace Mailficient {
public class RichTextBuffer : Object {
    public const string BOLD = "mailficient-bold";
    public const string ITALIC = "mailficient-italic";
    public const string UNDERLINE = "mailficient-underline";
    public const string STRIKETHROUGH = "mailficient-strikethrough";
    public const string CODE = "mailficient-code";
    private static string[] tags = { BOLD, ITALIC, UNDERLINE, STRIKETHROUGH, CODE };

    public static void prepare (Gtk.TextBuffer buffer) {
        if (buffer.tag_table.lookup (BOLD) == null)
            buffer.create_tag (BOLD, "weight", Pango.Weight.BOLD);
        if (buffer.tag_table.lookup (ITALIC) == null)
            buffer.create_tag (ITALIC, "style", Pango.Style.ITALIC);
        if (buffer.tag_table.lookup (UNDERLINE) == null)
            buffer.create_tag (UNDERLINE, "underline", Pango.Underline.SINGLE);
        if (buffer.tag_table.lookup (STRIKETHROUGH) == null)
            buffer.create_tag (STRIKETHROUGH, "strikethrough", true);
        if (buffer.tag_table.lookup (CODE) == null)
            buffer.create_tag (CODE, "family", "monospace", "background", "#deddda");
    }

    public static bool toggle_selection (Gtk.TextBuffer buffer, string tag_name) {
        Gtk.TextIter start; Gtk.TextIter end;
        if (!buffer.get_selection_bounds (out start, out end)) return false;
        var tag = buffer.tag_table.lookup (tag_name); if (tag == null) return false;
        bool every_character_has_tag = true; Gtk.TextIter cursor = start;
        while (cursor.compare (end) < 0) {
            if (!cursor.has_tag (tag)) { every_character_has_tag = false; break; }
            if (!cursor.forward_char ()) break;
        }
        if (every_character_has_tag) buffer.remove_tag (tag, start, end);
        else buffer.apply_tag (tag, start, end);
        return true;
    }

    public static string serialize (Gtk.TextBuffer buffer) {
        var builder = new Json.Builder (); builder.begin_array ();
        int count = buffer.get_char_count ();
        foreach (var tag_name in tags) {
            var tag = buffer.tag_table.lookup (tag_name); if (tag == null) continue;
            int run_start = -1; Gtk.TextIter iter; buffer.get_start_iter (out iter);
            for (int offset = 0; offset <= count; offset++) {
                bool active = offset < count && iter.has_tag (tag);
                if (active && run_start < 0) run_start = offset;
                if (!active && run_start >= 0) {
                    builder.begin_object (); builder.set_member_name ("tag"); builder.add_string_value (tag_name);
                    builder.set_member_name ("start"); builder.add_int_value (run_start);
                    builder.set_member_name ("end"); builder.add_int_value (offset); builder.end_object (); run_start = -1;
                }
                if (offset < count) iter.forward_char ();
            }
        }
        builder.end_array (); var generator = new Json.Generator (); generator.root = builder.get_root ();
        return generator.to_data (null);
    }

    public static void restore (Gtk.TextBuffer buffer, string serialized) {
        if (serialized.strip () == "") return;
        try {
            var parser = new Json.Parser (); parser.load_from_data (serialized);
            var array = parser.get_root ().get_array (); int count = buffer.get_char_count ();
            for (uint index = 0; index < array.get_length (); index++) {
                var item = array.get_object_element (index); string tag_name = item.get_string_member ("tag");
                var tag = buffer.tag_table.lookup (tag_name); if (tag == null) continue;
                int start_offset = int.max (0, int.min (count, (int) item.get_int_member ("start")));
                int end_offset = int.max (start_offset, int.min (count, (int) item.get_int_member ("end")));
                Gtk.TextIter start; Gtk.TextIter end; buffer.get_iter_at_offset (out start, start_offset);
                buffer.get_iter_at_offset (out end, end_offset); buffer.apply_tag (tag, start, end);
            }
        } catch (Error error) { warning ("Could not restore draft formatting: %s", error.message); }
    }

    public static string to_html (Gtk.TextBuffer buffer) {
        int count = buffer.get_char_count (); bool bold = false; bool italic = false; bool underline = false;
        bool strike = false; bool code = false;
        bool has_formatting = buffer.text.contains ("[Image: "); var html = new StringBuilder ("<div>");
        var bold_tag = buffer.tag_table.lookup (BOLD); var italic_tag = buffer.tag_table.lookup (ITALIC);
        var underline_tag = buffer.tag_table.lookup (UNDERLINE);
        var strike_tag = buffer.tag_table.lookup (STRIKETHROUGH); var code_tag = buffer.tag_table.lookup (CODE);
        Gtk.TextIter iter; buffer.get_start_iter (out iter);
        for (int offset = 0; offset < count; offset++) {
            bool next_bold = bold_tag != null && iter.has_tag (bold_tag);
            bool next_italic = italic_tag != null && iter.has_tag (italic_tag);
            bool next_underline = underline_tag != null && iter.has_tag (underline_tag);
            bool next_strike = strike_tag != null && iter.has_tag (strike_tag);
            bool next_code = code_tag != null && iter.has_tag (code_tag);
            if (next_bold != bold || next_italic != italic || next_underline != underline ||
                next_strike != strike || next_code != code) {
                close_tags (html, bold, italic, underline, strike, code);
                open_tags (html, next_bold, next_italic, next_underline, next_strike, next_code);
                bold = next_bold; italic = next_italic; underline = next_underline;
                strike = next_strike; code = next_code;
            }
            has_formatting = has_formatting || bold || italic || underline || strike || code;
            unichar character = iter.get_char ();
            switch (character) {
            case '&': html.append ("&amp;"); break;
            case '<': html.append ("&lt;"); break;
            case '>': html.append ("&gt;"); break;
            case '"': html.append ("&quot;"); break;
            case '\n': html.append ("<br>\n"); break;
            default: html.append_unichar (character); break;
            }
            iter.forward_char ();
        }
        close_tags (html, bold, italic, underline, strike, code); html.append ("</div>");
        return has_formatting ? html.str : "";
    }

    private static void close_tags (StringBuilder html, bool bold, bool italic, bool underline,
                                    bool strike, bool code) {
        if (code) html.append ("</code>"); if (strike) html.append ("</s>");
        if (underline) html.append ("</u>"); if (italic) html.append ("</em>"); if (bold) html.append ("</strong>");
    }

    private static void open_tags (StringBuilder html, bool bold, bool italic, bool underline,
                                   bool strike, bool code) {
        if (bold) html.append ("<strong>"); if (italic) html.append ("<em>"); if (underline) html.append ("<u>");
        if (strike) html.append ("<s>"); if (code) html.append ("<code>");
    }

    public static void prefix_lines (Gtk.TextBuffer buffer, bool ordered) {
        Gtk.TextIter start; Gtk.TextIter end;
        if (!buffer.get_selection_bounds (out start, out end)) {
            buffer.get_iter_at_mark (out start, buffer.get_insert ()); end = start;
            start.set_line_offset (0); end.forward_to_line_end ();
        } else {
            start.set_line_offset (0);
            if (!end.ends_line ()) end.forward_to_line_end ();
        }
        string original = buffer.get_text (start, end, true);
        var replacement = new StringBuilder (); int number = 1;
        foreach (var line in original.split ("\n")) {
            if (replacement.len > 0) replacement.append_c ('\n');
            replacement.append (ordered ? "%d. ".printf (number++) : "• ").append (line);
        }
        buffer.delete (ref start, ref end); buffer.insert (ref start, replacement.str, -1);
    }
}
}
