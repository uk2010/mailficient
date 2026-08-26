namespace Mailficient {
private class FormatRun : Object {
    public Gtk.TextTag tag;
    public int start_offset;
    public int end_offset;

    public FormatRun (Gtk.TextTag tag, int start_offset, int end_offset) {
        this.tag = tag;
        this.start_offset = start_offset;
        this.end_offset = end_offset;
    }
}

// Gtk.TextBuffer's built-in undo history records text edits but not tag
// application. Track the formatting snapshot around a correction and restore
// it after GTK performs the corresponding Undo or Redo action.
private class FormatUndoRecord : Object {
    private weak Gtk.TextBuffer buffer;
    private Gtk.TextMark start_mark;
    private string original;
    private string replacement;
    private Gee.ArrayList<Gtk.TextTag> format_tags;
    private Gee.ArrayList<FormatRun> original_runs;
    private Gee.ArrayList<FormatRun> replacement_runs;
    private bool applied = true;
    private bool undo_candidate;
    private bool redo_candidate;

    public FormatUndoRecord (Gtk.TextBuffer buffer, Gtk.TextMark start_mark,
                             string original, string replacement,
                             Gee.ArrayList<Gtk.TextTag> format_tags,
                             Gee.ArrayList<FormatRun> original_runs,
                             Gee.ArrayList<FormatRun> replacement_runs) {
        this.buffer = buffer;
        this.start_mark = start_mark;
        this.original = original;
        this.replacement = replacement;
        this.format_tags = format_tags;
        this.original_runs = original_runs;
        this.replacement_runs = replacement_runs;
        buffer.undo.connect (() => {
            undo_candidate = applied && contains_text (replacement);
        });
        buffer.undo.connect_after (() => {
            if (undo_candidate && contains_text (original)) {
                restore (original, original_runs);
                applied = false;
            }
            undo_candidate = false;
        });
        buffer.redo.connect (() => {
            redo_candidate = !applied && contains_text (original);
        });
        buffer.redo.connect_after (() => {
            if (redo_candidate && contains_text (replacement)) {
                restore (replacement, replacement_runs);
                applied = true;
            }
            redo_candidate = false;
        });
    }

    private bool bounds_for (string text, out Gtk.TextIter start,
                             out Gtk.TextIter end) {
        buffer.get_iter_at_mark (out start, start_mark);
        int end_offset = start.get_offset () + text.char_count ();
        if (end_offset > buffer.get_char_count ()) {
            end = start;
            return false;
        }
        buffer.get_iter_at_offset (out end, end_offset);
        return true;
    }

    private bool contains_text (string text) {
        Gtk.TextIter start; Gtk.TextIter end;
        return bounds_for (text, out start, out end) &&
            buffer.get_text (start, end, true) == text;
    }

    private void restore (string text, Gee.ArrayList<FormatRun> runs) {
        Gtk.TextIter start; Gtk.TextIter end;
        if (!bounds_for (text, out start, out end)) return;
        foreach (var tag in format_tags) buffer.remove_tag (tag, start, end);
        int base_offset = start.get_offset ();
        foreach (var run in runs) {
            Gtk.TextIter run_start; Gtk.TextIter run_end;
            buffer.get_iter_at_offset (out run_start,
                base_offset + run.start_offset);
            buffer.get_iter_at_offset (out run_end,
                base_offset + run.end_offset);
            buffer.apply_tag (run.tag, run_start, run_end);
        }
    }
}

public class RichTextBuffer : Object {
    public const string BOLD = "mailficient-bold";
    public const string ITALIC = "mailficient-italic";
    public const string UNDERLINE = "mailficient-underline";
    public const string STRIKETHROUGH = "mailficient-strikethrough";
    public const string CODE = "mailficient-code";
    private static string[] format_tags () {
        return new string[] { BOLD, ITALIC, UNDERLINE, STRIKETHROUGH, CODE };
    }

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

    // Replace one word as a single undoable edit while carrying the
    // composer formatting that covered the complete source range. Transient
    // tags such as the spelling underline are intentionally excluded.
    public static void replace_preserving_format (Gtk.TextBuffer buffer,
                                                  Gtk.TextIter start,
                                                  Gtk.TextIter end,
                                                  string replacement) {
        string original = buffer.get_text (start, end, true);
        int original_length = original.char_count ();
        var tags = new Gee.ArrayList<Gtk.TextTag> ();
        var original_runs = new Gee.ArrayList<FormatRun> ();
        var replacement_runs = new Gee.ArrayList<FormatRun> ();
        var retained = new Gee.ArrayList<Gtk.TextTag> ();
        foreach (var tag_name in format_tags ()) {
            var tag = buffer.tag_table.lookup (tag_name);
            if (tag == null) continue;
            tags.add (tag);
            bool covers_range = start.compare (end) < 0;
            Gtk.TextIter cursor = start;
            int relative_offset = 0;
            int run_start = -1;
            while (cursor.compare (end) < 0) {
                bool active = cursor.has_tag (tag);
                if (!active) covers_range = false;
                if (active && run_start < 0) run_start = relative_offset;
                if (!active && run_start >= 0) {
                    original_runs.add (new FormatRun (tag, run_start,
                        relative_offset));
                    run_start = -1;
                }
                if (!cursor.forward_char ()) break;
                relative_offset++;
            }
            if (run_start >= 0)
                original_runs.add (new FormatRun (tag, run_start,
                    original_length));
            if (covers_range) retained.add (tag);
        }

        int replacement_length = replacement.char_count ();
        foreach (var tag in retained)
            replacement_runs.add (new FormatRun (tag, 0, replacement_length));

        int insertion_offset = start.get_offset ();
        buffer.begin_user_action ();
        buffer.delete (ref start, ref end);
        Gtk.TextIter insertion_start;
        buffer.get_iter_at_offset (out insertion_start, insertion_offset);
        Gtk.TextIter insertion_end = insertion_start;
        buffer.insert (ref insertion_end, replacement, -1);
        // Inserting invalidates every iterator except the one passed by ref.
        // Resolve the range again before applying the retained tags.
        buffer.get_iter_at_offset (out insertion_start, insertion_offset);
        buffer.get_iter_at_offset (out insertion_end,
            insertion_offset + replacement_length);
        foreach (var tag in tags)
            buffer.remove_tag (tag, insertion_start, insertion_end);
        foreach (var run in replacement_runs)
            buffer.apply_tag (run.tag, insertion_start, insertion_end);
        buffer.end_user_action ();
        if (original_runs.size > 0 || replacement_runs.size > 0) {
            buffer.get_iter_at_offset (out insertion_start, insertion_offset);
            var tracking_mark = buffer.create_mark (null, insertion_start, true);
            new FormatUndoRecord (buffer, tracking_mark, original, replacement,
                tags, original_runs, replacement_runs);
        }
    }

    public static string serialize (Gtk.TextBuffer buffer) {
        var builder = new Json.Builder (); builder.begin_array ();
        int count = buffer.get_char_count ();
        foreach (var tag_name in format_tags ()) {
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
        bool has_formatting;
        string fragment = render_html (buffer, 0, buffer.get_char_count (), out has_formatting);
        return has_formatting ? "<div>" + fragment + "</div>" : "";
    }

    // Render a range even when it has no composer formatting. This lets
    // replies and forwards combine editable text with a preserved HTML quote.
    public static string to_html_fragment (Gtk.TextBuffer buffer, int start_offset, int end_offset) {
        bool has_formatting;
        return render_html (buffer, start_offset, end_offset, out has_formatting);
    }

    private static string render_html (Gtk.TextBuffer buffer, int start_offset, int end_offset,
                                       out bool has_formatting) {
        int count = buffer.get_char_count ();
        int start = int.max (0, int.min (count, start_offset));
        int end = int.max (start, int.min (count, end_offset));
        bool bold = false; bool italic = false; bool underline = false;
        bool strike = false; bool code = false;
        has_formatting = buffer.text.contains ("[Image: "); var html = new StringBuilder ();
        var bold_tag = buffer.tag_table.lookup (BOLD); var italic_tag = buffer.tag_table.lookup (ITALIC);
        var underline_tag = buffer.tag_table.lookup (UNDERLINE);
        var strike_tag = buffer.tag_table.lookup (STRIKETHROUGH); var code_tag = buffer.tag_table.lookup (CODE);
        Gtk.TextIter iter; buffer.get_iter_at_offset (out iter, start);
        for (int offset = start; offset < end; offset++) {
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
        close_tags (html, bold, italic, underline, strike, code);
        return html.str;
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
