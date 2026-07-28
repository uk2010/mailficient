namespace Mailficient {
internal delegate Gee.List<Message> MessagePageLoader (int limit, int offset);

// Represents the entire logical mailbox while retaining only a few database
// pages. Gtk.ListView independently recycles visible row widgets.
internal class VirtualMessageModel : Object, GLib.ListModel {
    internal const int PAGE_SIZE = 100;
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
}
}
