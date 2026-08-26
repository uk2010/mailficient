using GLib;

private void test_spelling_replacement_is_one_preserving_edit () {
    var buffer = new Gtk.TextBuffer (null);
    buffer.enable_undo = true;
    Mailficient.RichTextBuffer.prepare (buffer);
    buffer.text = "teh keep teh";

    Gtk.TextIter selected_start; Gtk.TextIter selected_end;
    buffer.get_iter_at_offset (out selected_start, 0);
    buffer.get_iter_at_offset (out selected_end, 3);
    buffer.select_range (selected_start, selected_end);

    Gtk.TextIter target_start; Gtk.TextIter target_end;
    buffer.get_iter_at_offset (out target_start, 9);
    buffer.get_iter_at_offset (out target_end, 12);
    var bold = buffer.tag_table.lookup (Mailficient.RichTextBuffer.BOLD);
    assert (bold != null);
    buffer.apply_tag (bold, target_start, target_end);
    assert (target_start.has_tag (bold));
    var spelling = buffer.create_tag ("test-spelling", "underline",
        Pango.Underline.ERROR);
    buffer.apply_tag (spelling, target_start, target_end);

    Mailficient.RichTextBuffer.replace_preserving_format (buffer, target_start,
        target_end, "the");
    assert (buffer.text == "teh keep the");
    assert (buffer.get_selection_bounds (out selected_start, out selected_end));
    assert (selected_start.get_offset () == 0 && selected_end.get_offset () == 3);
    buffer.get_iter_at_offset (out target_start, 9);
    buffer.get_iter_at_offset (out target_end, 12);
    Gtk.TextIter cursor = target_start;
    while (cursor.compare (target_end) < 0) {
        assert (cursor.has_tag (bold));
        assert (!cursor.has_tag (spelling));
        cursor.forward_char ();
    }

    buffer.undo ();
    assert (buffer.text == "teh keep teh");
    buffer.get_iter_at_offset (out target_start, 9);
    buffer.get_iter_at_offset (out target_end, 12);
    cursor = target_start;
    while (cursor.compare (target_end) < 0) {
        assert (cursor.has_tag (bold));
        assert (!cursor.has_tag (spelling));
        cursor.forward_char ();
    }
    buffer.redo ();
    assert (buffer.text == "teh keep the");
    buffer.get_iter_at_offset (out target_start, 9);
    buffer.get_iter_at_offset (out target_end, 12);
    cursor = target_start;
    while (cursor.compare (target_end) < 0) {
        assert (cursor.has_tag (bold));
        assert (!cursor.has_tag (spelling));
        cursor.forward_char ();
    }
}

private void test_spelling_undo_restores_partial_formatting () {
    var buffer = new Gtk.TextBuffer (null);
    buffer.enable_undo = true;
    Mailficient.RichTextBuffer.prepare (buffer);
    buffer.text = "teh";
    var bold = buffer.tag_table.lookup (Mailficient.RichTextBuffer.BOLD);
    Gtk.TextIter start; Gtk.TextIter end;
    buffer.get_iter_at_offset (out start, 0);
    buffer.get_iter_at_offset (out end, 2);
    buffer.apply_tag (bold, start, end);
    buffer.get_iter_at_offset (out end, 3);
    Mailficient.RichTextBuffer.replace_preserving_format (buffer, start, end,
        "the");
    buffer.get_iter_at_offset (out start, 0);
    assert (!start.has_tag (bold));
    buffer.undo ();
    assert (buffer.text == "teh");
    buffer.get_iter_at_offset (out start, 0);
    assert (start.has_tag (bold));
    buffer.get_iter_at_offset (out start, 1);
    assert (start.has_tag (bold));
    buffer.get_iter_at_offset (out start, 2);
    assert (!start.has_tag (bold));
    buffer.redo ();
    assert (buffer.text == "the");
    buffer.get_iter_at_offset (out start, 0);
    assert (!start.has_tag (bold));
}

private void test_unicode_spelling_replacement_uses_character_offsets () {
    var buffer = new Gtk.TextBuffer (null);
    buffer.enable_undo = true;
    Mailficient.RichTextBuffer.prepare (buffer);
    buffer.text = "Café teh notes";
    Gtk.TextIter start; Gtk.TextIter end;
    buffer.get_iter_at_offset (out start, 5);
    buffer.get_iter_at_offset (out end, 8);
    Mailficient.RichTextBuffer.replace_preserving_format (buffer, start, end, "the");
    assert (buffer.text == "Café the notes");
    buffer.undo ();
    assert (buffer.text == "Café teh notes");
}

private void assert_bold_range (Gtk.TextBuffer buffer, int start_offset,
                                int end_offset) {
    var bold = buffer.tag_table.lookup (Mailficient.RichTextBuffer.BOLD);
    Gtk.TextIter cursor; Gtk.TextIter end;
    buffer.get_iter_at_offset (out cursor, start_offset);
    buffer.get_iter_at_offset (out end, end_offset);
    while (cursor.compare (end) < 0) {
        assert (cursor.has_tag (bold));
        cursor.forward_char ();
    }
}

private void test_multiple_corrections_track_shifted_undo_ranges () {
    var buffer = new Gtk.TextBuffer (null);
    buffer.enable_undo = true;
    Mailficient.RichTextBuffer.prepare (buffer);
    buffer.text = "adress teh";
    var bold = buffer.tag_table.lookup (Mailficient.RichTextBuffer.BOLD);
    Gtk.TextIter start; Gtk.TextIter end;
    buffer.get_iter_at_offset (out start, 0);
    buffer.get_iter_at_offset (out end, 6);
    buffer.apply_tag (bold, start, end);
    buffer.get_iter_at_offset (out start, 7);
    buffer.get_iter_at_offset (out end, 10);
    buffer.apply_tag (bold, start, end);
    Mailficient.RichTextBuffer.replace_preserving_format (buffer, start, end,
        "the");
    buffer.get_iter_at_offset (out start, 0);
    buffer.get_iter_at_offset (out end, 6);
    Mailficient.RichTextBuffer.replace_preserving_format (buffer, start, end,
        "address");
    assert (buffer.text == "address the");
    buffer.undo ();
    assert (buffer.text == "adress the");
    assert_bold_range (buffer, 0, 6);
    assert_bold_range (buffer, 7, 10);
    buffer.undo ();
    assert (buffer.text == "adress teh");
    assert_bold_range (buffer, 0, 6);
    assert_bold_range (buffer, 7, 10);
    buffer.redo ();
    buffer.redo ();
    assert (buffer.text == "address the");
    assert_bold_range (buffer, 0, 7);
    assert_bold_range (buffer, 8, 11);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/compose/spelling-replacement-preserves-selection-and-format",
        test_spelling_replacement_is_one_preserving_edit);
    Test.add_func ("/compose/spelling-replacement-unicode-offsets",
        test_unicode_spelling_replacement_uses_character_offsets);
    Test.add_func ("/compose/spelling-undo-restores-partial-formatting",
        test_spelling_undo_restores_partial_formatting);
    Test.add_func ("/compose/spelling-multiple-undo-tracks-shifted-ranges",
        test_multiple_corrections_track_shifted_undo_ranges);
    return Test.run ();
}
