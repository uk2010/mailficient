namespace Mailficient {
private class RuleRunProgressDialog : Adw.Dialog {
    public signal void cancel_requested ();

    private Gtk.Label detail = new Gtk.Label ("");
    private Gtk.ProgressBar progress = new Gtk.ProgressBar ();
    private bool completed;

    public RuleRunProgressDialog (string title, string description) {
        this.title = title;
        add_css_class ("rule-run-dialog"); add_css_class ("background");
        presentation_mode = Adw.DialogPresentationMode.FLOATING;
        content_width = 460; content_height = 235;
        set_size_request (340, 190);
        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false;
        header.show_end_title_buttons = false;
        toolbar.add_top_bar (header);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content.set_margin_start (24); content.set_margin_end (24);
        content.set_margin_top (20); content.set_margin_bottom (20);
        var spinner = new Gtk.Spinner (); spinner.spinning = true;
        spinner.halign = Gtk.Align.CENTER;
        spinner.add_css_class ("rule-run-hero-icon"); content.append (spinner);
        var heading = new Gtk.Label (description);
        heading.add_css_class ("title-3"); heading.wrap = true;
        heading.justify = Gtk.Justification.CENTER; content.append (heading);
        detail.label = "Starting…"; detail.add_css_class ("dim-label");
        detail.halign = Gtk.Align.CENTER; content.append (detail);
        progress.pulse_step = 0.08; progress.add_css_class ("rule-run-progress");
        content.append (progress);
        var cancel = new Gtk.Button.with_label ("Cancel");
        cancel.halign = Gtk.Align.CENTER; cancel.add_css_class ("flat");
        cancel.clicked.connect (() => close ());
        content.append (cancel); toolbar.content = content; child = toolbar;
        closed.connect (() => { if (!completed) cancel_requested (); });
    }

    public void update_progress (int inspected, int matched) {
        detail.label = inspected == 1 ? "Checked 1 message • %d matched".printf (matched) :
            "Checked %d messages • %d matched".printf (inspected, matched);
        progress.pulse ();
    }

    public void complete_and_close () {
        completed = true;
        close ();
    }
}

public class RulesWindow : Adw.Window {
    public signal void rules_changed ();

    private CacheDatabase cache;
    private Gtk.ListBox rule_list = new Gtk.ListBox ();
    private Gtk.Stack state_stack = new Gtk.Stack ();
    private Adw.ToastOverlay toast_overlay = new Adw.ToastOverlay ();
    private Gtk.Button remove_button = new Gtk.Button.from_icon_name ("list-remove-symbolic");
    private Gtk.Button duplicate_button = new Gtk.Button.from_icon_name ("edit-copy-symbolic");
    private Gtk.Button edit_button = new Gtk.Button.with_label ("Edit");
    private Gtk.Button run_button = new Gtk.Button.with_label ("Preview & Run…");
    private Gtk.Button up_button = new Gtk.Button.from_icon_name ("go-up-symbolic");
    private Gtk.Button down_button = new Gtk.Button.from_icon_name ("go-down-symbolic");
    private Gtk.Label rule_count_label = new Gtk.Label ("No rules yet");
    private Gtk.Label selection_label = new Gtk.Label ("Select a rule to manage it");
    private Gee.ArrayList<MailRule> rules = new Gee.ArrayList<MailRule> ();
    private Gee.HashMap<string, string> account_names = new Gee.HashMap<string, string> ();
    private Gee.HashMap<string, string> mailbox_names = new Gee.HashMap<string, string> ();
    private SimpleActionGroup template_actions = new SimpleActionGroup ();
    private bool editor_open;
    private bool run_in_progress;

    public RulesWindow (Gtk.Window parent, CacheDatabase cache) {
        Object (title: "Rules", transient_for: parent, modal: false,
            default_width: Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1" ?
                600 : 860, default_height: 700);
        bool qa_narrow = Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1";
        this.cache = cache;
        add_css_class ("rules-window");
        install_template_actions ();

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        var title_label = new Gtk.Label ("Rules"); title_label.add_css_class ("heading");
        header.title_widget = title_label;
        var add_content = new Adw.ButtonContent ();
        add_content.icon_name = "list-add-symbolic"; add_content.label = "Add Rule";
        var add_button = new Gtk.MenuButton (); add_button.child = add_content;
        add_button.always_show_arrow = true; add_button.menu_model = template_menu ();
        add_button.add_css_class ("suggested-action"); add_button.add_css_class ("rules-primary-action");
        add_button.tooltip_text = "Create a rule from a template";
        Accessibility.label (add_button, "Create a mail rule");
        header.pack_end (add_button); toolbar.add_top_bar (header);

        rule_list.selection_mode = Gtk.SelectionMode.SINGLE;
        rule_list.show_separators = false;
        rule_list.add_css_class ("rules-list");
        rule_list.valign = Gtk.Align.START;
        rule_list.row_selected.connect ((row) => update_selection_actions ());
        rule_list.row_activated.connect ((row) => {
            rule_list.select_row (row); edit_selected.begin ();
        });

        state_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        state_stack.add_named (rule_list, "rules");
        state_stack.add_named (build_empty_state (), "empty");
        state_stack.vexpand = true;

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        page.add_css_class ("rules-page");
        page.append (build_rules_hero ()); page.append (state_stack);
        var page_clamp = new Adw.Clamp (); page_clamp.maximum_size = 840;
        page_clamp.margin_start = qa_narrow ? 14 : 20;
        page_clamp.margin_end = qa_narrow ? 14 : 20;
        page_clamp.margin_top = qa_narrow ? 12 : 16;
        page_clamp.margin_bottom = 20;
        page_clamp.valign = Gtk.Align.START; page_clamp.child = page;
        var scroller = new Gtk.ScrolledWindow ();
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER; scroller.child = page_clamp;

        toast_overlay.child = scroller; toolbar.content = toast_overlay;
        toolbar.add_bottom_bar (build_action_bar ()); content = toolbar;

        var compact = new Adw.Breakpoint (
            new Adw.BreakpointCondition.length (
                Adw.BreakpointConditionLengthType.MAX_WIDTH, 700, Adw.LengthUnit.PX));
        compact.apply.connect (() => selection_label.visible = false);
        compact.unapply.connect (() => selection_label.visible = true);
        add_breakpoint (compact);

        reload_rules ();
        open_qa_state_if_requested ();
    }

    public void refresh () { reload_rules (); }

    public void create_rule () { add_rule.begin (RuleEditorPreset.blank ()); }

    // The sidebar or a future message context menu can call this without
    // knowing anything about the editor widgets. Account, mailbox, sender, and
    // subject context are used to start from a meaningful valid condition.
    public void create_rule_for_context (string account_id, string mailbox_id = "",
                                         string sender = "", string subject = "") {
        add_rule.begin (RuleEditorPreset.for_context (
            account_id, mailbox_id, sender, subject));
    }

    private void install_template_actions () {
        var blank = new SimpleAction ("new-blank-rule", null);
        blank.activate.connect (() => add_rule.begin (RuleEditorPreset.blank ()));
        template_actions.add_action (blank);
        var sender = new SimpleAction ("new-sender-rule", null);
        sender.activate.connect (() => add_rule.begin (RuleEditorPreset.move_from_sender ()));
        template_actions.add_action (sender);
        var subject = new SimpleAction ("new-subject-rule", null);
        subject.activate.connect (() => add_rule.begin (RuleEditorPreset.move_with_subject ()));
        template_actions.add_action (subject);
        var flag = new SimpleAction ("new-flag-rule", null);
        flag.activate.connect (() => add_rule.begin (RuleEditorPreset.flag_from_sender ()));
        template_actions.add_action (flag);
        var mailing_list = new SimpleAction ("new-mailing-list-rule", null);
        mailing_list.activate.connect (() => add_rule.begin (RuleEditorPreset.archive_mailing_list ()));
        template_actions.add_action (mailing_list);
        insert_action_group ("rules", template_actions);
    }

    private Menu template_menu () {
        var menu = new Menu ();
        menu.append ("Blank Rule…", "rules.new-blank-rule");
        var common = new Menu ();
        common.append ("Move Messages from a Sender…", "rules.new-sender-rule");
        common.append ("Move Messages with a Subject…", "rules.new-subject-rule");
        common.append ("Flag Messages from a Sender…", "rules.new-flag-rule");
        common.append ("Archive a Mailing List…", "rules.new-mailing-list-rule");
        menu.append_section ("Start with a common rule", common);
        return menu;
    }

    private Gtk.Widget build_rules_hero () {
        var hero = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        hero.add_css_class ("card"); hero.add_css_class ("rules-hero");
        var icon = new Gtk.Image.from_icon_name ("system-run-symbolic");
        icon.pixel_size = 20; icon.valign = Gtk.Align.START;
        icon.add_css_class ("rules-hero-icon"); hero.append (icon);
        var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); copy.hexpand = true;
        var title = new Gtk.Label ("On-device mail rules");
        title.xalign = 0; title.wrap = true; title.add_css_class ("title-3");
        title.add_css_class ("rules-hero-title");
        var detail = new Gtk.Label (
            "Evaluated from top to bottom as Mailficient checks new mail.");
        detail.xalign = 0; detail.wrap = true; detail.add_css_class ("dim-label");
        detail.add_css_class ("rules-hero-copy");
        copy.append (title); copy.append (detail);
        hero.append (copy);
        rule_count_label.valign = Gtk.Align.CENTER;
        rule_count_label.add_css_class ("rules-count-pill");
        hero.append (rule_count_label);
        return hero;
    }

    private Gtk.Widget build_empty_state () {
        var empty = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        empty.add_css_class ("card"); empty.add_css_class ("rules-empty-card");
        empty.halign = Gtk.Align.FILL;
        var icon = new Gtk.Image.from_icon_name ("folder-new-symbolic");
        icon.pixel_size = 28; icon.halign = Gtk.Align.CENTER;
        icon.add_css_class ("rules-empty-icon"); empty.append (icon);
        var title = new Gtk.Label ("Let Mailficient handle the routine");
        title.halign = Gtk.Align.CENTER; title.wrap = true;
        title.justify = Gtk.Justification.CENTER; title.add_css_class ("title-4");
        empty.append (title);
        var detail = new Gtk.Label (
            "Start with a common rule or build your own. Nothing changes until you choose the conditions and actions.");
        detail.halign = Gtk.Align.CENTER; detail.wrap = true;
        detail.justify = Gtk.Justification.CENTER; detail.add_css_class ("dim-label");
        empty.append (detail);
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        actions.halign = Gtk.Align.CENTER;
        var blank = new Gtk.Button.with_label ("Create a Rule");
        blank.add_css_class ("suggested-action");
        blank.clicked.connect (() => add_rule.begin (RuleEditorPreset.blank ()));
        actions.append (blank);
        var template_content = new Adw.ButtonContent ();
        template_content.icon_name = "view-more-symbolic";
        template_content.label = "Choose a Template";
        var templates = new Gtk.MenuButton (); templates.child = template_content;
        templates.menu_model = template_menu (); templates.always_show_arrow = true;
        Accessibility.label (templates, "Choose a rule template");
        actions.append (templates); empty.append (actions);
        return empty;
    }

    private Gtk.Widget build_action_bar () {
        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        bar.add_css_class ("toolbar"); bar.add_css_class ("rules-action-bar");
        bar.set_margin_start (10); bar.set_margin_end (10);
        bar.set_margin_top (6); bar.set_margin_bottom (6);

        selection_label.xalign = 0; selection_label.ellipsize = Pango.EllipsizeMode.END;
        selection_label.add_css_class ("caption"); selection_label.add_css_class ("dim-label");
        selection_label.add_css_class ("rules-selection-label");
        selection_label.hexpand = true; bar.append (selection_label);

        remove_button.tooltip_text = "Delete selected rule";
        Accessibility.label (remove_button, "Delete selected rule");
        remove_button.add_css_class ("flat");
        remove_button.clicked.connect (() => delete_selected.begin ());
        bar.append (remove_button);

        duplicate_button.tooltip_text = "Duplicate selected rule";
        Accessibility.label (duplicate_button, "Duplicate selected rule");
        duplicate_button.add_css_class ("flat");
        duplicate_button.clicked.connect (duplicate_selected); bar.append (duplicate_button);
        up_button.tooltip_text = "Move selected rule up";
        down_button.tooltip_text = "Move selected rule down";
        Accessibility.label (up_button, up_button.tooltip_text);
        Accessibility.label (down_button, down_button.tooltip_text);
        up_button.clicked.connect (() => move_selected (-1));
        down_button.clicked.connect (() => move_selected (1));
        var ordering = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        ordering.add_css_class ("linked"); ordering.append (up_button); ordering.append (down_button);
        bar.append (ordering);

        edit_button.clicked.connect (() => edit_selected.begin ()); bar.append (edit_button);
        run_button.tooltip_text = "Preview, then apply the selected rule to cached mail on this device";
        run_button.add_css_class ("suggested-action");
        run_button.clicked.connect (() => run_selected.begin ()); bar.append (run_button);
        return bar;
    }

    private void reload_rules (int64 preferred_id = 0) {
        Gtk.Widget? child = rule_list.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            rule_list.remove (child); child = next;
        }
        rules.clear ();
        try {
            refresh_display_names ();
            rules.add_all (cache.list_mail_rules ());
            foreach (var rule in rules) rule_list.append (build_rule_row (rule));
            update_rule_count_label ();
            state_stack.visible_child_name = rules.size == 0 ? "empty" : "rules";
            if (rules.size > 0) {
                Gtk.ListBoxRow? selection = null;
                for (int index = 0; index < rules.size; index++) {
                    var row = rule_list.get_row_at_index (index);
                    if (selection == null || rules[index].id == preferred_id) selection = row;
                    if (rules[index].id == preferred_id) break;
                }
                if (selection != null) rule_list.select_row (selection);
            }
        } catch (Error error) {
            state_stack.visible_child_name = "empty";
            show_error (error.message);
        }
        update_selection_actions ();
    }

    private void refresh_display_names () throws MailError {
        account_names.clear (); mailbox_names.clear ();
        foreach (var account in cache.list_accounts ())
            account_names[account.id] = account.display_name;
        foreach (var mailbox in cache.list_cached_mailboxes ())
            mailbox_names[mailbox.id] = mailbox.name;
    }

    private Gtk.ListBoxRow build_rule_row (MailRule rule) {
        var row = new Gtk.ListBoxRow ();
        row.add_css_class ("card"); row.add_css_class ("rule-card");
        if (!rule.enabled) row.add_css_class ("rule-card-disabled");
        row.set_data<MailRule> ("rule", rule);
        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        content.set_margin_start (12); content.set_margin_end (10);
        content.set_margin_top (8); content.set_margin_bottom (8);

        var order = new Gtk.Label ((rule.position + 1).to_string ());
        order.valign = Gtk.Align.START; order.add_css_class ("rule-order-badge");
        Accessibility.label (order, "Rule %d in processing order".printf (rule.position + 1));
        content.append (order);

        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 3); labels.hexpand = true;
        var name = new Gtk.Label (rule.name); name.xalign = 0; name.wrap = true;
        name.add_css_class ("title-4"); name.add_css_class ("rule-title");
        labels.append (name);
        labels.append (build_rule_flow ("WHEN", rule_conditions_description (rule)));
        labels.append (build_rule_flow ("THEN", rule_actions_description (rule)));
        var metadata = new Gtk.Label (rule_metadata (rule));
        metadata.xalign = 0; metadata.wrap = true;
        metadata.add_css_class ("caption"); metadata.add_css_class ("dim-label");
        metadata.add_css_class ("rule-metadata"); labels.append (metadata);
        content.append (labels);

        var trailing = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        trailing.valign = Gtk.Align.CENTER; trailing.halign = Gtk.Align.CENTER;
        var status = new Gtk.Label (rule.enabled ? "ACTIVE" : "PAUSED");
        status.add_css_class ("caption"); status.add_css_class ("rule-status-label");
        trailing.append (status);
        var enabled = new Gtk.Switch (); enabled.valign = Gtk.Align.CENTER;
        enabled.active = rule.enabled;
        bool reverting_toggle = false;
        enabled.tooltip_text = rule.enabled ? "Disable “%s”".printf (rule.name) : "Enable “%s”".printf (rule.name);
        Accessibility.label (enabled, enabled.tooltip_text);
        enabled.notify["active"].connect (() => {
            if (reverting_toggle) return;
            try {
                cache.set_mail_rule_enabled (rule.id, enabled.active);
                rule.enabled = enabled.active;
                enabled.tooltip_text = enabled.active ? "Disable “%s”".printf (rule.name) : "Enable “%s”".printf (rule.name);
                Accessibility.label (enabled, enabled.tooltip_text);
                status.label = enabled.active ? "ACTIVE" : "PAUSED";
                if (enabled.active) row.remove_css_class ("rule-card-disabled");
                else row.add_css_class ("rule-card-disabled");
                update_rule_count_label (); update_selection_actions ();
                rules_changed ();
            } catch (Error error) {
                reverting_toggle = true; enabled.active = rule.enabled; reverting_toggle = false;
                show_error (error.message);
            }
        });
        trailing.append (enabled);
        var drag_handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
        drag_handle.add_css_class ("dim-label"); drag_handle.valign = Gtk.Align.CENTER;
        drag_handle.add_css_class ("rule-drag-handle");
        drag_handle.tooltip_text = "Drag to change rule order";
        trailing.append (drag_handle); content.append (trailing);
        row.child = content;
        add_rule_drag_and_drop (row, drag_handle, rule.id);
        return row;
    }

    private Gtk.Widget build_rule_flow (string label, string value) {
        var flow = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        flow.add_css_class ("rule-flow");
        var flow_label = new Gtk.Label (label);
        flow_label.valign = Gtk.Align.START; flow_label.add_css_class ("caption");
        flow_label.add_css_class ("rule-flow-label");
        var flow_value = new Gtk.Label (value);
        flow_value.xalign = 0; flow_value.wrap = true; flow_value.hexpand = true;
        flow_value.add_css_class ("rule-flow-value");
        flow.append (flow_label); flow.append (flow_value);
        return flow;
    }

    private void add_rule_drag_and_drop (Gtk.ListBoxRow row, Gtk.Widget drag_handle,
                                         int64 rule_id) {
        var source = new Gtk.DragSource ();
        source.actions = Gdk.DragAction.MOVE;
        source.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        source.prepare.connect ((x, y) => {
            Value value = Value (typeof (string));
            value.set_string (rule_id.to_string ());
            return new Gdk.ContentProvider.for_value (value);
        });
        drag_handle.add_controller (source);

        var target = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.drop.connect ((value, x, y) => {
            string? raw_id = value.get_string (); int64 dragged_id = 0;
            if (raw_id == null || !int64.try_parse (raw_id, out dragged_id) ||
                dragged_id == rule_id) return false;
            reorder_rule (dragged_id, rule_id, y > row.get_height () / 2.0);
            return true;
        });
        row.add_controller (target);
    }

    private void reorder_rule (int64 dragged_id, int64 target_id, bool after_target) {
        int dragged_index = -1; int target_index = -1;
        for (int index = 0; index < rules.size; index++) {
            if (rules[index].id == dragged_id) dragged_index = index;
            if (rules[index].id == target_id) target_index = index;
        }
        if (dragged_index < 0 || target_index < 0) return;
        if (dragged_index < target_index) target_index--;
        int destination = int.max (0, int.min (
            target_index + (after_target ? 1 : 0), rules.size - 1));
        try {
            while (dragged_index < destination) {
                cache.move_mail_rule (dragged_id, 1); dragged_index++;
            }
            while (dragged_index > destination) {
                cache.move_mail_rule (dragged_id, -1); dragged_index--;
            }
            reload_rules (dragged_id); rules_changed ();
        } catch (Error error) { show_error (error.message); }
    }

    private string rule_conditions_description (MailRule rule) {
        var description = new StringBuilder ();
        int index = 0;
        foreach (var condition in rule.conditions) {
            if (index >= 2) break;
            if (index > 0) description.append (
                rule.match_mode == MailRuleMatchMode.ALL ? "  +  " : "  or  ");
            description.append (condition_description (condition));
            index++;
        }
        if (rule.conditions.size > 2)
            description.append ("  +  %d more".printf (rule.conditions.size - 2));
        return description.str;
    }

    private string rule_actions_description (MailRule rule) {
        var description = new StringBuilder ();
        int index = 0;
        foreach (var operation in rule.operations) {
            if (index >= 2) break;
            if (index > 0) description.append ("  →  ");
            description.append (action_description (operation));
            index++;
        }
        if (rule.operations.size > 2)
            description.append ("  →  %d more".printf (rule.operations.size - 2));
        return description.str;
    }

    private void update_rule_count_label () {
        int active_count = 0;
        foreach (var rule in rules) if (rule.enabled) active_count++;
        if (rules.size == 0) rule_count_label.label = "NO RULES YET";
        else rule_count_label.label = "%d %s • %d ACTIVE".printf (
            rules.size, rules.size == 1 ? "RULE" : "RULES", active_count);
    }

    private string rule_metadata (MailRule rule) {
        string scope = "All accounts";
        if (rule.account_id != "")
            scope = account_names[rule.account_id] ?? "Unavailable account — edit to repair";
        var metadata = new StringBuilder ("On this device • " + scope);
        if (rule.exceptions.size > 0)
            metadata.append (" • %d %s".printf (rule.exceptions.size,
                rule.exceptions.size == 1 ? "exception" : "exceptions"));
        if (rule.stop_processing) metadata.append (" • Stops later rules");
        return metadata.str;
    }

    private string condition_description (MailRuleCondition condition) {
        string field = field_name (condition.field);
        string comparison = operator_name (condition.operator, condition.field);
        string value = condition.pattern;
        if (condition.field == MailRuleField.MAILBOX)
            value = mailbox_names[condition.pattern] ??
                "Unavailable folder (edit to repair)";
        else if (condition.field == MailRuleField.HAS_ATTACHMENT ||
                 condition.field == MailRuleField.IS_UNREAD ||
                 condition.field == MailRuleField.IS_FLAGGED)
            value = condition.pattern.down () == "true" || condition.pattern == "1" ?
                "Yes" : "No";
        return "%s %s “%s”".printf (field, comparison, clean_summary_value (value));
    }

    private string action_description (MailRuleOperation operation) {
        switch (operation.action) {
        case MailRuleAction.MARK_READ: return "Mark as read";
        case MailRuleAction.MARK_UNREAD: return "Mark as unread";
        case MailRuleAction.FLAG: return "Flag";
        case MailRuleAction.UNFLAG: return "Remove flag";
        case MailRuleAction.ARCHIVE: return "Archive";
        case MailRuleAction.TRASH: return "Move to Trash";
        case MailRuleAction.LABEL: return "Apply label “%s”".printf (clean_summary_value (operation.value));
        case MailRuleAction.REMOVE_LABEL: return "Remove label “%s”".printf (clean_summary_value (operation.value));
        case MailRuleAction.MOVE:
            return "Move to %s".printf (mailbox_names[operation.value] ??
                "unavailable folder (edit to repair)");
        case MailRuleAction.COPY:
            return "Copy to %s".printf (mailbox_names[operation.value] ??
                "unavailable folder (edit to repair)");
        case MailRuleAction.SET_FLAG_COLOR:
            return "Set %s flag".printf (operation.value == "" ? "colored" : operation.value);
        case MailRuleAction.MARK_JUNK: return "Mark as Junk";
        case MailRuleAction.MARK_NOT_JUNK: return "Mark as Not Junk";
        }
        return "Apply action";
    }

    private static string field_name (MailRuleField field) {
        switch (field) {
        case MailRuleField.SENDER: return "Sender";
        case MailRuleField.RECIPIENT: return "Recipients";
        case MailRuleField.SUBJECT: return "Subject";
        case MailRuleField.BODY: return "Body";
        case MailRuleField.HAS_ATTACHMENT: return "Has attachment";
        case MailRuleField.IS_UNREAD: return "Unread";
        case MailRuleField.IS_FLAGGED: return "Flagged";
        case MailRuleField.CC: return "Cc";
        case MailRuleField.BCC: return "Bcc";
        case MailRuleField.ATTACHMENT_NAME: return "Attachment name";
        case MailRuleField.MESSAGE_SIZE: return "Message size";
        case MailRuleField.MAILBOX: return "Folder";
        case MailRuleField.REPLY_TO: return "Reply-To";
        case MailRuleField.DATE_RECEIVED: return "Date received";
        case MailRuleField.LABEL: return "Label";
        case MailRuleField.SECURITY_STATUS: return "Security status";
        case MailRuleField.MAILING_LIST: return "Mailing list";
        case MailRuleField.RAW_HEADERS: return "Headers";
        }
        return "Message";
    }

    private static string operator_name (MailRuleOperator value, MailRuleField field) {
        switch (value) {
        case MailRuleOperator.DOES_NOT_CONTAIN:
            return field == MailRuleField.MAILBOX || field == MailRuleField.HAS_ATTACHMENT ||
                field == MailRuleField.IS_UNREAD || field == MailRuleField.IS_FLAGGED ?
                "is not" : "does not contain";
        case MailRuleOperator.EQUALS:
            return field == MailRuleField.DATE_RECEIVED ? "is on" : "is";
        case MailRuleOperator.STARTS_WITH: return "starts with";
        case MailRuleOperator.ENDS_WITH: return "ends with";
        case MailRuleOperator.GREATER_THAN: return "is greater than";
        case MailRuleOperator.LESS_THAN: return "is less than";
        case MailRuleOperator.AFTER: return "is after";
        case MailRuleOperator.BEFORE: return "is before";
        default: return "contains";
        }
    }

    private static string clean_summary_value (string value) {
        return value.replace ("\n", " ").replace ("\r", " ").strip ();
    }

    private MailRule? selected_rule () {
        var row = rule_list.get_selected_row ();
        return row == null ? null : row.get_data<MailRule> ("rule");
    }

    private void update_selection_actions () {
        var row = rule_list.get_selected_row ();
        bool selected = row != null && !run_in_progress;
        var rule = selected_rule ();
        selection_label.label = rule == null ? "Select a rule to manage it" :
            "%s • %s".printf (rule.name, rule.enabled ? "Enabled" : "Paused");
        remove_button.sensitive = selected; duplicate_button.sensitive = selected;
        edit_button.sensitive = selected; run_button.sensitive = selected;
        up_button.sensitive = selected && row.get_index () > 0;
        down_button.sensitive = selected && row.get_index () < rules.size - 1;
    }

    private async void add_rule (RuleEditorPreset? preset = null) {
        if (editor_open) { present (); return; }
        editor_open = true;
        try {
            var rule = yield RuleEditorDialog.choose (
                this, cache, null, null, preset ?? RuleEditorPreset.blank ());
            if (rule != null) {
                var saved = cache.save_mail_rule (rule);
                reload_rules (saved.id); rules_changed ();
                show_rule_saved_toast (saved, "created");
            }
        } catch (Error error) { show_error (error.message); }
        finally { editor_open = false; }
    }

    private async void edit_selected () {
        var existing = selected_rule (); if (existing == null) return;
        try {
            var rule = yield RuleEditorDialog.choose (this, cache, existing);
            if (rule == null) return;
            var saved = cache.save_mail_rule (rule);
            reload_rules (saved.id); rules_changed ();
            show_rule_saved_toast (saved, "updated");
        } catch (Error error) { show_error (error.message); }
    }

    private void show_rule_saved_toast (MailRule rule, string change) {
        var toast = new Adw.Toast ("Rule “%s” %s".printf (rule.name, change));
        toast.button_label = "Preview Existing Mail";
        int64 rule_id = rule.id;
        toast.button_clicked.connect (() => {
            // Select the rule saved by this toast even if the user changed the
            // list selection while the toast was visible.
            reload_rules (rule_id);
            run_selected.begin ();
        });
        toast_overlay.add_toast (toast);
    }

    private async void delete_selected () {
        var rule = selected_rule (); if (rule == null) return;
        var dialog = new Adw.AlertDialog ("Delete “%s”?".printf (rule.name),
            "This removes the rule. Messages it already processed will not be changed.");
        dialog.add_response ("cancel", "Cancel"); dialog.add_response ("delete", "Delete Rule");
        dialog.default_response = "cancel"; dialog.close_response = "cancel";
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        if ((yield dialog.choose (this, null)) != "delete") return;
        try {
            int original_position = rule.position;
            var recoverable = copy_rule (rule, rule.name);
            cache.remove_mail_rule (rule.id); reload_rules (); rules_changed ();
            var toast = new Adw.Toast ("Rule “%s” deleted".printf (rule.name));
            toast.button_label = "Undo";
            toast.button_clicked.connect (() => {
                try {
                    var restored = cache.save_mail_rule (recoverable);
                    for (int position = restored.position;
                         position > original_position; position--)
                        cache.move_mail_rule (restored.id, -1);
                    reload_rules (restored.id); rules_changed ();
                } catch (Error error) { show_error (error.message); }
            });
            toast_overlay.add_toast (toast);
        } catch (Error error) { show_error (error.message); }
    }

    private void duplicate_selected () {
        var source = selected_rule (); if (source == null) return;
        try {
            var copy = copy_rule (source, source.name + " copy");
            var saved = cache.save_mail_rule (copy);
            reload_rules (saved.id); rules_changed ();
            toast_overlay.add_toast (new Adw.Toast ("Rule duplicated"));
        } catch (Error error) { show_error (error.message); }
    }

    private static MailRule copy_rule (MailRule source, string name) {
        var first_condition = source.conditions[0];
        var first_action = source.operations[0];
        var copy = new MailRule (0, name, source.account_id,
            first_condition.field, first_condition.pattern, first_action.action,
            first_action.value, source.enabled, 0, source.match_mode,
            source.stop_processing);
        copy.replace_legacy_parts ();
        foreach (var condition in source.conditions)
            copy.conditions.add (new MailRuleCondition (
                condition.field, condition.pattern, condition.operator));
        foreach (var exception in source.exceptions)
            copy.exceptions.add (new MailRuleCondition (
                exception.field, exception.pattern, exception.operator));
        foreach (var operation in source.operations)
            copy.operations.add (new MailRuleOperation (
                operation.action, operation.value));
        return copy;
    }

    private void move_selected (int direction) {
        var rule = selected_rule (); if (rule == null) return;
        try {
            cache.move_mail_rule (rule.id, direction); reload_rules (rule.id); rules_changed ();
        } catch (Error error) { show_error (error.message); }
    }

    private async int choose_run_scope (MailRule rule, Gtk.StringList scope_names) {
        var dialog = new Adw.Dialog ();
        dialog.title = "Preview Rule"; dialog.add_css_class ("rule-run-dialog");
        dialog.add_css_class ("background");
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
        dialog.set_size_request (360, 300);
        dialog.content_width = Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1" ?
            480 : 520;
        dialog.content_height = 350;
        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false; header.show_end_title_buttons = false;
        var cancel = new Gtk.Button.with_label ("Cancel"); cancel.add_css_class ("flat");
        header.pack_start (cancel);
        var preview = new Gtk.Button.with_label ("Preview Matches");
        preview.add_css_class ("suggested-action"); header.pack_end (preview);
        toolbar.add_top_bar (header);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content.set_margin_start (22); content.set_margin_end (22);
        content.set_margin_top (18); content.set_margin_bottom (20);
        var icon = new Gtk.Image.from_icon_name ("system-search-symbolic");
        icon.pixel_size = 24; icon.halign = Gtk.Align.CENTER;
        icon.add_css_class ("rule-run-hero-icon"); content.append (icon);
        var eyebrow = new Gtk.Label ("SAFE RUN");
        eyebrow.halign = Gtk.Align.CENTER; eyebrow.add_css_class ("caption");
        eyebrow.add_css_class ("rules-eyebrow"); content.append (eyebrow);
        var heading = new Gtk.Label ("Preview “%s”".printf (rule.name));
        heading.halign = Gtk.Align.CENTER; heading.wrap = true;
        heading.justify = Gtk.Justification.CENTER; heading.add_css_class ("title-3");
        content.append (heading);
        var detail = new Gtk.Label (
            "Choose which cached mail to check. This first pass only counts matches; it cannot change a message.");
        detail.halign = Gtk.Align.CENTER; detail.wrap = true;
        detail.justify = Gtk.Justification.CENTER; detail.add_css_class ("dim-label");
        content.append (detail);

        var scope_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
        scope_card.add_css_class ("card"); scope_card.add_css_class ("rule-run-scope-card");
        var scope_label = new Gtk.Label ("SEARCH SCOPE");
        scope_label.xalign = 0; scope_label.add_css_class ("caption");
        scope_label.add_css_class ("rule-preview-eyebrow");
        var scope = new Gtk.DropDown (scope_names, null); scope.hexpand = true;
        Accessibility.label (scope, "Messages to preview");
        var scope_detail = new Gtk.Label (
            "Only mail already cached on this device is inspected.");
        scope_detail.xalign = 0; scope_detail.wrap = true;
        scope_detail.add_css_class ("caption"); scope_detail.add_css_class ("dim-label");
        scope_card.append (scope_label); scope_card.append (scope); scope_card.append (scope_detail);
        content.append (scope_card);

        var safety = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        safety.halign = Gtk.Align.CENTER;
        var safety_icon = new Gtk.Image.from_icon_name ("security-high-symbolic");
        safety.append (safety_icon);
        var safety_copy = new Gtk.Label ("You will review the match count before anything is applied.");
        safety_copy.wrap = true; safety_copy.add_css_class ("caption");
        safety_copy.add_css_class ("dim-label"); safety.append (safety_copy);
        content.append (safety); toolbar.content = content; dialog.child = toolbar;
        dialog.default_widget = preview;

        int selected = -1; bool finished = false;
        cancel.clicked.connect (() => dialog.close ());
        preview.clicked.connect (() => {
            selected = (int) scope.selected; dialog.close ();
        });
        dialog.closed.connect (() => {
            if (finished) return; finished = true; choose_run_scope.callback ();
        });
        dialog.present (this); yield;
        return selected;
    }

    private async bool confirm_rule_application (MailRule rule,
                                                  MailRuleRunResult preview,
                                                  string scope_label) {
        var dialog = new Adw.Dialog ();
        dialog.title = "Apply Rule"; dialog.add_css_class ("rule-run-dialog");
        dialog.add_css_class ("background");
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
        dialog.set_size_request (360, 320);
        dialog.content_width = Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1" ?
            480 : 520;
        int notice_count = (preview.truncated ? 1 : 0) + (!rule.enabled ? 1 : 0);
        dialog.content_height = 380 + notice_count * 54;
        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false; header.show_end_title_buttons = false;
        var cancel = new Gtk.Button.with_label ("Cancel"); cancel.add_css_class ("flat");
        header.pack_start (cancel);
        string apply_label = preview.matched == 1 ?
            "Apply to 1 Message" : "Apply to %d Messages".printf (preview.matched);
        var apply = new Gtk.Button.with_label (apply_label);
        apply.add_css_class (destructive_rule (rule) ?
            "destructive-action" : "suggested-action");
        header.pack_end (apply); toolbar.add_top_bar (header);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        content.set_margin_start (22); content.set_margin_end (22);
        content.set_margin_top (18); content.set_margin_bottom (20);
        var count = new Gtk.Label (preview.matched.to_string ());
        count.halign = Gtk.Align.CENTER; count.add_css_class ("title-2");
        count.add_css_class ("rule-run-match-count"); content.append (count);
        var heading = new Gtk.Label (preview.matched == 1 ?
            "message matches" : "messages match");
        heading.halign = Gtk.Align.CENTER; heading.add_css_class ("title-4");
        content.append (heading);
        var description = new Gtk.Label (
            "Review the preview, then choose whether to apply “%s” once to this mail.".printf (rule.name));
        description.halign = Gtk.Align.CENTER; description.wrap = true;
        description.justify = Gtk.Justification.CENTER;
        description.add_css_class ("dim-label"); content.append (description);

        var results = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        results.add_css_class ("card"); results.add_css_class ("rule-run-scope-card");
        results.append (run_detail_row ("folder-symbolic", "Scope", scope_label));
        results.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        results.append (run_detail_row ("system-search-symbolic", "Checked",
            preview.inspected == 1 ? "1 cached message" :
                "%d cached messages".printf (preview.inspected)));
        results.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        results.append (run_detail_row ("computer-symbolic", "Rule location",
            "This device only"));
        content.append (results);

        if (!rule.enabled) {
            var notice = run_notice ("media-playback-pause-symbolic",
                "This rule is paused for future mail. Applying it here is a one-time run.");
            notice.add_css_class ("warning"); content.append (notice);
        }
        if (preview.truncated) {
            var notice = run_notice ("dialog-warning-symbolic",
                "This scope has more than 10,000 messages. Only matches among the first 10,000 checked will be applied.");
            notice.add_css_class ("warning"); content.append (notice);
        }
        var final_note = new Gtk.Label (
            "No server mail outside this device was inspected. Applied folder changes will synchronize normally with your provider.");
        final_note.xalign = 0; final_note.wrap = true;
        final_note.add_css_class ("caption"); final_note.add_css_class ("dim-label");
        content.append (final_note); toolbar.content = content; dialog.child = toolbar;
        // Applying is intentionally never the default response.
        dialog.default_widget = cancel;

        bool accepted = false; bool finished = false;
        cancel.clicked.connect (() => dialog.close ());
        apply.clicked.connect (() => { accepted = true; dialog.close (); });
        dialog.closed.connect (() => {
            if (finished) return; finished = true; confirm_rule_application.callback ();
        });
        dialog.present (this); yield;
        return accepted;
    }

    private Gtk.Widget run_detail_row (string icon_name, string title, string value) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        row.add_css_class ("rule-run-detail-row");
        var icon = new Gtk.Image.from_icon_name (icon_name); row.append (icon);
        var label = new Gtk.Label (title); label.xalign = 0; label.hexpand = true;
        label.add_css_class ("dim-label"); row.append (label);
        var detail = new Gtk.Label (value); detail.xalign = 1; detail.wrap = true;
        detail.justify = Gtk.Justification.RIGHT; row.append (detail);
        return row;
    }

    private Gtk.Widget run_notice (string icon_name, string description) {
        var notice = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 7);
        notice.add_css_class ("rule-run-notice");
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.valign = Gtk.Align.START; notice.append (icon);
        var copy = new Gtk.Label (description); copy.xalign = 0; copy.wrap = true;
        copy.hexpand = true; notice.append (copy); return notice;
    }

    private async void run_selected () {
        var rule = selected_rule ();
        if (rule == null || run_in_progress) return;
        run_in_progress = true; update_selection_actions ();
        try {
            var scope_names = new Gtk.StringList (null);
            var scope_ids = new Gee.ArrayList<string> ();
            string account_scope = rule.account_id == "" ? "all accounts" :
                (account_names[rule.account_id] ?? "the rule’s account");
            scope_names.append ("All cached mail — " + account_scope);
            scope_ids.add ("");
            foreach (var mailbox in cache.list_cached_mailboxes ()) {
                if (rule.account_id != "" && mailbox.account_id != rule.account_id) continue;
                string display_name = mailbox.name;
                if (rule.account_id == "") {
                    string account_name = account_names[mailbox.account_id] ?? mailbox.account_id;
                    display_name = "%s — %s".printf (account_name, mailbox.name);
                }
                scope_names.append (display_name); scope_ids.add (mailbox.id);
            }
            int scope_index = yield choose_run_scope (rule, scope_names);
            if (scope_index < 0) return;
            string mailbox_scope = scope_index < scope_ids.size ? scope_ids[scope_index] : "";
            string scope_label = scope_names.get_string ((uint) scope_index);

            var preview_service = new MailRuleService (cache);
            var preview_cancel = new Cancellable ();
            var preview_progress = new RuleRunProgressDialog (
                "Checking Rule", "Finding matching cached mail on this device…");
            preview_progress.cancel_requested.connect (() => preview_cancel.cancel ());
            preview_service.run_progress.connect ((inspected, matched) =>
                preview_progress.update_progress (inspected, matched));
            preview_progress.present (this);

            MailRuleRunResult preview;
            try {
                preview = yield preview_service.preview_run (
                    rule, 10000, preview_cancel, mailbox_scope);
            } catch (IOError.CANCELLED error) {
                preview_progress.complete_and_close ();
                toast_overlay.add_toast (new Adw.Toast ("Rule check canceled"));
                return;
            }
            preview_progress.complete_and_close ();

            if (preview.matched == 0) {
                string checked = preview.inspected == 1 ? "1 cached message" :
                    "%d cached messages".printf (preview.inspected);
                toast_overlay.add_toast (new Adw.Toast (
                    "No matches in %s on this device".printf (checked)));
                return;
            }

            if (!(yield confirm_rule_application (
                    rule, preview, scope_label))) return;

            var apply_service = new MailRuleService (cache);
            var apply_cancel = new Cancellable ();
            var apply_progress = new RuleRunProgressDialog (
                "Applying Rule", "Applying changes to cached mail on this device…");
            int last_matched = 0;
            apply_progress.cancel_requested.connect (() => apply_cancel.cancel ());
            apply_service.run_progress.connect ((inspected, matched) => {
                last_matched = matched;
                apply_progress.update_progress (inspected, matched);
            });
            apply_progress.present (this);
            MailRuleRunResult applied;
            try {
                applied = yield apply_service.run_now_async (
                    rule, 10000, apply_cancel, mailbox_scope);
            } catch (IOError.CANCELLED error) {
                apply_progress.complete_and_close ();
                string partial = last_matched == 0 ? "No messages were changed" :
                    "Canceled after changing %d %s".printf (last_matched,
                        last_matched == 1 ? "message" : "messages");
                toast_overlay.add_toast (new Adw.Toast (partial));
                if (last_matched > 0) rules_changed ();
                return;
            }
            apply_progress.complete_and_close ();
            string message = applied.matched == 1 ?
                "Applied “%s” to 1 message on this device".printf (rule.name) :
                "Applied “%s” to %d messages on this device".printf (
                    rule.name, applied.matched);
            if (applied.truncated) message += " (10,000 checked)";
            toast_overlay.add_toast (new Adw.Toast (message));
            if (applied.matched > 0) rules_changed ();
        } catch (Error error) {
            if (!(error is IOError.CANCELLED)) show_error (error.message);
        } finally {
            run_in_progress = false; update_selection_actions ();
        }
    }

    private static bool destructive_rule (MailRule rule) {
        foreach (var operation in rule.operations)
            if (operation.action == MailRuleAction.TRASH ||
                operation.action == MailRuleAction.MARK_JUNK)
                return true;
        return false;
    }

    private void open_qa_state_if_requested () {
        if (Environment.get_variable ("MAILFICIENT_QA") != "1") return;
        bool editor = Environment.get_variable ("MAILFICIENT_QA_RULE_EDITOR") == "1";
        string run_state = Environment.get_variable ("MAILFICIENT_QA_RULE_RUN") ?? "";
        bool run_preview = run_state == "1";
        bool run_confirmation = run_state == "confirm";
        if (!editor && !run_preview && !run_confirmation) return;
        Idle.add (() => {
            if (editor)
                add_rule.begin (RuleEditorPreset.flag_from_sender ());
            else if (run_confirmation)
                open_qa_run_confirmation.begin ();
            else if (run_preview)
                run_selected.begin ();
            return Source.REMOVE;
        });
    }

    private async void open_qa_run_confirmation () {
        if (rules.size > 1) rule_list.select_row (rule_list.get_row_at_index (1));
        var rule = selected_rule (); if (rule == null) return;
        try {
            var service = new MailRuleService (cache);
            var preview = yield service.preview_run (rule, 10000, null, "");
            if (preview.matched == 0) return;
            yield confirm_rule_application (
                rule, preview, "All cached mail — all accounts");
        } catch (Error error) { show_error (error.message); }
    }

    private void show_error (string message) {
        var toast = new Adw.Toast (message); toast.priority = Adw.ToastPriority.HIGH;
        toast_overlay.add_toast (toast);
    }
}
}
