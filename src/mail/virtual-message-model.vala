namespace Mailficient {
internal delegate Gee.List<Message> MessagePageLoader (int limit, int offset);

// Represents the entire logical mailbox while retaining only a few database
// pages. Gtk.ListView independently recycles visible row widgets.
internal class VirtualMessageModel : Object, GLib.ListModel {
    // Load a small first page so switching from an empty smart mailbox can
    // paint the Inbox promptly. Additional rows are fetched as the user
    // scrolls, while the bounded page cache still keeps scrolling smooth.
    internal const int PAGE_SIZE = 40;
    internal const int MAX_CACHED_PAGES = 3;
    private uint item_count;
    private MessagePageLoader loader;
    private Gee.HashMap<int, Gee.ArrayList<Message>> pages =
        new Gee.HashMap<int, Gee.ArrayList<Message>> ();
    private Gee.ArrayList<int> page_usage = new Gee.ArrayList<int> ();
    internal int cached_page_count { get { return pages.size; } }

    public VirtualMessageModel (int item_count, owned MessagePageLoader loader) {
        this.item_count = (uint) int.max (0, item_count);
        this.loader = (owned) loader;
    }

    public Object? get_item (uint position) {
        if (position >= item_count) return null;
        int page_number = (int) position / PAGE_SIZE;
        var page = pages[page_number];
        if (page == null) {
            page = new Gee.ArrayList<Message> ();
            page.add_all (loader (PAGE_SIZE, page_number * PAGE_SIZE));
            pages[page_number] = page;
        }
        page_usage.remove (page_number); page_usage.add (page_number);
        while (page_usage.size > MAX_CACHED_PAGES) {
            int expired = page_usage.remove_at (0);
            pages.unset (expired);
        }
        int within_page = (int) position % PAGE_SIZE;
        return within_page < page.size ? page[within_page] : null;
    }

    public Type get_item_type () { return typeof (Message); }
    public uint get_n_items () { return item_count; }

    // State-only actions must never call get_item() for every logical row:
    // doing so turns a one-bit change into a synchronous load of the entire
    // mailbox. Update the bounded page cache only; unloaded pages will read
    // the durable value when GTK asks for them later.
    public void set_cached_read_state (string id, bool read) {
        foreach (var page in pages.values)
            foreach (var message in page)
                if (message.id == id) message.unread = !read;
    }

    public void set_cached_flag_state (string id, bool flagged, string color = "") {
        foreach (var page in pages.values) {
            foreach (var message in page) {
                if (message.id != id) continue;
                message.flagged = flagged;
                if (color != "") message.flag_color = color;
            }
        }
    }

    // Remove rows whose backing messages were moved or deleted. Only the
    // affected portion of the virtual list is invalidated; the rest of a
    // large mailbox stays painted and its pages remain available.
    public int remove_messages (Gee.Collection<string> ids) {
        if (ids.size == 0) return 0;
        var wanted = new Gee.HashSet<string> (); wanted.add_all (ids);
        var positions = new Gee.ArrayList<int> ();
        foreach (var page_number in pages.keys) {
            var page = pages[page_number];
            for (int offset = 0; offset < page.size; offset++) {
                var message = page[offset];
                if (message != null && wanted.contains (message.id))
                    positions.add (page_number * PAGE_SIZE + offset);
            }
        }
        if (positions.size != wanted.size) return 0;
        positions.sort ((left, right) => right - left);
        foreach (var position in positions) {
            item_count--;
            int affected_page = position / PAGE_SIZE;
            var expired_pages = new Gee.ArrayList<int> ();
            foreach (var page_number in pages.keys)
                if (page_number >= affected_page) expired_pages.add (page_number);
            foreach (var page_number in expired_pages) {
                pages.unset (page_number);
                page_usage.remove (page_number);
            }
            items_changed ((uint) position, 1, 0);
        }
        return positions.size;
    }

    // A successful mail check can add newer rows at the front of a mailbox.
    // Drop only the page cache; the list model keeps its existing items and
    // asks the loader for the new first page when GTK needs it.
    public bool add_new_items (int new_count) {
        if (new_count <= (int) item_count) return false;
        uint added = (uint) (new_count - (int) item_count);
        item_count = (uint) new_count;
        pages.clear (); page_usage.clear ();
        items_changed (0, 0, added);
        return true;
    }
}
}
