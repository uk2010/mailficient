namespace Mailficient {
public class MessageList : Gtk.Box {
    public signal void message_selected (Message message);
    public signal void message_activated (Message message);
    public signal void selection_changed (Gee.List<Message> messages);
    public signal void no_messages ();
    private MailRepository repository;
    private MailSearchService search_service;
    private Gtk.ListView list;
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow ();
    private Gtk.Stack content_stack = new Gtk.Stack ();
    private Adw.StatusPage empty_status = new Adw.StatusPage ();
    private VirtualMessageModel? model;
    private Gtk.SelectionModel? selection;
    private string mailbox_id = "inbox";
    private string query = "";
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
        mailbox_title.xalign = 0; mailbox_title.add_css_class ("title-3"); labels.append (mailbox_title);
        message_count.xalign = 0; message_count.add_css_class ("dim-label"); message_count.add_css_class ("message-count"); labels.append (message_count);
        header.append (labels);
        unread_filter.icon_name = "mail-unread-symbolic";
        unread_filter.tooltip_text = "Show unread messages only";
        Accessibility.label (unread_filter, "Show unread messages only");
        unread_filter.toggled.connect (() => reload ()); header.append (unread_filter);
        select_multiple.icon_name = "object-select-symbolic";
        select_multiple.tooltip_text = "Select multiple messages (Shift-click for a range, Ctrl+A for all)";
        Accessibility.label (select_multiple, "Select multiple messages");
        // Multi-selection is always available through the standard Shift-click
        // and Ctrl-click gestures. This button only reveals checkboxes.
        select_multiple.toggled.connect (refresh_row_widgets);
        header.append (select_multiple);
        append (header); append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

        var factory = new Gtk.SignalListItemFactory ();
        factory.bind.connect ((object) => {
            var item = object as Gtk.ListItem;
            var message = item == null ? null : item.item as Message;
            if (item == null || message == null) return;
            item.child = new MessageRow (message, selection, item.position,
                select_multiple.active);
        });
        factory.unbind.connect ((object) => {
            var item = object as Gtk.ListItem;
            var row = item == null ? null : item.child as MessageRow;
            if (row != null) row.unbind_selection ();
            if (item != null) item.child = null;
        });
        list = new Gtk.ListView (null, factory);
        list.add_css_class ("boxed-list"); list.show_separators = true;
        list.activate.connect ((position) => {
            var message = model == null ? null : model.get_item (position) as Message;
            if (message != null) message_activated (message);
        });
        scroller.set_child (list); scroller.vexpand = true;
        content_stack.vexpand = true;
        content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        content_stack.transition_duration = 160;
        empty_status.vexpand = true;
        empty_status.add_css_class ("empty-state");
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

    public void show_mailbox (Mailbox mailbox) {
        int64 started = DebugTrace.mark ();
        bool already_loaded = mailbox_loaded && mailbox_id == mailbox.id && query == "" && !unread_filter.active;
        DebugTrace.log ("message-list", "show_mailbox begin mailbox=%s old=%s already_loaded=%s".printf (
            mailbox.id, mailbox_id, already_loaded.to_string ()));
        mailbox_id = mailbox.id; mailbox_name = mailbox.name; mailbox_title.label = mailbox.name;
        query = "";
        if (unread_filter.active) unread_filter.active = false;
        if (already_loaded) {
            content_stack.visible_child_name = model != null && model.get_n_items () > 0 ? "messages" : "empty";
            DebugTrace.duration ("message-list", "show_mailbox cached_complete", started);
            return;
        }
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

    public void refresh () { reload (); }

    public void refresh_preserving_selection (string preferred_id = "") {
        // An unread-only list is a reading queue. Repository changes caused by
        // opening its selected message must not immediately remove that row
        // from under the reader. Keep the snapshot until the filter is toggled.
        if (unread_filter.active) {
            return;
        }
        reload (true, true, preferred_id);
    }

    public void refresh_after_removal () {
        // Removal actions must rebuild the model before selecting the next
        // message. Selecting against the old model lets the selection callback
        // run while the deleted row is still present and can retarget the next
        // delete action to the wrong message.
        reload (false, false);
    }
    public void set_sort (MessageSortMode mode) { sort_mode = mode; reload (); }

    public void mark_read_in_place (string id) {
        if (model == null) return;
        for (uint position = 0; position < model.get_n_items (); position++) {
            var message = model.get_item (position) as Message;
            if (message != null && message.id == id) {
                message.unread = false;
                return;
            }
        }
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

    private void reload (bool notify_selection = true, bool preserve_selection = false,
                         string preferred_id = "") {
        int64 started = DebugTrace.mark ();
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
                search_service.count (query, unread_filter.active);
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
                    search_service.search (current_query, limit, offset, unread_only, current_sort);
            } catch (Error error) {
                warning ("Could not load a virtual mail page: %s", error.message);
                return new Gee.ArrayList<Message> ();
            }
        });
        mailbox_loaded = true;
        mailbox_title.label = query == "" ? mailbox_name : "Search Results";
        message_count.label = total == 1 ? "1 message" : "%d messages".printf (total);
        local_queue = mailbox_id == CachedMailRepository.LOCAL_DRAFTS_ID ||
            mailbox_id == CachedMailRepository.LOCAL_OUTBOX_ID || mailbox_id == "drafts";
        suppress_selection = !notify_selection || local_queue || preserve_id != "";
        configure_selection (notify_selection && !local_queue && preserve_id == "");
        if (total > 0) {
            content_stack.visible_child_name = "messages";
            if (preserve_id != "" && selection != null) {
                for (uint position = 0; position < model.get_n_items (); position++) {
                    var message = model.get_item (position) as Message;
                    if (message != null && message.id == preserve_id) {
                        selection.select_item (position, true);
                        list.scroll_to (position, Gtk.ListScrollFlags.NONE, null);
                        break;
                    }
                }
            } else if (notify_selection && !local_queue && selection != null)
                selection.select_item (0, true);
        } else {
            show_status (unread_filter.active ? "No Unread Messages" : "No Messages",
                unread_filter.active ? "All messages here have been read." :
                    (query == "" ? "This mailbox is empty." : "Try a different search."),
                "mail-read-symbolic");
            no_messages ();
        }
        suppress_selection = false;
        DebugTrace.duration ("message-list", "reload complete", started);
    }

    private void configure_selection (bool select_first = false) {
        if (model == null) return;
        selection = new Gtk.MultiSelection (model);
        selection.selection_changed.connect ((position, count) => {
            if (suppress_selection) return;
            var selected = selected_messages ();
            selection_changed (selected);
            if (!select_multiple.active && !local_queue && selected.size == 1)
                message_selected (selected[0]);
        });
        list.model = selection;
        if (select_first && model.get_n_items () > 0) selection.select_item (0, true);
        else selection.unselect_all ();
        if (!suppress_selection) selection_changed (selected_messages ());
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
        content_stack.visible_child_name = "empty";
    }
}
}
