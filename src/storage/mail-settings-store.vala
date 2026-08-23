namespace Mailficient {
public class MailSettingsStore : Object {
    public signal void changed (string key);
    private CacheDatabase cache;

    public MailSettingsStore (CacheDatabase cache) {
        this.cache = cache;
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
        get { return get_bool ("full-html-formatting", true); }
        set { set_bool ("full-html-formatting", value); }
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

    public int sync_interval_minutes {
        get { return normalize_sync_interval ((int) get_double ("sync-interval-minutes", 5)); }
        set { set_double ("sync-interval-minutes", normalize_sync_interval (value)); }
    }

    public double mailbox_pane_width {
        get { return clamp_double (get_double ("mailbox-pane-width", 240), 190, 420); }
        set { set_double ("mailbox-pane-width", clamp_double (value, 190, 420)); }
    }

    public double message_pane_width {
        get { return clamp_double (get_double ("message-pane-width", 380), 300, 620); }
        set { set_double ("message-pane-width", clamp_double (value, 300, 620)); }
    }

    public int window_width {
        get { return clamp_int ((int) get_double ("window-width", 1320), 640, 3840); }
        set { set_double ("window-width", clamp_int (value, 640, 3840)); }
    }

    public int window_height {
        get { return clamp_int ((int) get_double ("window-height", 820), 480, 2160); }
        set { set_double ("window-height", clamp_int (value, 480, 2160)); }
    }

    public bool window_maximized {
        get { return get_bool ("window-maximized", false); }
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
        owned get {
            return get_string ("toolbar-layout", ToolbarLayout.DEFAULT_LAYOUT);
        }
        set {
            set_string ("toolbar-layout",
                ToolbarLayout.serialize (ToolbarLayout.parse (value)));
        }
    }

    public bool toolbar_layout_percentages_migrated {
        get { return get_bool ("toolbar-layout-percentages-migrated", false); }
        set { set_bool ("toolbar-layout-percentages-migrated", value); }
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

    private static double clamp_double (double value, double minimum, double maximum) {
        return double.max (minimum, double.min (maximum, value));
    }

    private static int clamp_int (int value, int minimum, int maximum) {
        return int.max (minimum, int.min (maximum, value));
    }

    private static int normalize_sync_interval (int value) {
        switch (value) {
        case 0: case 5: case 15: case 30: case 60: return value;
        default: return 5;
        }
    }
}
}
