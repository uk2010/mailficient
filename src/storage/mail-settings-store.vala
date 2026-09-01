namespace Mailficient {
public class MailSettingsStore : Object {
    public signal void changed (string key);
    private const uint TOOLBAR_PERSISTENCE_RETRY_MILLISECONDS = 50;
    private CacheDatabase cache;
    private string cached_toolbar_layout = ToolbarLayout.DEFAULT_LAYOUT;
    private string cached_toolbar_display_mode = "icons";
    private bool cached_toolbar_layout_percentages_migrated;
    private string pending_toolbar_layout = "";
    private string pending_toolbar_display_mode = "";
    private string pending_toolbar_layout_percentages_migrated = "";
    private uint toolbar_persistence_source;

    public MailSettingsStore (CacheDatabase cache) {
        this.cache = cache;
        string stored_layout = get_string (
            "toolbar-layout", ToolbarLayout.DEFAULT_LAYOUT);
        bool migrate_legacy_layout = ToolbarLayout.is_legacy_default (
            stored_layout);
        cached_toolbar_layout = migrate_legacy_layout ?
            ToolbarLayout.DEFAULT_LAYOUT : stored_layout;
        cached_toolbar_display_mode = canonical_toolbar_display_mode (
            get_string ("toolbar-display-mode", "icons"));
        cached_toolbar_layout_percentages_migrated = get_bool (
            "toolbar-layout-percentages-migrated", false);

        // Preserve the existing exact-default migration without ever making a
        // later toolbar getter perform storage I/O.
        if (migrate_legacy_layout)
            queue_toolbar_preference_persistence (
                "toolbar-layout", cached_toolbar_layout);
    }

    public bool notifications_enabled {
        get { return get_bool ("notifications-enabled", true); }
        set { set_bool ("notifications-enabled", value); }
    }

    public bool sync_on_startup {
        get { return get_bool ("sync-on-startup", true); }
        set { set_bool ("sync-on-startup", value); }
    }

    public bool group_messages {
        get { return get_bool ("group-messages", true); }
        set { set_bool ("group-messages", value); }
    }

    public bool always_show_images {
        get { return get_bool ("always-show-images", false); }
        set { set_bool ("always-show-images", value); }
    }

    public bool full_html_formatting {
        get { return get_bool ("full-html-formatting", false); }
        set { set_bool ("full-html-formatting", value); }
    }

    public bool spellcheck_enabled {
        get { return get_bool ("spellcheck-enabled", true); }
        set { set_bool ("spellcheck-enabled", value); }
    }

    public bool undo_send_enabled {
        get { return get_bool ("undo-send-enabled", true); }
        set { set_bool ("undo-send-enabled", value); }
    }

    public int undo_send_seconds {
        get { return clamp_int ((int) get_double ("undo-send-seconds", 10), 5, 30); }
        set { set_double ("undo-send-seconds", clamp_int (value, 5, 30)); }
    }

    public string appearance {
        owned get {
            string value = get_string ("appearance", "system");
            return value == "light" || value == "dark" ? value : "system";
        }
        set {
            set_string ("appearance",
                value == "light" || value == "dark" ? value : "system");
        }
    }

    public string color_theme {
        owned get {
            string value = get_string ("color-theme", "blue");
            return value == "gray" || value == "custom" ? value : "blue";
        }
        set {
            set_string ("color-theme",
                value == "gray" || value == "custom" ? value : "blue");
        }
    }

    /*
     * Blue and Gray were the original fixed color families. Keep reading
     * those exact colors so existing preferences migrate without a visual
     * change. Choosing a color stores it as the custom family in one logical
     * update, which prevents observers from briefly applying a stale color.
     */
    public string app_color {
        owned get {
            switch (color_theme) {
            case "gray": return "#70767d";
            case "custom":
                return canonical_app_color (get_string ("app-color", "#3584e4"));
            default: return "#3584e4";
            }
        }
        set {
            string color = canonical_app_color (value);
            try {
                cache.set_preference ("app-color", color);
                cache.set_preference ("color-theme", "custom");
                changed ("color-theme");
            } catch (Error error) {
                warning ("Could not save app color preference: %s", error.message);
            }
        }
    }

    private static string canonical_app_color (string value) {
        string color = value.strip ();
        if (!Regex.match_simple ("^#[0-9A-Fa-f]{6}$", color))
            return "#3584e4";
        return color.down ();
    }

    public int sync_interval_minutes {
        get { return normalize_sync_interval ((int) get_double ("sync-interval-minutes", 5)); }
        set { set_double ("sync-interval-minutes", normalize_sync_interval (value)); }
    }

    public double mailbox_pane_width {
        get {
            double value = get_double ("mailbox-pane-width", 238);
            // Migrate the former shipped default without overwriting a user's
            // genuinely customized width.
            if (value >= 281.5 && value <= 282.5) value = 238;
            return clamp_double (value, 190, 320);
        }
        set { set_double ("mailbox-pane-width", clamp_double (value, 190, 320)); }
    }

    public double message_pane_width {
        get {
            double value = get_double ("message-pane-width", 340);
            if (value >= 557.5 && value <= 558.5) value = 340;
            return clamp_double (value, 300, 520);
        }
        set { set_double ("message-pane-width", clamp_double (value, 300, 520)); }
    }

    public bool compact_pane_widths_migrated {
        get { return get_bool ("compact-pane-widths-migrated", false); }
        set { set_bool ("compact-pane-widths-migrated", value); }
    }

    public int window_width {
        get { return clamp_int ((int) get_double ("window-width", 1180), 480, 3840); }
        set { set_double ("window-width", clamp_int (value, 480, 3840)); }
    }

    public int window_height {
        get { return clamp_int ((int) get_double ("window-height", 800), 480, 2160); }
        set { set_double ("window-height", clamp_int (value, 480, 2160)); }
    }

    public bool window_maximized {
        get { return get_bool ("window-maximized", true); }
        set { set_bool ("window-maximized", value); }
    }

    public bool sidebar_visible {
        get { return get_bool ("sidebar-visible", true); }
        set { set_bool ("sidebar-visible", value); }
    }

    public bool onboarding_completed {
        get { return get_bool ("onboarding-completed", false); }
        set { set_bool ("onboarding-completed", value); }
    }

    public string selected_mailbox_id {
        owned get { return get_string ("selected-mailbox-id", ""); }
        set { set_string ("selected-mailbox-id", value); }
    }

    // Gtk's portal can otherwise reuse an unrelated application's most recent
    // location (commonly Pictures/Screenshots). Mailficient keeps one shared
    // location for opening, attaching, and exporting so each dialog resumes
    // where the user last completed a file operation. Downloads is the calm,
    // predictable first-use fallback requested by desktop mail users.
    public File file_dialog_initial_folder () {
        string uri = get_string ("last-file-dialog-folder-uri", "").strip ();
        if (uri != "") {
            var previous = File.new_for_uri (uri);
            // A non-native URI was already accepted by the desktop portal;
            // do not synchronously contact a possibly offline GVfs mount on
            // the GTK thread merely to seed the next chooser.
            if (!previous.is_native () ||
                previous.query_file_type (FileQueryInfoFlags.NONE, null) ==
                FileType.DIRECTORY) return previous;
        }
        string? downloads = Environment.get_user_special_dir (UserDirectory.DOWNLOAD);
        if (downloads != null && downloads != "") {
            var fallback = File.new_for_path (downloads);
            if (fallback.query_file_type (FileQueryInfoFlags.NONE, null) ==
                FileType.DIRECTORY) return fallback;
        }
        return File.new_for_path (Environment.get_home_dir ());
    }

    public void remember_file_dialog_selection (File selection) {
        var parent = selection.get_parent ();
        if (parent == null) return;
        set_string ("last-file-dialog-folder-uri", parent.get_uri ());
    }

    public string message_sort {
        owned get {
            string value = get_string ("message-sort", "newest");
            switch (value) {
            case "oldest": case "sender": case "subject": case "unread": case "flagged":
                return value;
            default: return "newest";
            }
        }
        set { set_string ("message-sort", value); }
    }

    public string toolbar_layout {
        owned get { return cached_toolbar_layout; }
        set {
            string canonical = ToolbarLayout.serialize (ToolbarLayout.parse (value));
            if (canonical == "") canonical = ToolbarLayout.DEFAULT_LAYOUT;
            cached_toolbar_layout = canonical;
            changed ("toolbar-layout");
            queue_toolbar_preference_persistence ("toolbar-layout", canonical);
        }
    }

    public string toolbar_display_mode {
        owned get { return cached_toolbar_display_mode; }
        set {
            string canonical = canonical_toolbar_display_mode (value);
            cached_toolbar_display_mode = canonical;
            changed ("toolbar-display-mode");
            queue_toolbar_preference_persistence (
                "toolbar-display-mode", canonical);
        }
    }

    public bool toolbar_layout_percentages_migrated {
        get { return cached_toolbar_layout_percentages_migrated; }
        set {
            cached_toolbar_layout_percentages_migrated = value;
            changed ("toolbar-layout-percentages-migrated");
            queue_toolbar_preference_persistence (
                "toolbar-layout-percentages-migrated",
                value ? "true" : "false");
        }
    }

    public string preferences_page {
        owned get {
            string value = get_string ("preferences-page", "general");
            switch (value) {
            case "accounts": case "composing": case "junk": case "rules": case "vacation": case "privacy": return value;
            default: return "general";
            }
        }
        set {
            switch (value) {
            case "accounts": case "composing": case "junk": case "rules": case "vacation": case "privacy": set_string ("preferences-page", value); break;
            default: set_string ("preferences-page", "general"); break;
            }
        }
    }

    public void save_window_state (int width, int height, bool maximized) {
        if (!maximized) {
            window_width = width;
            window_height = height;
        }
        window_maximized = maximized;
    }

    public bool signature_enabled (string account_id) {
        return get_bool ("signature-enabled." + account_id, false);
    }

    public void set_signature_enabled (string account_id, bool enabled) {
        set_bool ("signature-enabled." + account_id, enabled);
    }

    public string signature (string account_id) {
        try { return cache.preference ("signature." + account_id); }
        catch (Error error) { warning ("Could not load signature preference: %s", error.message); return ""; }
    }

    public void set_signature (string account_id, string value) {
        string key = "signature." + account_id;
        try { cache.set_preference (key, value); changed (key); }
        catch (Error error) { warning ("Could not save signature preference: %s", error.message); }
    }

    private bool get_bool (string key, bool fallback) {
        try { return cache.preference (key, fallback ? "true" : "false") == "true"; }
        catch (Error error) { warning ("Could not load Boolean preference: %s", error.message); return fallback; }
    }

    private void set_bool (string key, bool value) {
        try { cache.set_preference (key, value ? "true" : "false"); changed (key); }
        catch (Error error) { warning ("Could not save Boolean preference: %s", error.message); }
    }

    private double get_double (string key, double fallback) {
        try {
            double value;
            return double.try_parse (cache.preference (key, fallback.to_string ()), out value) ? value : fallback;
        } catch (Error error) { warning ("Could not load numeric preference: %s", error.message); return fallback; }
    }

    private void set_double (string key, double value) {
        try { cache.set_preference (key, value.to_string ()); changed (key); }
        catch (Error error) { warning ("Could not save numeric preference: %s", error.message); }
    }

    private string get_string (string key, string fallback) {
        try { return cache.preference (key, fallback); }
        catch (Error error) { warning ("Could not load text preference: %s", error.message); return fallback; }
    }

    private void set_string (string key, string value) {
        try { cache.set_preference (key, value); changed (key); }
        catch (Error error) { warning ("Could not save text preference: %s", error.message); }
    }

    private static string canonical_toolbar_display_mode (string value) {
        switch (value) {
        case "icons":
        case "icons-text":
        case "text": return value;
        default: return "icons";
        }
    }

    private void queue_toolbar_preference_persistence (string key,
                                                       string value) {
        if (key == "toolbar-layout") {
            pending_toolbar_layout = value;
        } else if (key == "toolbar-display-mode") {
            pending_toolbar_display_mode = value;
        } else {
            pending_toolbar_layout_percentages_migrated = value;
        }
        retry_toolbar_preference (key, value);
        schedule_toolbar_persistence_retry ();
    }

    private string pending_toolbar_preference (string key) {
        if (key == "toolbar-layout") return pending_toolbar_layout;
        if (key == "toolbar-display-mode")
            return pending_toolbar_display_mode;
        return pending_toolbar_layout_percentages_migrated;
    }

    private void clear_pending_toolbar_preference (string key, string value) {
        if (pending_toolbar_preference (key) != value) return;
        if (key == "toolbar-layout") pending_toolbar_layout = "";
        else if (key == "toolbar-display-mode")
            pending_toolbar_display_mode = "";
        else pending_toolbar_layout_percentages_migrated = "";
    }

    private bool has_pending_toolbar_preferences () {
        return pending_toolbar_layout != "" ||
            pending_toolbar_display_mode != "" ||
            pending_toolbar_layout_percentages_migrated != "";
    }

    private void schedule_toolbar_persistence_retry () {
        if (!has_pending_toolbar_preferences () ||
            toolbar_persistence_source != 0)
            return;
        toolbar_persistence_source = Timeout.add (
            TOOLBAR_PERSISTENCE_RETRY_MILLISECONDS, () => {
                toolbar_persistence_source = 0;
                retry_toolbar_persistence ();
                return Source.REMOVE;
            });
    }

    private void retry_toolbar_persistence () {
        retry_toolbar_preference (
            "toolbar-layout", pending_toolbar_layout);
        retry_toolbar_preference (
            "toolbar-display-mode", pending_toolbar_display_mode);
        retry_toolbar_preference (
            "toolbar-layout-percentages-migrated",
            pending_toolbar_layout_percentages_migrated);
        schedule_toolbar_persistence_retry ();
    }

    private void retry_toolbar_preference (string key, string pending_value) {
        if (pending_value == "" ||
            pending_toolbar_preference (key) != pending_value) return;
        try {
            if (cache.try_set_preference (key, pending_value))
                clear_pending_toolbar_preference (key, pending_value);
        } catch (Error error) {
            warning ("Could not save toolbar preference: %s", error.message);
        }
    }

    private static double clamp_double (double value, double minimum, double maximum) {
        return double.max (minimum, double.min (maximum, value));
    }

    private static int clamp_int (int value, int minimum, int maximum) {
        return int.max (minimum, int.min (maximum, value));
    }

    private static int normalize_sync_interval (int value) {
        switch (value) {
        case 0: case 1: case 5: case 15: case 30: case 60: return value;
        default: return 5;
        }
    }
}
}
