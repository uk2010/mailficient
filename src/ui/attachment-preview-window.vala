namespace Mailficient {
public class AttachmentPreviewWindow : Adw.Window {
    private const int64 MAX_TEXT_PREVIEW_BYTES = 2 * 1024 * 1024;
    private const int64 MAX_PREVIEW_BYTES = 50 * 1024 * 1024;
    private Attachment attachment;
    private Gtk.Box preview_area = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

    public AttachmentPreviewWindow (Gtk.Window parent, Attachment attachment) {
        Object (title: attachment.name, transient_for: parent, modal: true,
            default_width: 900, default_height: 680);
        this.attachment = attachment;

        var toolbar = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.title_widget = build_title ();
        toolbar.add_top_bar (header);
        preview_area.vexpand = true;
        preview_area.hexpand = true;
        toolbar.content = preview_area;
        content = toolbar;

        show_loading ();
        load_preview.begin ();
    }

    private Gtk.Widget build_title () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var name = new Gtk.Label (attachment.name);
        name.ellipsize = Pango.EllipsizeMode.MIDDLE;
        name.max_width_chars = 48;
        name.add_css_class ("heading");
        var details = new Gtk.Label (attachment.formatted_size ());
        details.add_css_class ("dim-label");
        box.append (name);
        box.append (details);
        return box;
    }

    private File source_file () throws MailError {
        if (attachment.path.has_prefix ("resource:///com/local/Mailficient/"))
            return File.new_for_uri (attachment.path);
        if (attachment.path.contains ("://"))
            throw new MailError.ATTACHMENT ("The attachment source is not trusted");
        if (attachment.path == "")
            throw new MailError.ATTACHMENT ("The attachment has not been downloaded");
        return File.new_for_path (attachment.path);
    }

    private async void load_preview () {
        try {
            var file = source_file ();
            var kind = AttachmentSafety.preview_kind (attachment.content_type, attachment.name);
            var info = yield file.query_info_async (FileAttribute.STANDARD_SIZE + "," +
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_CONTENT_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
            if (info.get_file_type () != FileType.REGULAR)
                throw new MailError.ATTACHMENT ("Only regular files can be previewed");
            if ((int64) info.get_size () > MAX_PREVIEW_BYTES)
                throw new MailError.ATTACHMENT ("Previews are limited to files smaller than 50 MB");
            var detected_kind = AttachmentSafety.preview_kind (info.get_content_type () ?? "", attachment.name);
            if (kind == AttachmentPreviewKind.NONE || detected_kind != kind)
                throw new MailError.ATTACHMENT ("The file contents do not match a safely previewable type");
            var stream = yield file.read_async (Priority.DEFAULT, null);
            uint8[] prefix = new uint8[16];
            ssize_t prefix_length = yield stream.read_async (prefix, Priority.DEFAULT, null);
            yield stream.close_async (Priority.DEFAULT, null);
            if (prefix_length < 0 || !AttachmentSafety.preview_signature_matches (kind,
                    info.get_content_type () ?? "", prefix, (size_t) prefix_length))
                throw new MailError.ATTACHMENT ("The file signature does not match its declared type");
            switch (kind) {
                case AttachmentPreviewKind.IMAGE:
                    show_image (file);
                    break;
                case AttachmentPreviewKind.TEXT:
                    yield show_text (file, (int64) info.get_size ());
                    break;
                case AttachmentPreviewKind.PDF:
                    show_pdf (file);
                    break;
                default:
                    show_error ("Preview unavailable", "This file type can be saved, but it is not opened inside Mailficient.");
                    break;
            }
        } catch (Error error) {
            show_error ("Couldn’t preview attachment", error.message);
        }
    }

    private void show_image (File file) {
        clear ();
        var picture = new Gtk.Picture.for_file (file);
        picture.content_fit = Gtk.ContentFit.CONTAIN;
        picture.can_shrink = true;
        picture.set_margin_top (24);
        picture.set_margin_bottom (24);
        picture.set_margin_start (24);
        picture.set_margin_end (24);
        preview_area.append (picture);
    }

    private async void show_text (File file, int64 size) throws Error {
        if (size > MAX_TEXT_PREVIEW_BYTES)
            throw new MailError.ATTACHMENT ("Text previews are limited to files smaller than 2 MB");
        uint8[] contents;
        string? etag;
        yield file.load_contents_async (null, out contents, out etag);
        string text = (string) contents;
        if (!text.validate ())
            throw new MailError.ATTACHMENT ("This text attachment is not valid UTF-8");

        clear ();
        var view = new Gtk.TextView ();
        view.editable = false;
        view.cursor_visible = false;
        view.monospace = attachment.content_type != "text/plain";
        view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
        view.left_margin = 24;
        view.right_margin = 24;
        view.top_margin = 24;
        view.bottom_margin = 24;
        view.buffer.text = text;
        var scroller = new Gtk.ScrolledWindow ();
        scroller.vexpand = true;
        scroller.child = view;
        preview_area.append (scroller);
    }

    private void show_pdf (File file) {
        clear ();
        var settings = new WebKit.Settings ();
        settings.enable_javascript = false;
        settings.enable_html5_database = false;
        settings.enable_html5_local_storage = false;
        settings.enable_webgl = false;
        var view = new WebKit.WebView ();
        view.settings = settings;
        view.vexpand = true;
        view.permission_request.connect ((request) => { request.deny (); return true; });
        string allowed_uri = file.get_uri ();
        view.decide_policy.connect ((decision, type) => {
            if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION) return false;
            var navigation = (WebKit.NavigationPolicyDecision) decision;
            string uri = navigation.navigation_action.get_request ().get_uri ();
            if (uri == allowed_uri || uri.has_prefix ("about:")) return false;
            decision.ignore ();
            return true;
        });
        view.load_uri (allowed_uri);
        preview_area.append (view);
    }

    private void show_loading () {
        clear ();
        var status = new Adw.StatusPage ();
        status.title = "Loading Preview";
        var spinner = new Gtk.Spinner ();
        spinner.spinning = true;
        status.child = spinner;
        status.vexpand = true;
        preview_area.append (status);
    }

    private void show_error (string title, string description) {
        clear ();
        var status = new Adw.StatusPage ();
        status.icon_name = "dialog-warning-symbolic";
        status.title = title;
        status.description = description;
        status.vexpand = true;
        preview_area.append (status);
    }

    private void clear () {
        while (preview_area.get_first_child () != null)
            preview_area.remove ((Gtk.Widget) preview_area.get_first_child ());
    }
}
}
