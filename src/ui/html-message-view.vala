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
    private ulong width_handler;
    private ulong termination_handler;
    private class ResourceSignals : Object {
        public WebKit.WebResource resource;
        public ulong finished_handler;
        public ulong failed_handler;

        public ResourceSignals (WebKit.WebResource resource) {
            this.resource = resource;
        }
    }
    private Gee.ArrayList<ResourceSignals> resource_signals = new Gee.ArrayList<ResourceSignals> ();
    private Cancellable? height_measurement;
    private uint display_generation;
    private WebKit.PrintOperation? print_operation;
    private bool document_loaded;
    private bool rendering_message;
    private bool recovering_renderer;
    private uint active_resources;
    private uint width_fit_source;
    private int layout_width;
    // The reader automatically fits each message to its available width.
    // Keep the user's browser-style zoom as a multiplier on top of that fit
    // so resizing the pane does not erase Ctrl +/- adjustments.
    private double user_zoom = 1.0;
    private const double MIN_USER_ZOOM = 0.5;
    private const double MAX_USER_ZOOM = 3.0;

    public HtmlMessageView () {
        Object (orientation: Gtk.Orientation.VERTICAL);
        set_size_request (0, -1);
        overflow = Gtk.Overflow.HIDDEN;
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
        web_view.hexpand = true; web_view.halign = Gtk.Align.FILL;
        web_view.vexpand = true;
        web_view.set_size_request (0, 360);
        width_handler = web_view.notify["width"].connect (() => {
            if (document_loaded) queue_fit_to_width ();
        });
        hexpand = true; halign = Gtk.Align.FILL;
        permission_handler = web_view.permission_request.connect ((request) => {
            request.deny ();
            return true;
        });
        resource_handler = web_view.resource_load_started.connect ((resource, request) => {
            secure_request (request);
            if (!rendering_message) return;
            uint resource_generation = display_generation;
            active_resources++;
            var signals = new ResourceSignals (resource);
            signals.finished_handler = resource.finished.connect (() => {
                settle_resource (signals, resource_generation);
            });
            signals.failed_handler = resource.failed.connect ((error) => {
                settle_resource (signals, resource_generation);
            });
            resource_signals.add (signals);
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
            if (rendering_message && event == WebKit.LoadEvent.FINISHED) {
                document_loaded = true;
                measure_rendered_height.begin (display_generation);
                notify_resources_settled ();
            }
        });
        termination_handler = web_view.web_process_terminated.connect ((reason) => {
            recover_from_web_process_termination (reason);
        });
        append (web_view);
    }

    // Retain the WebView for reuse by the reading pane. Replacing a document
    // is substantially cheaper than allocating another WebKit view for every
    // mailbox selection, while the resource handlers still need to be reset
    // between documents.
    public void reset_for_reuse (bool release_document = false) {
        var view = web_view;
        if (view == null) return;
        display_generation++;
        rendering_message = false;
        recovering_renderer = false;
        if (width_fit_source != 0) Source.remove (width_fit_source);
        width_fit_source = 0;
        if (height_measurement != null) height_measurement.cancel ();
        height_measurement = null;
        document_loaded = false;
        active_resources = 0;
        clear_resource_signals ();
        view.stop_loading ();
        // A pooled WebView otherwise retains the complete old document (and
        // decoded image surfaces) while a plain-text message is displayed.
        // Loading a tiny private page gives WebKit an explicit release edge.
        if (release_document) {
            allow_remote_content = false;
            view.load_html (HtmlContentPolicy.document ("", false), "about:blank");
        }
    }

    public void constrain_width (int width) {
        if (width <= 0 || web_view == null) return;
        layout_width = width;
        if (document_loaded) queue_fit_to_width ();
    }

    public void zoom_in () {
        user_zoom = double.min (MAX_USER_ZOOM, user_zoom * 1.1);
        queue_fit_to_width ();
    }

    public void zoom_out () {
        user_zoom = double.max (MIN_USER_ZOOM, user_zoom / 1.1);
        queue_fit_to_width ();
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
            rendering_message = false;
            recovering_renderer = false;
            document_loaded = false;
            active_resources = 0;
            web_view.zoom_level = 1.0;
            if (height_measurement != null) height_measurement.cancel ();
            height_measurement = null;
            clear_resource_signals ();
            web_view.stop_loading ();
            // Start compactly, then fit the WebView to the document's actual
            // laid-out height once WebKit has loaded images and styles.
            web_view.set_size_request (0, 360);
            rendering_message = true;
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

    private void settle_resource (ResourceSignals signals, uint generation) {
        if (!resource_signals.contains (signals)) return;
        // Keep the list's strong reference until both closures have released
        // their captures; Vala object parameters themselves are unowned.
        disconnect_resource_signals (signals);
        resource_signals.remove (signals);
        resource_finished (generation);
    }

    private static void disconnect_resource_signals (ResourceSignals signals) {
        ulong finished = signals.finished_handler;
        ulong failed = signals.failed_handler;
        signals.finished_handler = 0;
        signals.failed_handler = 0;
        if (finished != 0) signals.resource.disconnect (finished);
        if (failed != 0) signals.resource.disconnect (failed);
    }

    private void clear_resource_signals () {
        while (resource_signals.size > 0) {
            var signals = resource_signals.remove_at (resource_signals.size - 1);
            disconnect_resource_signals (signals);
        }
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
        // Load completion, width allocation, and zoom can all request a
        // measurement. Keep only one WebKit JavaScript task alive so replaced
        // documents cannot accumulate retained views and cancellables.
        if (height_measurement != null) height_measurement.cancel ();
        var cancellable = new Cancellable ();
        height_measurement = cancellable;
        try {
            if (layout_width > 0) {
                string viewport_script =
                    "document.documentElement.style.width='%dpx';".printf (layout_width) +
                    "if(document.body){document.body.style.width='100%';}";
                yield view.evaluate_javascript (viewport_script, -1, null, null, cancellable);
            }
            var width_result = yield view.evaluate_javascript (
                "Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0)",
                -1, null, null, cancellable);
            if (web_view != view || generation != display_generation) return;
            if (width_result.is_number ()) {
                double document_width = width_result.to_double ();
                int viewport_width = view.get_width ();
                double fit_zoom = 1.0;
                if (document_width > 0 && viewport_width > 0) {
                    fit_zoom = double.min (1.0, ((double) viewport_width) / document_width);
                    fit_zoom = double.max (0.25, fit_zoom);
                    double target_zoom = double.min (5.0, fit_zoom * user_zoom);
                    if (Math.fabs (view.zoom_level - target_zoom) > 0.01)
                        view.zoom_level = target_zoom;
                }
            }
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

    private void queue_fit_to_width () {
        if (width_fit_source != 0) return;
        width_fit_source = Idle.add (() => {
            width_fit_source = 0;
            measure_rendered_height.begin (display_generation);
            return Source.REMOVE;
        });
    }

    public void shutdown (bool terminate_process = false) {
        var view = web_view;
        if (view == null) return;
        display_generation++;
        if (width_fit_source != 0) Source.remove (width_fit_source);
        width_fit_source = 0;
        if (height_measurement != null) height_measurement.cancel ();
        height_measurement = null;
        print_operation = null;
        // Each WebKit signal closure retains this HtmlMessageView. Without
        // explicitly breaking those cycles, changing messages leaves the old
        // WebView and its content process alive indefinitely.
        if (width_handler != 0) view.disconnect (width_handler);
        if (permission_handler != 0) view.disconnect (permission_handler);
        if (resource_handler != 0) view.disconnect (resource_handler);
        if (policy_handler != 0) view.disconnect (policy_handler);
        if (load_handler != 0) view.disconnect (load_handler);
        if (termination_handler != 0) view.disconnect (termination_handler);
        width_handler = permission_handler = resource_handler = policy_handler = load_handler = 0;
        termination_handler = 0;
        rendering_message = false;
        clear_resource_signals ();
        view.stop_loading ();
        // During application shutdown, ask WebKit to terminate its sandboxed
        // renderer before GTK releases the last WebView. Leaving pooled views
        // for object finalization can make the WebProcess run its teardown
        // after the UI process has already exited.
        if (terminate_process) view.terminate_web_process ();
        remove (view);
        web_view = null;
    }

    private void recover_from_web_process_termination (
            WebKit.WebProcessTerminationReason reason) {
        var view = web_view;
        if (view == null || reason == WebKit.WebProcessTerminationReason.TERMINATED_BY_API)
            return;
        bool recovery_failed = recovering_renderer;
        display_generation++;
        if (width_fit_source != 0) Source.remove (width_fit_source);
        width_fit_source = 0;
        if (height_measurement != null) height_measurement.cancel ();
        height_measurement = null;
        document_loaded = false;
        active_resources = 0;
        rendering_message = false;
        clear_resource_signals ();
        if (recovery_failed) {
            warning ("The HTML message renderer could not load its recovery page");
            return;
        }
        bool memory_limit = reason ==
            WebKit.WebProcessTerminationReason.EXCEEDED_MEMORY_LIMIT;
        warning (memory_limit ?
            "The HTML message renderer exceeded its private memory limit" :
            "The HTML message renderer stopped unexpectedly");
        string explanation = memory_limit ?
            "This message was too large to preview safely. Its attachments are still available below." :
            "The formatted preview stopped unexpectedly. Select the message again to retry.";
        allow_remote_content = false;
        recovering_renderer = true;
        rendering_message = true;
        view.load_html (HtmlContentPolicy.document (
            "<p>%s</p>".printf (Markup.escape_text (explanation)), false),
            "about:blank");
    }

    private void secure_request (WebKit.URIRequest request) {
        string uri = request.get_uri ();
        if (!HtmlContentPolicy.allows_resource (uri, allow_remote_content)) request.set_uri ("about:blank");
    }
}
}
