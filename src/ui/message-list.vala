namespace Mailficient {
public class MessageList : Gtk.Box {
    public signal void message_selected (Message message);
    public signal void message_activated (Message message);
    public signal void selection_changed (Gee.List<Message> messages);
    public signal void no_messages ();
    public signal void clear_search_requested ();
    public signal void get_mail_requested ();
    private MailRepository repository;
    private MailSearchService search_service;
    private Gtk.ListView list;
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow ();
    private Gtk.Stack content_stack = new Gtk.Stack ();
    private Adw.StatusPage empty_status = new Adw.StatusPage ();
    private Gtk.Button empty_action = new Gtk.Button ();
    private VirtualMessageModel? model;
    private Gtk.SelectionModel? selection;
    private string mailbox_id = "inbox";
    private string query = "";
    private MailSearchScope search_scope = MailSearchScope.CURRENT_FOLDER;
    private uint search_source;
    private MessageSortMode sort_mode = MessageSortMode.NEWEST;
    private bool suppress_selection;
    private bool local_queue;
    private bool mailbox_loaded;
    private Gtk.Label mailbox_title = new Gtk.Label ("Inbox");
    private Gtk.Label message_count = new Gtk.Label ("");
    private Gtk.ToggleButton unread_filter = new Gtk.ToggleButton ();
    private Gtk.ToggleButton select_multiple = new Gtk.ToggleButton ();
    private string mailbox_name = "Inbox";
    private Gtk.Stack list_stack = new Gtk.Stack ();
    private Gee.HashMap<string, MessageRow> bound_rows = new Gee.HashMap<string, MessageRow> ();
    private bool suppress_unread_filter_reload;
    private uint unread_filter_reload_source;
    private bool refresh_deferred_until_shown;

    public MessageList (MailRepository repository, MailSearchService search_service) {
        Object (orientation: Gtk.Orientation.VERTICAL);
        this.repository = repository; this.search_service = search_service;
        hexpand = true; vexpand = true;
        halign = Gtk.Align.FILL; valign = Gtk.Align.FILL;
        set_size_request (0, -1);
        add_css_class ("message-list");
        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        header.add_css_class ("message-list-header");
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 0); labels.hexpand = true;
        labels.add_css_class ("message-list-title-group");
        mailbox_title.xalign = 0; mailbox_title.add_css_class ("title-3"); labels.append (mailbox_title);
        message_count.xalign = 0; message_count.add_css_class ("dim-label"); message_count.add_css_class ("message-count"); labels.append (message_count);
        header.append (labels);
        unread_filter.icon_name = "mail-unread-symbolic";
        unread_filter.tooltip_text = "Show unread messages only";
        Accessibility.label (unread_filter, "Show unread messages only");
        unread_filter.toggled.connect (() => {
            string label = unread_filter.active ?
                "Show all messages" : "Show unread messages only";
            unread_filter.tooltip_text = label;
            Accessibility.label (unread_filter, label);
            if (suppress_unread_filter_reload) return;
            // Rebuilding the virtual list synchronously from inside GTK's
            // ToggleButton state transition can leave the original pointer
            // event active while a large real mailbox is being rebound. Queue
            // one reload after the control has finished changing state, and
            // collapse a quick on/off gesture to the final requested state.
            if (unread_filter_reload_source != 0)
                Source.remove (unread_filter_reload_source);
            unread_filter_reload_source = Idle.add (() => {
                unread_filter_reload_source = 0;
                reload ();
                return Source.REMOVE;
            });
        });
        header.append (unread_filter);
        select_multiple.icon_name = "object-select-symbolic";
        select_multiple.tooltip_text = "Select multiple messages (Shift-click for a range, Ctrl+A for all)";
        Accessibility.label (select_multiple, "Select multiple messages");
        // Multi-selection is always available through the standard Shift-click
        // and Ctrl-click gestures. This button only reveals checkboxes.
        select_multiple.toggled.connect (refresh_row_widgets);
        header.append (select_multiple);
        append (header);
        var header_divider = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
        header_divider.add_css_class ("message-list-divider");
        append (header_divider);

        list = create_list_view ();
        list_stack.add_named (list, "transient");
        list_stack.vexpand = true; list_stack.hexpand = true;
        scroller.set_child (list_stack); scroller.vexpand = true;
        content_stack.vexpand = true;
        content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        content_stack.transition_duration = 160;
        empty_status.vexpand = true;
        empty_status.add_css_class ("empty-state");
        empty_action.halign = Gtk.Align.CENTER;
        empty_action.add_css_class ("pill");
        empty_action.clicked.connect (() => {
            if (query.strip () != "") {
                query = "";
                clear_search_requested ();
            } else if (unread_filter.active) {
                unread_filter.active = false;
            } else get_mail_requested ();
        });
        empty_status.child = empty_action;
        content_stack.add_named (scroller, "messages");
        content_stack.add_named (empty_status, "empty");
        append (content_stack);
        reload ();
        if (Environment.get_variable ("MAILFICIENT_QA_MULTI_SELECT") == "1") Timeout.add (500, () => {
            select_multiple.active = true;
            if (selection != null && model != null && model.get_n_items () > 1) {
                var selected = new Gtk.Bitset.range (0, 2);
                var mask = new Gtk.Bitset.range (0, 2);
                selection.set_selection (selected, mask);
            }
            return Source.REMOVE;
        });
    }

    private Gtk.ListView create_list_view () {
        var factory = new Gtk.SignalListItemFactory ();
        factory.bind.connect ((object) => {
            var item = object as Gtk.ListItem;
            var message = item == null ? null : item.item as Message;
            if (item == null || message == null) return;
            var row = new MessageRow (message, selection, item,
                select_multiple.active);
            row.reopen_requested.connect ((reopened) => message_selected (reopened));
            bound_rows[message.id] = row;
            item.child = row;
        });
        factory.unbind.connect ((object) => {
            var item = object as Gtk.ListItem;
            var row = item == null ? null : item.child as MessageRow;
            if (row != null) {
                row.unbind_selection ();
                if (bound_rows[row.message.id] == row) bound_rows.unset (row.message.id);
            }
            if (item != null) item.child = null;
        });
        var result = new Gtk.ListView (null, factory);
        result.add_css_class ("boxed-list");
        result.add_css_class ("message-list-items");
        result.show_separators = false;
        result.activate.connect ((position) => {
            var message = model == null ? null : model.get_item (position) as Message;
            if (message != null) message_activated (message);
        });
        return result;
    }

    public void show_mailbox (Mailbox mailbox) {
        int64 started = DebugTrace.mark ();
        bool already_loaded = mailbox_loaded && mailbox_id == mailbox.id && query == "" &&
            !unread_filter.active;
        bool refresh_when_shown = already_loaded && refresh_deferred_until_shown;
        DebugTrace.log ("message-list", "show_mailbox begin mailbox=%s old=%s already_loaded=%s".printf (
            mailbox.id, mailbox_id, already_loaded.to_string ()));
        mailbox_id = mailbox.id; mailbox_name = mailbox.name; mailbox_title.label = mailbox.name;
        query = "";
        if (unread_filter.active) {
            suppress_unread_filter_reload = true;
            unread_filter.active = false;
            suppress_unread_filter_reload = false;
        }
        if (already_loaded) {
            bool has_messages = model != null && model.get_n_items () > 0;
            content_stack.visible_child_name = has_messages ? "messages" : "empty";
            // Keep the reader in step even when the empty model was already
            // loaded. A fresh reload emits this from reload(); the cached path
            // must provide the same contract exactly once.
            if (!has_messages) no_messages ();
            if (refresh_when_shown) {
                refresh_deferred_until_shown = false;
                // Paint the retained row/reader immediately, then rebuild from
                // the current cache after the task-to-mail switch completes.
                Idle.add (() => {
                    refresh_preserving_selection ();
                    return Source.REMOVE;
                });
            }
            DebugTrace.duration ("message-list", "show_mailbox cached_complete", started);
            return;
        }
        refresh_deferred_until_shown = false;
        reload (false);
        DebugTrace.duration ("message-list", "show_mailbox complete", started);
    }

    public void search (string value) {
        query = value;
        if (search_source != 0) Source.remove (search_source);
        search_source = Timeout.add (120, () => {
            search_source = 0; reload (); return Source.REMOVE;
        });
    }

    public void set_search_scope (MailSearchScope scope) {
        if (search_scope == scope) return;
        search_scope = scope;
        if (query.strip () != "") reload (true, true);
    }

    public void refresh () { reload (true, false, "", true); }

    public bool showing_mailbox (string id) {
        return mailbox_loaded && query == "" && mailbox_id == id;
    }

    // Message views are intentionally not retained per mailbox. Keeping a
    // Gtk.ListView, selection model, and message pages for every favorite
    // makes memory and layout work grow each time the user visits another
    // mailbox.
    public void invalidate_cached_views () { }
    public void invalidate_cached_view (string id) { }
    public void invalidate_current_view () { }

    public void defer_refresh_until_shown () {
        // Background mail can arrive while Today or Planned owns the
        // workspace. Avoid rebuilding the hidden Gtk.ListView; show_mailbox()
        // consumes this marker and reloads once when mail becomes visible.
        refresh_deferred_until_shown = true;
    }

    public void mark_current_view_clean () {
        // The active model is already authoritative; inactive mailbox models
        // are not retained.
    }

    public void refresh_preserving_selection (string preferred_id = "") {
        // An unread-only list is a reading queue. Repository changes caused by
        // opening its selected message must not immediately remove that row
        // from under the reader. Keep the snapshot until the filter is toggled.
        if (unread_filter.active) {
            return;
        }
        reload (true, true, preferred_id, true);
    }

    public void refresh_after_removal () {
        // Removal actions must rebuild the model before selecting the next
        // message. Selecting against the old model lets the selection callback
        // run while the deleted row is still present and can retarget the next
        // delete action to the wrong message.
        if (model != null) {
            var selected = selected_messages ();
            var removed_ids = new Gee.ArrayList<string> ();
            foreach (var message in selected) removed_ids.add (message.id);
            // Gtk.MultiSelection adjusts its bitset while ListModel emits
            // items-changed. Suppress that intermediate state and clear it
            // explicitly so the caller's replacement selection starts from
            // exactly zero rows, even after a range removal.
            bool was_suppressed = suppress_selection;
            suppress_selection = true;
            bool removed_in_place = removed_ids.size > 0 &&
                model.remove_messages (removed_ids) == removed_ids.size;
            if (removed_in_place && selection != null) selection.unselect_all ();
            suppress_selection = was_suppressed;
            if (removed_in_place) {
                int remaining = (int) model.get_n_items ();
                message_count.label = remaining == 1 ? "1 message" : "%d messages".printf (remaining);
                mark_current_view_clean ();
                if (remaining == 0) no_messages ();
                return;
            }
        }
        reload (false, false, "", true);
    }

    public void refresh_after_mail_check () {
        if (model == null || query != "" || unread_filter.active) return;
        // A sync can change unread flags, ordering, and mailbox membership
        // even when the number of downloaded messages is unchanged. Reload
        // the active model so rows receive the repository's current Message
        // objects instead of only extending the old page snapshot.
        string preferred_id = "";
        var selected = selected_messages ();
        if (selected.size == 1) preferred_id = selected[0].id;
        reload (false, true, preferred_id, true);
    }
    public void set_sort (MessageSortMode mode) { sort_mode = mode; reload (true, false, "", true); }

    public void set_read_in_place (string id, bool read) {
        var row = bound_rows[id];
        if (row != null) row.set_read_in_place (read);
        if (model != null) model.set_cached_read_state (id, read);
    }

    public void set_flag_in_place (string id, bool flagged, string color = "") {
        var row = bound_rows[id];
        if (row != null) row.set_flag_in_place (flagged, color);
        if (model != null) model.set_cached_flag_state (id, flagged, color);
    }

    public bool remove_unflagged_messages (Gee.Collection<string> ids) {
        if (mailbox_id != "unified-flagged" && mailbox_id != "flagged") return false;
        if (model == null || ids.size == 0 || model.remove_messages (ids) != ids.size) return false;
        int remaining = (int) model.get_n_items ();
        message_count.label = remaining == 1 ? "1 message" : "%d messages".printf (remaining);
        if (remaining == 0) no_messages ();
        return true;
    }

    public Message? first_message () {
        return model == null ? null : model.get_item (0) as Message;
    }

    public bool select_message (string id) {
        if (model == null || selection == null) return false;
        for (uint position = 0; position < model.get_n_items (); position++) {
            var message = model.get_item (position) as Message;
            if (message != null && message.id == id) {
                selection.select_item (position, true);
                // During initial/refresh rebinding the virtual model and
                // selection already exist while Gtk.ListView is intentionally
                // detached until the next idle turn. Selecting is still valid;
                // asking the unbound view to scroll would trigger a fatal GTK
                // assertion in QA builds.
                if (list.model != null && position < list.model.get_n_items ())
                    list.scroll_to (position, Gtk.ListScrollFlags.FOCUS, null);
                return true;
            }
        }
        return false;
    }

    public string adjacent_message_id_after_selection () {
        if (model == null || selection == null) return "";
        var selected = selection.get_selection ();
        if (selected.is_empty ()) return "";

        uint last = selected.get_maximum ();
        for (uint position = last + 1; position < model.get_n_items (); position++) {
            var message = model.get_item (position) as Message;
            if (message != null && !selected.contains (position)) return message.id;
        }

        uint first = selected.get_minimum ();
        for (int position = (int) first - 1; position >= 0; position--) {
            var message = model.get_item ((uint) position) as Message;
            if (message != null && !selected.contains ((uint) position)) return message.id;
        }
        return "";
    }

    public void activate_message (string id) {
        if (model == null) return;
        for (uint position = 0; position < model.get_n_items (); position++) {
            var message = model.get_item (position) as Message;
            if (message != null && message.id == id) {
                if (selection != null) selection.select_item (position, true);
                list.scroll_to (position, Gtk.ListScrollFlags.FOCUS, null);
                message_activated (message); return;
            }
        }
    }

    public void select_relative (int offset) {
        if (model == null || selection == null || model.get_n_items () == 0) return;
        var selected = selection.get_selection ();
        int current = selected.is_empty () ? 0 : (int) selected.get_minimum ();
        uint target = (uint) int.max (0, int.min ((int) model.get_n_items () - 1, current + offset));
        selection.select_item (target, true);
        list.scroll_to (target, Gtk.ListScrollFlags.FOCUS, null);
    }

    public Gee.List<Message> selected_messages () {
        var result = new Gee.ArrayList<Message> ();
        if (selection == null || model == null) return result;
        var selected = selection.get_selection ();
        Gtk.BitsetIter iterator = Gtk.BitsetIter ();
        uint position;
        if (iterator.init_first (selected, out position)) {
            do {
                var message = model.get_item (position) as Message;
                if (message != null) result.add (message);
            } while (iterator.next (out position));
        }
        return result;
    }

    public void select_all () {
        if (selection == null || model == null || model.get_n_items () == 0) return;
        select_multiple.active = true;
        var all = new Gtk.Bitset.range (0, model.get_n_items ());
        selection.set_selection (all, all);
    }

    public void clear_selection () {
        if (selection == null) return;
        var selected = selection.get_selection ();
        if (selected.is_empty ()) return;
        select_multiple.active = false;
        selection.unselect_all ();
    }

    public void finish_bulk_action () { select_multiple.active = false; }

    internal void qa_assert_single_selection () {
        var selected = selected_messages ();
        if (selected.size != 1)
            critical ("Removal selection QA expected one selected message, found %d",
                selected.size);
        int highlighted = 0;
        foreach (var row in bound_rows.values) {
            if (!row.qa_selection_style_matches ())
                critical ("Removal selection QA found stale row styling for %s",
                    row.message.id);
            if (row.qa_has_selection_style ()) highlighted++;
        }
        if (highlighted != 1)
            critical ("Removal selection QA expected one highlighted row, found %d",
                highlighted);
    }

    private void reload (bool notify_selection = true, bool preserve_selection = false,
                         string preferred_id = "", bool force_reload = false) {
        int64 started = DebugTrace.mark ();
        bool had_attached_rows = list.model != null && list.model.get_n_items () > 0;
        DebugTrace.log ("message-list", "reload begin mailbox=%s query=%s notify=%s preserve=%s preferred=%s".printf (
            mailbox_id, query, notify_selection.to_string (), preserve_selection.to_string (), preferred_id));
        // A bulk selection owns the selection model; preserving the reader's
        // single-message id must not collapse that range.
        string preserve_id = select_multiple.active ? "" : preferred_id;
        if (preserve_id == "" && preserve_selection && !select_multiple.active) {
            var previously_selected = selected_messages ();
            if (previously_selected.size == 1) preserve_id = previously_selected[0].id;
        }
        int total;
        try {
            total = query == "" ? repository.message_count (mailbox_id, "", unread_filter.active) :
                search_service.count (query, unread_filter.active, search_scope, mailbox_id);
        } catch (Error error) {
            show_status ("Search Unavailable",
                "The local mail index could not be searched. Try refreshing Mailficient.",
                "dialog-warning-symbolic");
            warning ("Cached-mail search failed: %s", error.message); return;
        }
        DebugTrace.log ("message-list", "reload count=%d mailbox=%s".printf (total, mailbox_id));
        bool unread_only = unread_filter.active;
        string current_query = query;
        string current_mailbox = mailbox_id;
        MessageSortMode current_sort = sort_mode;
        model = new VirtualMessageModel (total, (limit, offset) => {
            try {
                return current_query == "" ? repository.list_messages (current_mailbox, "",
                    limit, offset, unread_only, current_sort) :
                    search_service.search (current_query, limit, offset, unread_only, current_sort,
                        search_scope, current_mailbox);
            } catch (Error error) {
                warning ("Could not load a virtual mail page: %s".printf (error.message));
                return new Gee.ArrayList<Message> ();
            }
        });
        // Keep one ListView and replace only its selection model. Recreating
        // the view for every mailbox leaves factories and row state for each
        // visited favorite alive until GTK finishes tearing down the old
        // hierarchy. Leave the previous model attached while the replacement
        // is prepared below: configure_selection() installs it on the next
        // idle turn, and detaching here would paint an empty Inbox meanwhile.
        list_stack.set_visible_child (list);
        mailbox_loaded = true;
        // Build an owned title before handing it to GTK. Vala can otherwise
        // lower the concatenating branch of a nested conditional to a
        // short-lived temporary, which showed up as corrupted text during a
        // live search even though the result set itself was correct.
        string visible_title;
        if (query == "") visible_title = mailbox_name;
        else if (search_scope == MailSearchScope.CURRENT_FOLDER)
            visible_title = "Search in %s".printf (mailbox_name);
        else if (search_scope == MailSearchScope.CURRENT_ACCOUNT)
            visible_title = "Search This Account";
        else visible_title = "Search All Mail";
        mailbox_title.label = visible_title;
        message_count.label = total == 1 ? "1 message" : "%d messages".printf (total);
        local_queue = mailbox_id == CachedMailRepository.LOCAL_DRAFTS_ID ||
            mailbox_id == CachedMailRepository.LOCAL_OUTBOX_ID || mailbox_id == "drafts";
        suppress_selection = !notify_selection || local_queue || preserve_id != "";
        configure_selection (notify_selection && !local_queue && preserve_id == "", preserve_id,
            notify_selection && !local_queue && preserve_id == "");
        if (Environment.get_variable ("MAILFICIENT_QA") == "1" &&
            had_attached_rows && list.model == null)
            critical ("Message list detached its nonempty model during refresh");
        if (total > 0) {
            content_stack.visible_child_name = "messages";
        } else {
            show_status (unread_filter.active ? "No Unread Messages" : "No Messages",
                unread_filter.active ? "All messages here have been read." :
                    (query == "" ? "This folder is empty." : "Try a different search."),
                "mail-read-symbolic");
            no_messages ();
        }
        suppress_selection = false;
        DebugTrace.duration ("message-list", "reload complete", started);
    }

    private void configure_selection (bool select_first = false, string preserve_id = "",
                                      bool announce = false) {
        if (model == null) return;
        var next_model = model;
        var next_selection = new Gtk.MultiSelection (next_model);
        selection = next_selection;
        next_selection.selection_changed.connect ((position, count) => {
            if (suppress_selection) return;
            var selected = selected_messages ();
            selection_changed (selected);
            // Local drafts/outbox messages do not need read-state handling,
            // but they still must announce selection so the reading pane
            // follows the row the user clicked.
            if (!select_multiple.active && selected.size == 1)
                message_selected (selected[0]);
        });
        // Keep the currently painted rows until next_selection is ready to be
        // installed. Assigning the replacement directly in the idle callback
        // makes the model change atomic from the frame clock's perspective.
        Idle.add (() => {
            if (model != next_model || selection != next_selection) return Source.REMOVE;
            list.model = next_selection;
            suppress_selection = !announce;
            if (preserve_id != "") {
                for (uint position = 0; position < next_model.get_n_items (); position++) {
                    var message = next_model.get_item (position) as Message;
                    if (message != null && message.id == preserve_id) {
                        next_selection.select_item (position, true);
                        list.scroll_to (position, Gtk.ListScrollFlags.NONE, null);
                        break;
                    }
                }
            } else if (select_first && next_model.get_n_items () > 0)
                next_selection.select_item (0, true);
            else
                next_selection.unselect_all ();
            suppress_selection = false;
            if (announce) selection_changed (selected_messages ());
            return Source.REMOVE;
        });
    }

    private void refresh_row_widgets () {
        // Reassigning the existing selection model makes ListView rebind its
        // rows without disturbing the selected range.
        var current = selection;
        list.model = null;
        list.model = current;
    }

    private void show_status (string title, string description, string icon_name) {
        empty_status.icon_name = icon_name; empty_status.title = title;
        empty_status.description = description;
        if (query.strip () != "") {
            empty_action.label = "Clear Search";
            Accessibility.label (empty_action, "Clear this mail search");
        } else if (unread_filter.active) {
            empty_action.label = "Show All Messages";
            Accessibility.label (empty_action, "Show read and unread messages");
        } else {
            empty_action.label = "Get Mail";
            Accessibility.label (empty_action, "Check for new mail");
        }
        content_stack.visible_child_name = "empty";
    }
}
}
