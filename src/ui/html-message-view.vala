namespace Mailficient {
public class HtmlMessageView : Gtk.Box {
    public signal void link_requested (string uri);
    public signal void layout_changed ();
    private signal void resources_settled ();
    private WebKit.WebView? web_view;
    private bool allow_remote_content;
    private ulong permission_handler;
    private ulong resource_handler;
    private ulong policy_handler;
    private ulong load_handler;
    private Cancellable? height_measurement;
    private uint display_generation;
    private WebKit.PrintOperation? print_operation;
    private bool document_loaded;
    private uint active_resources;

    public HtmlMessageView () {
        Object (orientation: Gtk.Orientation.VERTICAL);
        var settings = new WebKit.Settings ();
        // The document sanitizer and CSP still prohibit message scripts. The
        // engine is enabled only so the app can query the laid-out height.
        settings.enable_javascript = true;
        settings.enable_javascript_markup = false;
        settings.enable_html5_database = false;
        settings.enable_html5_local_storage = false;
        settings.enable_page_cache = false;
        settings.enable_webgl = false;
        settings.print_backgrounds = true;
        web_view = new WebKit.WebView ();
        web_view.set_settings (settings);
        web_view.focusable = false;
        web_view.hexpand = true;
        web_view.vexpand = true;
        web_view.set_size_request (0, 360);
        permission_handler = web_view.permission_request.connect ((request) => {
            request.deny ();
            return true;
        });
        resource_handler = web_view.resource_load_started.connect ((resource, request) => {
            secure_request (request);
            uint resource_generation = display_generation;
            active_resources++;
            bool settled = false;
            resource.finished.connect (() => {
                if (!settled) {
                    settled = true;
                    resource_finished (resource_generation);
                }
            });
            resource.failed.connect ((error) => {
                if (!settled) {
                    settled = true;
                    resource_finished (resource_generation);
                }
            });
        });
        policy_handler = web_view.decide_policy.connect ((decision, type) => {
            if (type == WebKit.PolicyDecisionType.NAVIGATION_ACTION) {
                var navigation = (WebKit.NavigationPolicyDecision) decision;
                string uri = navigation.navigation_action.get_request ().get_uri ();
                if (!uri.has_prefix ("about:")) {
                    decision.ignore ();
                    if (uri.has_prefix ("https://") || uri.has_prefix ("http://") || uri.has_prefix ("mailto:")) link_requested (uri);
                    return true;
                }
            }
            return false;
        });
        load_handler = web_view.load_changed.connect ((event) => {
            if (event == WebKit.LoadEvent.FINISHED) {
                document_loaded = true;
                measure_rendered_height.begin (display_generation);
                notify_resources_settled ();
            }
        });
        append (web_view);
    }

    public void display (string untrusted_html, bool allow_remote_content = false,
                         Gee.Iterable<Attachment>? attachments = null,
                         bool full_html_formatting = false,
                         string print_header_html = "") {
        this.allow_remote_content = allow_remote_content;
        string safe = HtmlSanitizer.sanitize (
            untrusted_html, allow_remote_content, full_html_formatting);
        if (attachments != null) safe = InlineContentResolver.resolve (safe, attachments);
        if (web_view != null) {
            display_generation++;
            document_loaded = false;
            active_resources = 0;
            if (height_measurement != null) height_measurement.cancel ();
            height_measurement = null;
            // Start compactly, then fit the WebView to the document's actual
            // laid-out height once WebKit has loaded images and styles.
            web_view.set_size_request (0, 360);
            web_view.load_html (HtmlContentPolicy.document (
                safe, allow_remote_content, print_header_html), "about:blank");
        }
    }

    public async void export_rendered_pdf (File destination) throws Error {
        var view = web_view;
        if (view == null) throw new IOError.CLOSED ("The rendered message is no longer available");
        if (print_operation != null) throw new IOError.PENDING ("A print operation is already active");
        yield wait_for_resources ();
        var operation = new WebKit.PrintOperation (view);
        var settings = new Gtk.PrintSettings ();
        settings.set_printer ("Print to File");
        settings.set (Gtk.PRINT_SETTINGS_OUTPUT_URI, destination.get_uri ());
        settings.set (Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf");
        operation.set_print_settings (settings);
        print_operation = operation;
        bool failed = false;
        operation.failed.connect ((error) => failed = true);
        operation.finished.connect (() => {
            export_rendered_pdf.callback ();
        });
        operation.print ();
        yield;
        if (print_operation == operation) print_operation = null;
        if (failed) throw new IOError.FAILED ("WebKit could not render the message for printing");
    }

    private void resource_finished (uint generation) {
        if (generation != display_generation) return;
        if (active_resources > 0) active_resources--;
        notify_resources_settled ();
    }

    private void notify_resources_settled () {
        if (document_loaded && active_resources == 0) resources_settled ();
    }

    private async void wait_for_resources () {
        if (document_loaded && active_resources == 0) return;
        bool resumed = false;
        ulong handler_id = 0;
        uint timeout_id = 0;
        handler_id = resources_settled.connect (() => {
            if (resumed) return;
            resumed = true;
            wait_for_resources.callback ();
        });
        timeout_id = Timeout.add (5000, () => {
            timeout_id = 0;
            if (!resumed) {
                resumed = true;
                wait_for_resources.callback ();
            }
            return Source.REMOVE;
        });
        yield;
        if (handler_id != 0) disconnect (handler_id);
        if (timeout_id != 0) Source.remove (timeout_id);
    }

    public bool qa_print_pdf (string path) {
        var view = web_view;
        if (view == null || print_operation != null) return false;
        var operation = new WebKit.PrintOperation (view);
        var settings = new Gtk.PrintSettings ();
        settings.set_printer ("Print to File");
        settings.set (Gtk.PRINT_SETTINGS_OUTPUT_URI,
            File.new_for_path (path).get_uri ());
        settings.set (Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf");
        operation.set_print_settings (settings);
        print_operation = operation;
        operation.finished.connect (() => {
            if (print_operation == operation) print_operation = null;
        });
        operation.print ();
        return true;
    }

    private async void measure_rendered_height (uint generation) {
        var view = web_view;
        if (view == null || generation != display_generation) return;
        var cancellable = new Cancellable ();
        height_measurement = cancellable;
        try {
            var result = yield view.evaluate_javascript (
                "Math.ceil(Math.max(document.body.scrollHeight,document.documentElement.scrollHeight))",
                -1, null, null, cancellable);
            if (web_view != view || generation != display_generation || !result.is_number ()) return;
            int rendered_height = (int) result.to_double ();
            view.set_size_request (0, int.max (360, int.min (12000, rendered_height + 1)));
            layout_changed ();
        } catch (IOError.CANCELLED error) {
            // A different message replaced this document.
        } catch (Error error) {
            warning ("Could not measure rendered email height: %s", error.message);
        } finally {
            if (height_measurement == cancellable) height_measurement = null;
        }
    }

    public void shutdown () {
        var view = web_view;
        if (view == null) return;
        display_generation++;
        if (height_measurement != null) height_measurement.cancel ();
        height_measurement = null;
        print_operation = null;
        // Each WebKit signal closure retains this HtmlMessageView. Without
        // explicitly breaking those cycles, changing messages leaves the old
        // WebView and its content process alive indefinitely.
        view.stop_loading ();
        if (permission_handler != 0) view.disconnect (permission_handler);
        if (resource_handler != 0) view.disconnect (resource_handler);
        if (policy_handler != 0) view.disconnect (policy_handler);
        if (load_handler != 0) view.disconnect (load_handler);
        permission_handler = resource_handler = policy_handler = load_handler = 0;
        remove (view);
        web_view = null;
    }

    private void secure_request (WebKit.URIRequest request) {
        string uri = request.get_uri ();
        if (!HtmlContentPolicy.allows_resource (uri, allow_remote_content)) request.set_uri ("about:blank");
    }
}
}
