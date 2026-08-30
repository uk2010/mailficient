namespace Mailficient {
/*
 * Applies Mailficient's color family independently of light/dark appearance.
 * The stylesheet is display-wide so native popovers and newly constructed
 * widgets use the same palette. Every supported family defines the same
 * semantic surface variables; root classes select the active values while
 * shared dialog/control rules stay consistent across every selected color.
 */
public class ColorThemeController : Object {
    private Gtk.CssProvider family_provider = new Gtk.CssProvider ();
    private Gtk.CssProvider gray_provider = new Gtk.CssProvider ();
    private Gtk.CssProvider custom_provider = new Gtk.CssProvider ();
    private string current_theme = "blue";
    private string current_color = "#3584e4";

    public ColorThemeController () {
        // Adw.Dialog and AlertDialog are not Gtk.Window toplevels. Keep the
        // shared family/surface stylesheet installed for the lifetime of the
        // process so those in-window surfaces receive their host's palette.
        family_provider.load_from_resource ("/com/local/Mailficient/color-family-base.css");
        Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (),
            family_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        gray_provider.load_from_string ("");
        Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (),
            gray_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
        custom_provider.load_from_string ("");
        Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (),
            custom_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3);
        Adw.StyleManager.get_default ().notify["dark"].connect (() =>
            refresh_windows ());
    }

    public string theme { get { return current_theme; } }

    public void apply (string requested_theme, string requested_color = "#3584e4") {
        current_theme = canonicalize (requested_theme);
        current_color = canonicalize_color (requested_color);
        // Blue keeps the established base artwork and accents. Gray's higher
        // priority sheet remaps those accents. Custom uses those comprehensive
        // selectors too, then replaces their semantic palette with values
        // derived from the color chosen by the user.
        if (current_theme == "gray" || current_theme == "custom")
            gray_provider.load_from_resource ("/com/local/Mailficient/color-themes.css");
        else
            gray_provider.load_from_string ("");
        if (current_theme == "custom")
            custom_provider.load_from_string (custom_palette_css (current_color));
        else
            custom_provider.load_from_string ("");
        refresh_windows ();
    }

    private void refresh_windows () {
        foreach (var window in Gtk.Window.list_toplevels ())
            apply_to_window (window);
    }

    public void apply_to_window (Gtk.Window window) {
        window.remove_css_class ("color-theme-blue");
        window.remove_css_class ("color-theme-gray");
        window.remove_css_class ("color-theme-custom");
        window.remove_css_class ("color-theme-dark");
        if (current_theme == "custom") {
            // The Gray family sheet is the complete retint layer. Keep its
            // selector class and override only the generated semantic colors.
            window.add_css_class ("color-theme-gray");
            window.add_css_class ("color-theme-custom");
        } else {
            window.add_css_class ("color-theme-" + current_theme);
        }
        if (Adw.StyleManager.get_default ().dark)
            window.add_css_class ("color-theme-dark");
    }

    public static string canonicalize (string requested_theme) {
        return requested_theme == "gray" || requested_theme == "custom" ?
            requested_theme : "blue";
    }

    private static string canonicalize_color (string requested_color) {
        string color = requested_color.strip ();
        if (!Regex.match_simple ("^#[0-9A-Fa-f]{6}$", color))
            return "#3584e4";
        return color.down ();
    }

    private static string foreground_for (string color, bool dark_palette = false) {
        uint red = uint.parse (color.substring (1, 2), 16);
        uint green = uint.parse (color.substring (3, 2), 16);
        uint blue = uint.parse (color.substring (5, 2), 16);
        // This perceived-brightness split preserves white on the established
        // blue/gray accents and switches light custom colors to dark ink. The
        // dark palette gently lightens very dark picks, so account for that
        // actual control color when selecting its foreground.
        uint brightness = red * 299 + green * 587 + blue * 114;
        if (dark_palette)
            brightness = (brightness * 82 + 255000 * 18) / 100;
        return brightness >= 150000 ? "#18212b" : "#ffffff";
    }

    private static string custom_palette_css (string color) {
        string foreground = foreground_for (color);
        string dark_foreground = foreground_for (color, true);
        var css = new StringBuilder ();
        css.append ("window.color-theme-custom {");
        css.append ("--accent-color:color-mix(in srgb,"); css.append (color);
        css.append (" 72%,#18212b);");
        css.append ("--accent-bg-color:"); css.append (color); css.append (";");
        css.append ("--accent-fg-color:"); css.append (foreground); css.append (";");
        css.append ("--window-bg-color:color-mix(in srgb,#f7f9fb 94%,"); css.append (color); css.append (");");
        css.append ("--window-fg-color:#26313d;");
        css.append ("--view-bg-color:color-mix(in srgb,#ffffff 97%,"); css.append (color); css.append (");");
        css.append ("--view-fg-color:#26313d;");
        css.append ("--headerbar-bg-color:color-mix(in srgb,#f1f3f5 89%,"); css.append (color); css.append (");");
        css.append ("--headerbar-fg-color:#26313d;");
        css.append ("--card-bg-color:color-mix(in srgb,#ffffff 95%,"); css.append (color); css.append (");");
        css.append ("--card-fg-color:#26313d;");
        css.append ("--popover-bg-color:color-mix(in srgb,#ffffff 94%,"); css.append (color); css.append (");");
        css.append ("--popover-fg-color:#26313d;");
        css.append ("--dialog-bg-color:color-mix(in srgb,#f6f7f9 93%,"); css.append (color); css.append (");");
        css.append ("--dialog-fg-color:#26313d;");
        css.append ("--sidebar-bg-color:color-mix(in srgb,#edf0f3 87%,"); css.append (color); css.append (");");
        css.append ("--sidebar-fg-color:#26313d;");
        css.append ("--mailficient-theme-window:var(--window-bg-color);");
        css.append ("--mailficient-theme-header:var(--headerbar-bg-color);");
        css.append ("--mailficient-theme-sidebar:var(--sidebar-bg-color);");
        css.append ("--mailficient-theme-list:color-mix(in srgb,#f8fafc 94%,"); css.append (color); css.append (");");
        css.append ("--mailficient-theme-view:var(--view-bg-color);");
        css.append ("--mailficient-theme-card:var(--card-bg-color);");
        css.append ("--mailficient-theme-raised:color-mix(in srgb,#ffffff 91%,"); css.append (color); css.append (");");
        css.append ("--mailficient-theme-border:rgba(38,49,61,.13);");
        css.append ("--mailficient-theme-wash:alpha("); css.append (color); css.append (",.09);");
        css.append ("--mailficient-theme-wash-strong:alpha("); css.append (color); css.append (",.17);");
        css.append ("}");

        css.append ("window.color-theme-custom.color-theme-dark {");
        css.append ("--accent-color:color-mix(in srgb,"); css.append (color); css.append (" 52%,white);");
        css.append ("--accent-bg-color:color-mix(in srgb,"); css.append (color); css.append (" 82%,white);");
        css.append ("--accent-fg-color:"); css.append (dark_foreground); css.append (";");
        css.append ("--window-bg-color:color-mix(in srgb,#101419 91%,"); css.append (color); css.append (");");
        css.append ("--window-fg-color:#eef3f8;");
        css.append ("--view-bg-color:color-mix(in srgb,#11161c 93%,"); css.append (color); css.append (");");
        css.append ("--view-fg-color:#eef3f8;");
        css.append ("--headerbar-bg-color:color-mix(in srgb,#20262d 84%,"); css.append (color); css.append (");");
        css.append ("--headerbar-fg-color:#f3f7fb;");
        css.append ("--card-bg-color:color-mix(in srgb,#20262d 88%,"); css.append (color); css.append (");");
        css.append ("--card-fg-color:#eef3f8;");
        css.append ("--popover-bg-color:color-mix(in srgb,#242a32 87%,"); css.append (color); css.append (");");
        css.append ("--popover-fg-color:#eef3f8;");
        css.append ("--dialog-bg-color:color-mix(in srgb,#1b2128 89%,"); css.append (color); css.append (");");
        css.append ("--dialog-fg-color:#eef3f8;");
        css.append ("--sidebar-bg-color:color-mix(in srgb,#192028 86%,"); css.append (color); css.append (");");
        css.append ("--sidebar-fg-color:#eef3f8;");
        css.append ("--mailficient-theme-window:var(--window-bg-color);");
        css.append ("--mailficient-theme-header:var(--headerbar-bg-color);");
        css.append ("--mailficient-theme-sidebar:var(--sidebar-bg-color);");
        css.append ("--mailficient-theme-list:color-mix(in srgb,#151b22 91%,"); css.append (color); css.append (");");
        css.append ("--mailficient-theme-view:var(--view-bg-color);");
        css.append ("--mailficient-theme-card:var(--card-bg-color);");
        css.append ("--mailficient-theme-raised:color-mix(in srgb,#29313a 84%,"); css.append (color); css.append (");");
        css.append ("--mailficient-theme-border:rgba(238,243,248,.13);");
        css.append ("--mailficient-theme-wash:alpha("); css.append (color); css.append (",.12);");
        css.append ("--mailficient-theme-wash-strong:alpha("); css.append (color); css.append (",.21);");
        css.append ("}");

        // The Light/Dark/System chooser contains miniature surfaces. Gray's
        // fixed preview swatches are replaced too, so the settings page itself
        // demonstrates both generated palettes for the selected color.
        css.append ("window.color-theme-custom .appearance-preview-sidebar{");
        css.append ("background:color-mix(in srgb,#edf0f3 84%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-preview-line-primary{");
        css.append ("background:color-mix(in srgb,#79838e 62%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-option-preview{");
        css.append ("background:color-mix(in srgb,#11161c 91%,"); css.append (color);
        css.append (");border-color:rgba(224,226,229,.18);}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-preview-header{");
        css.append ("background:color-mix(in srgb,#29313a 82%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-preview-body{");
        css.append ("background:color-mix(in srgb,#151b22 91%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-preview-sidebar{");
        css.append ("background:color-mix(in srgb,#192028 85%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-preview-line{");
        css.append ("background:color-mix(in srgb,#66717c 72%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-dark .appearance-preview-line-primary{");
        css.append ("background:color-mix(in srgb,#a3adb7 64%,"); css.append (color); css.append (");}");
        css.append ("window.color-theme-custom .appearance-option-system .appearance-preview-header{");
        css.append ("background:linear-gradient(to right,color-mix(in srgb,#f1f3f5 89%,"); css.append (color);
        css.append (") 0%,color-mix(in srgb,#f1f3f5 89%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#29313a 82%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#29313a 82%,"); css.append (color); css.append (") 100%);}");
        css.append ("window.color-theme-custom .appearance-option-system .appearance-preview-body{");
        css.append ("background:linear-gradient(to right,color-mix(in srgb,#ffffff 97%,"); css.append (color);
        css.append (") 0%,color-mix(in srgb,#ffffff 97%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#151b22 91%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#151b22 91%,"); css.append (color); css.append (") 100%);}");
        css.append ("window.color-theme-custom .appearance-option-system .appearance-preview-sidebar{");
        css.append ("background:linear-gradient(to right,color-mix(in srgb,#edf0f3 84%,"); css.append (color);
        css.append (") 0%,color-mix(in srgb,#edf0f3 84%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#192028 85%,"); css.append (color);
        css.append (") 50%,color-mix(in srgb,#192028 85%,"); css.append (color); css.append (") 100%);}");
        return css.str;
    }
}
}
