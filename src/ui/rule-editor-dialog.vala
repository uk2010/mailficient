namespace Mailficient {
internal class RuleConditionEditorRow : Gtk.Box {
    public signal void changed ();
    public Gtk.DropDown field = new Gtk.DropDown.from_strings ({
        "Sender", "Recipients", "Subject", "Body", "Has attachment", "Is unread", "Is flagged",
        "Cc", "Bcc", "Attachment name", "Message size", "Folder", "Reply-To", "Date received",
        "Label", "Security status", "Mailing list headers", "Raw headers"
    });
    public Gtk.DropDown operator;
    public Gtk.Entry pattern = new Gtk.Entry ();
    public new Gtk.Button remove = new Gtk.Button.from_icon_name ("list-remove-symbolic");
    private Gtk.DropDown boolean_value = new Gtk.DropDown.from_strings ({ "Yes", "No" });
    private Gtk.DropDown mailbox_value;
    private Gtk.StringList mailbox_names = new Gtk.StringList (null);
    private Gee.ArrayList<string> mailbox_ids = new Gee.ArrayList<string> ();
    private Gtk.Stack pattern_stack = new Gtk.Stack ();
    private Gee.ArrayList<MailRuleOperator> operator_values = new Gee.ArrayList<MailRuleOperator> ();
    private CacheDatabase cache;
    private string account_scope = "";

    public RuleConditionEditorRow (CacheDatabase cache, MailRuleCondition? existing = null,
                                   string account_scope = "") {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 6);
        this.cache = cache; this.account_scope = account_scope;
        add_css_class ("card"); add_css_class ("rule-builder-row");
        add_css_class ("rule-condition-row");
        operator = new Gtk.DropDown (new Gtk.StringList (null), null);
        field.hexpand = true; operator.hexpand = true;
        pattern.hexpand = true; pattern.placeholder_text = "Value";
        boolean_value.hexpand = true;
        mailbox_value = new Gtk.DropDown (mailbox_names, null);
        mailbox_value.hexpand = true;
        pattern_stack.hexpand = true;
        pattern_stack.add_named (pattern, "text"); pattern_stack.add_named (boolean_value, "boolean");
        pattern_stack.add_named (mailbox_value, "mailbox");
        Accessibility.label (field, "Condition field");
        Accessibility.description (field, "Condition field");
        Accessibility.label (operator, "Condition comparison");
        Accessibility.description (operator, "Condition comparison");
        Accessibility.label (pattern, "Condition value");
        Accessibility.label (boolean_value, "Condition value");
        Accessibility.description (boolean_value, "Choose Yes or No");
        Accessibility.label (mailbox_value, "Condition folder");
        remove.tooltip_text = "Remove condition"; Accessibility.label (remove, "Remove condition");
        remove.add_css_class ("flat");
        var selectors = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        selectors.append (field); selectors.append (operator);
        selectors.append (remove);
        append (selectors); append (pattern_stack);
        if (existing != null) field.selected = (uint) existing.field;
        rebuild_operators (existing == null ? MailRuleOperator.CONTAINS : existing.operator);
        if (existing != null) {
            pattern.text = existing.pattern;
            boolean_value.selected = existing.pattern.strip ().down () == "false" ||
                existing.pattern.strip ().down () == "no" || existing.pattern.strip () == "0" ? 1 : 0;
        }
        rebuild_mailboxes (account_scope,
            existing != null && existing.field == MailRuleField.MAILBOX ?
                existing.pattern : "", existing != null);
        field.notify["selected"].connect (() => {
            rebuild_operators (selected_operator ()); update_hint (); changed ();
        });
        operator.notify["selected"].connect (() => changed ());
        pattern.changed.connect (() => changed ());
        boolean_value.notify["selected"].connect (() => changed ());
        mailbox_value.notify["selected"].connect (() => changed ());
        update_hint ();
    }

    public MailRuleCondition value () {
        return new MailRuleCondition ((MailRuleField) field.selected, pattern_value (),
            selected_operator ());
    }

    public bool has_value () {
        if (is_boolean_field ()) return true;
        if ((MailRuleField) field.selected == MailRuleField.MAILBOX)
            return mailbox_value.selected < mailbox_ids.size &&
                mailbox_ids[(int) mailbox_value.selected] != "";
        return pattern.text.strip () != "";
    }

    public string validation_issue () {
        if (!has_value ())
            return (MailRuleField) field.selected == MailRuleField.MAILBOX ?
                "Choose a folder for every folder condition." :
                "Enter a value for every condition.";
        if ((MailRuleField) field.selected == MailRuleField.DATE_RECEIVED) {
            string clean = pattern.text.strip ();
            if (!Regex.match_simple ("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", clean) ||
                new DateTime.from_iso8601 (
                    clean + "T00:00:00", new TimeZone.local ()) == null)
                return "Enter dates as YYYY-MM-DD.";
        }
        if ((MailRuleField) field.selected == MailRuleField.MESSAGE_SIZE &&
            !Regex.match_simple ("^[0-9]+([.][0-9]+)?[ ]*(b|kb|mb|gb)?$",
                pattern.text.strip ().down ()))
            return "Enter a valid size, such as 500 KB or 2 MB.";
        return "";
    }

    public void set_account_scope (string value) {
        string preferred = "";
        if (mailbox_value.selected < mailbox_ids.size)
            preferred = mailbox_ids[(int) mailbox_value.selected];
        account_scope = value;
        rebuild_mailboxes (account_scope, preferred, false);
        changed ();
    }

    private void rebuild_mailboxes (string selected_account, string preferred_id,
                                    bool preserve_unavailable) {
        var names = new Gtk.StringList (null);
        mailbox_ids.clear (); names.append ("Choose a folder…"); mailbox_ids.add ("");
        int selected = 0;
        try {
            foreach (var mailbox in cache.list_cached_mailboxes ()) {
                if (selected_account != "" && mailbox.account_id != selected_account) continue;
                string display_name = mailbox.name;
                if (selected_account == "") {
                    string account_name = mailbox.account_id;
                    var account = cache.find_account (mailbox.account_id);
                    if (account != null) account_name = account.display_name;
                    display_name = "%s — %s".printf (account_name, mailbox.name);
                }
                names.append (display_name); mailbox_ids.add (mailbox.id);
                if (mailbox.id == preferred_id) selected = mailbox_ids.size - 1;
            }
        } catch (Error error) {
            warning ("Could not load rule-condition mailboxes: %s", error.message);
        }
        if (preferred_id != "" && selected == 0 && preserve_unavailable) {
            names.append ("Unavailable folder — " + preferred_id);
            mailbox_ids.add (preferred_id); selected = mailbox_ids.size - 1;
        }
        mailbox_names = names; mailbox_value.model = mailbox_names;
        mailbox_value.selected = (uint) selected;
    }

    private string pattern_value () {
        if (is_boolean_field ()) return boolean_value.selected == 0 ? "true" : "false";
        if ((MailRuleField) field.selected == MailRuleField.MAILBOX &&
            mailbox_value.selected < mailbox_ids.size)
            return mailbox_ids[(int) mailbox_value.selected];
        return pattern.text;
    }

    private MailRuleOperator selected_operator () {
        return operator.selected < operator_values.size ?
            operator_values[(int) operator.selected] : MailRuleOperator.CONTAINS;
    }

    private bool is_boolean_field () {
        var selected_field = (MailRuleField) field.selected;
        return selected_field == MailRuleField.HAS_ATTACHMENT ||
            selected_field == MailRuleField.IS_UNREAD ||
            selected_field == MailRuleField.IS_FLAGGED;
    }

    private void rebuild_operators (MailRuleOperator preferred) {
        var names = new Gtk.StringList (null); operator_values.clear ();
        if (is_boolean_field ()) {
            add_operator (names, "is", MailRuleOperator.EQUALS);
            add_operator (names, "is not", MailRuleOperator.DOES_NOT_CONTAIN);
        } else if ((MailRuleField) field.selected == MailRuleField.MESSAGE_SIZE) {
            add_operator (names, "is", MailRuleOperator.EQUALS);
            add_operator (names, "is greater than", MailRuleOperator.GREATER_THAN);
            add_operator (names, "is less than", MailRuleOperator.LESS_THAN);
        } else if ((MailRuleField) field.selected == MailRuleField.DATE_RECEIVED) {
            add_operator (names, "is on", MailRuleOperator.EQUALS);
            add_operator (names, "is after", MailRuleOperator.AFTER);
            add_operator (names, "is before", MailRuleOperator.BEFORE);
        } else if ((MailRuleField) field.selected == MailRuleField.MAILBOX) {
            add_operator (names, "is", MailRuleOperator.EQUALS);
            add_operator (names, "is not", MailRuleOperator.DOES_NOT_CONTAIN);
        } else {
            add_operator (names, "contains", MailRuleOperator.CONTAINS);
            add_operator (names, "does not contain", MailRuleOperator.DOES_NOT_CONTAIN);
            add_operator (names, "equals", MailRuleOperator.EQUALS);
            add_operator (names, "starts with", MailRuleOperator.STARTS_WITH);
            add_operator (names, "ends with", MailRuleOperator.ENDS_WITH);
        }
        operator.model = names;
        operator.selected = 0;
        for (int index = 0; index < operator_values.size; index++)
            if (operator_values[index] == preferred) { operator.selected = (uint) index; break; }
    }

    private void add_operator (Gtk.StringList names, string label, MailRuleOperator value) {
        names.append (label); operator_values.add (value);
    }

    private void update_hint () {
        var selected_field = (MailRuleField) field.selected;
        pattern_stack.visible_child_name = is_boolean_field () ? "boolean" :
            selected_field == MailRuleField.MAILBOX ? "mailbox" : "text";
        if (selected_field == MailRuleField.MESSAGE_SIZE) {
            pattern.placeholder_text = "Size in bytes, KB, MB, or GB";
        } else if (selected_field == MailRuleField.DATE_RECEIVED) {
            pattern.placeholder_text = "YYYY-MM-DD";
        } else if (selected_field == MailRuleField.SECURITY_STATUS) {
            pattern.placeholder_text = "signed, encrypted, passed, failed…";
        } else if (selected_field == MailRuleField.MAILING_LIST) {
            pattern.placeholder_text = "List name, address, or header value";
        } else {
            pattern.placeholder_text = "Value";
        }
    }
}

internal class RuleActionEditorRow : Gtk.Box {
    public signal void changed ();
    public Gtk.DropDown action = new Gtk.DropDown.from_strings ({
        "Mark read", "Flag", "Archive", "Move to Trash", "Apply label", "Mark unread", "Unflag",
        "Move to folder", "Copy to folder", "Set flag color", "Mark as Junk", "Mark as Not Junk",
        "Remove label"
    });
    public Gtk.Entry value_entry = new Gtk.Entry ();
    public Gtk.DropDown destination;
    public new Gtk.Button remove = new Gtk.Button.from_icon_name ("list-remove-symbolic");
    private Gtk.Stack value_stack = new Gtk.Stack ();
    private Gtk.DropDown flag_color = new Gtk.DropDown.from_strings ({
        "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"
    });
    private Gtk.DropDown label_value;
    private CacheDatabase cache;
    private string account_scope = "";
    private Gee.ArrayList<string> label_values = new Gee.ArrayList<string> ();
    private string[] flag_color_values = {
        "red", "orange", "yellow", "green", "blue", "purple", "gray"
    };
    private Gee.ArrayList<string> destination_ids = new Gee.ArrayList<string> ();
    private Gee.ArrayList<string> destination_account_ids = new Gee.ArrayList<string> ();

    public RuleActionEditorRow (CacheDatabase cache, MailRuleOperation? existing = null,
                                string account_scope = "") {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 6);
        this.cache = cache;
        this.account_scope = account_scope;
        add_css_class ("card"); add_css_class ("rule-builder-row");
        add_css_class ("rule-action-row");
        action.hexpand = true; value_entry.hexpand = true;
        value_entry.placeholder_text = "Label name";
        Accessibility.label (action, "Rule action");
        Accessibility.description (action, "Rule action");
        Accessibility.label (value_entry, "Action value");
        destination = new Gtk.DropDown (new Gtk.StringList (null), null);
        destination.hexpand = true;
        Accessibility.label (destination, "Destination folder");
        Accessibility.description (destination, "Destination folder");
        var label_names = new Gtk.StringList (null);
        label_names.append ("Choose a label…"); label_values.add ("");
        try {
            foreach (var label in cache.list_mail_labels ()) {
                label_names.append (label.name); label_values.add (label.name);
            }
        } catch (Error error) {
            warning ("Could not load rule labels: %s", error.message);
        }
        label_value = new Gtk.DropDown (label_names, null);
        label_value.hexpand = true; Accessibility.label (label_value, "Label to remove");
        var no_value = new Gtk.Label ("No additional value needed");
        no_value.xalign = 0; no_value.add_css_class ("dim-label");
        value_stack.hexpand = true;
        value_stack.add_named (no_value, "none");
        value_stack.add_named (value_entry, "label");
        value_stack.add_named (label_value, "existing-label");
        value_stack.add_named (destination, "mailbox");
        flag_color.hexpand = true; Accessibility.label (flag_color, "Flag color");
        value_stack.add_named (flag_color, "flag-color");
        remove.tooltip_text = "Remove action"; Accessibility.label (remove, "Remove action");
        remove.add_css_class ("flat");
        var selector = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        selector.append (action); selector.append (remove);
        append (selector); append (value_stack);
        action.notify["selected"].connect (() => { update_hint (); changed (); });
        value_entry.changed.connect (() => changed ());
        destination.notify["selected"].connect (() => changed ());
        flag_color.notify["selected"].connect (() => changed ());
        label_value.notify["selected"].connect (() => changed ());
        if (existing != null) {
            action.selected = (uint) existing.action; value_entry.text = existing.value;
            if (existing.action == MailRuleAction.SET_FLAG_COLOR) {
                for (int index = 0; index < flag_color_values.length; index++)
                    if (flag_color_values[index] == existing.value) {
                        flag_color.selected = (uint) index; break;
                    }
            } else if (existing.action == MailRuleAction.REMOVE_LABEL) {
                int selected = -1;
                for (int index = 0; index < label_values.size; index++)
                    if (label_values[index].down () == existing.value.down ()) {
                        selected = index; break;
                    }
                if (selected < 0 && existing.value != "") {
                    label_names.append ("Unavailable label — " + existing.value);
                    label_values.add (existing.value); selected = label_values.size - 1;
                }
                if (selected >= 0) label_value.selected = (uint) selected;
            }
        }
        rebuild_destinations (account_scope,
            existing != null && (existing.action == MailRuleAction.MOVE ||
                                  existing.action == MailRuleAction.COPY) ? existing.value : "",
            existing != null);
        update_hint ();
    }

    public MailRuleOperation value () {
        var selected_action = (MailRuleAction) action.selected;
        string value = "";
        if (selected_action == MailRuleAction.LABEL) value = value_entry.text;
        else if (selected_action == MailRuleAction.REMOVE_LABEL &&
                 label_value.selected < label_values.size)
            value = label_values[(int) label_value.selected];
        else if (selected_action == MailRuleAction.SET_FLAG_COLOR &&
                 flag_color.selected < flag_color_values.length)
            value = flag_color_values[(int) flag_color.selected];
        else if ((selected_action == MailRuleAction.MOVE ||
                  selected_action == MailRuleAction.COPY) &&
                 destination.selected < destination_ids.size)
            value = destination_ids[(int) destination.selected];
        return new MailRuleOperation (selected_action, value);
    }

    public string destination_account_id () {
        return destination.selected < destination_account_ids.size ?
            destination_account_ids[(int) destination.selected] : "";
    }

    public void set_account_scope (string value) {
        string preferred = "";
        if (destination.selected < destination_ids.size)
            preferred = destination_ids[(int) destination.selected];
        account_scope = value;
        rebuild_destinations (account_scope, preferred, false);
        update_hint ();
        changed ();
    }

    private void rebuild_destinations (string selected_account, string preferred_id,
                                       bool preserve_unavailable) {
        var destination_names = new Gtk.StringList (null);
        destination_ids.clear (); destination_account_ids.clear ();
        destination_names.append (selected_account == "" ?
            "Choose a specific account first…" : "Choose a folder…");
        destination_ids.add (""); destination_account_ids.add ("");
        int selected = 0;
        if (selected_account != "") {
            try {
                foreach (var mailbox in cache.list_cached_mailboxes ()) {
                    if (mailbox.account_id != selected_account) continue;
                    int depth = 0;
                    for (int index = 0; index < mailbox.remote_name.length; index++)
                        if (mailbox.remote_name[index] == '/' ||
                            mailbox.remote_name[index] == '\\') depth++;
                    var indent = new StringBuilder ();
                    for (int index = 0; index < int.min (depth, 5); index++)
                        indent.append ("  ");
                    destination_names.append (indent.str + mailbox.name);
                    destination_ids.add (mailbox.id);
                    destination_account_ids.add (mailbox.account_id);
                    if (mailbox.id == preferred_id) selected = destination_ids.size - 1;
                }
            } catch (Error error) {
                warning ("Could not load rule destinations: %s", error.message);
            }
        }
        if (preferred_id != "" && selected == 0 && preserve_unavailable) {
            destination_names.append ("Unavailable folder — " + preferred_id);
            destination_ids.add (preferred_id); destination_account_ids.add ("");
            selected = destination_ids.size - 1;
        }
        destination.model = destination_names;
        destination.selected = (uint) selected;
        destination.sensitive = selected_account != "";
    }

    private void update_hint () {
        var selected_action = (MailRuleAction) action.selected;
        bool label = selected_action == MailRuleAction.LABEL;
        bool mailbox = selected_action == MailRuleAction.MOVE ||
            selected_action == MailRuleAction.COPY;
        value_stack.visible_child_name = label ? "label" : mailbox ? "mailbox" :
            selected_action == MailRuleAction.SET_FLAG_COLOR ? "flag-color" :
            selected_action == MailRuleAction.REMOVE_LABEL ? "existing-label" : "none";
        if (mailbox) destination.sensitive = account_scope != "";
    }
}

public class RuleEditorPreset : Object {
    public string name_hint { get; construct; }
    public string account_id { get; construct; }
    public MailRuleField field { get; construct; }
    public MailRuleOperator operator { get; construct; }
    public string pattern { get; construct; }
    public MailRuleAction action { get; construct; }
    public string action_value { get; construct; }

    public RuleEditorPreset (string name_hint, MailRuleField field, MailRuleAction action,
                             string pattern = "", string account_id = "",
                             MailRuleOperator operator = MailRuleOperator.CONTAINS,
                             string action_value = "") {
        Object (name_hint: name_hint, account_id: account_id, field: field,
            operator: operator, pattern: pattern, action: action,
            action_value: action_value);
    }

    public static RuleEditorPreset blank () {
        return new RuleEditorPreset ("", MailRuleField.SENDER, MailRuleAction.MARK_READ);
    }

    public static RuleEditorPreset move_from_sender () {
        return new RuleEditorPreset ("Messages from a sender", MailRuleField.SENDER,
            MailRuleAction.MOVE);
    }

    public static RuleEditorPreset move_with_subject () {
        return new RuleEditorPreset ("Messages with a subject", MailRuleField.SUBJECT,
            MailRuleAction.MOVE);
    }

    public static RuleEditorPreset flag_from_sender () {
        return new RuleEditorPreset ("Important sender", MailRuleField.SENDER,
            MailRuleAction.FLAG);
    }

    public static RuleEditorPreset archive_mailing_list () {
        return new RuleEditorPreset ("Archive a mailing list", MailRuleField.MAILING_LIST,
            MailRuleAction.ARCHIVE);
    }

    public static RuleEditorPreset for_context (string account_id, string mailbox_id = "",
                                                string sender = "", string subject = "") {
        if (sender.strip () != "")
            return new RuleEditorPreset ("Messages from " + sender.strip (),
                MailRuleField.SENDER, MailRuleAction.MOVE, sender, account_id,
                MailRuleOperator.CONTAINS);
        if (subject.strip () != "")
            return new RuleEditorPreset ("Messages about " + subject.strip (),
                MailRuleField.SUBJECT, MailRuleAction.MOVE, subject, account_id,
                MailRuleOperator.CONTAINS);
        if (mailbox_id.strip () != "")
            return new RuleEditorPreset ("Messages in this folder",
                MailRuleField.MAILBOX, MailRuleAction.MARK_READ, mailbox_id,
                account_id, MailRuleOperator.EQUALS);
        return new RuleEditorPreset ("", MailRuleField.SENDER,
            MailRuleAction.MARK_READ, "", account_id);
    }
}

public class RuleEditorDialog : Object {
    public static async MailRule? choose (Gtk.Window parent, CacheDatabase cache,
                                          MailRule? existing = null,
                                          Cancellable? cancellable = null,
                                          RuleEditorPreset? requested_preset = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        var preset = requested_preset ?? RuleEditorPreset.blank ();
        var accounts = new Gee.ArrayList<string> (); accounts.add ("");
        var account_names = new Gtk.StringList (null); account_names.append ("All accounts");
        foreach (var account in cache.list_accounts ()) {
            accounts.add (account.id); account_names.append ("%s — %s".printf (account.display_name, account.email));
        }
        var name = new Gtk.Entry ();
        name.placeholder_text = preset.name_hint == "" ? "Rule name" : preset.name_hint;
        name.hexpand = true;
        Accessibility.label (name, "Rule name");
        var account = new Gtk.DropDown (account_names, null); account.hexpand = true;
        Accessibility.label (account, "Rule account scope");
        Accessibility.description (account, "Rule account scope");
        var match_mode = new Gtk.DropDown.from_strings ({ "Match every condition (AND)", "Match any condition (OR)" });
        match_mode.hexpand = true; Accessibility.label (match_mode, "Condition matching mode");
        Accessibility.description (match_mode, "Condition matching mode");
        string initial_account_id = existing == null ? preset.account_id : existing.account_id;
        for (int index = 0; index < accounts.size; index++)
            if (accounts[index] == initial_account_id) account.selected = (uint) index;

        var conditions = new Gee.ArrayList<RuleConditionEditorRow> ();
        var exceptions = new Gee.ArrayList<RuleConditionEditorRow> ();
        var actions = new Gee.ArrayList<RuleActionEditorRow> ();
        var condition_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var exception_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var action_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        content.add_css_class ("rule-editor-content");
        content.set_margin_start (20); content.set_margin_end (20);
        content.set_margin_top (12); content.set_margin_bottom (16);

        var intro = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        intro.add_css_class ("card"); intro.add_css_class ("rule-editor-hero");
        var intro_icon = new Gtk.Image.from_icon_name ("computer-symbolic");
        intro_icon.add_css_class ("rule-run-hero-icon");
        intro_icon.valign = Gtk.Align.START; intro.append (intro_icon);
        var intro_copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); intro_copy.hexpand = true;
        var intro_title = new Gtk.Label ("Runs on this device");
        intro_title.xalign = 0; intro_title.wrap = true;
        intro_title.add_css_class ("title-3");
        var intro_detail = new Gtk.Label (
            "Evaluated when Mailficient checks mail here; nothing is installed on your server.");
        intro_detail.xalign = 0; intro_detail.wrap = true;
        intro_detail.add_css_class ("caption"); intro_detail.add_css_class ("dim-label");
        intro_copy.append (intro_title); intro_copy.append (intro_detail);
        intro.append (intro_copy);
        content.append (intro);

        var details_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        details_box.append (labeled ("Name", name)); details_box.append (labeled ("Account", account));
        content.append (editor_section ("1", "Name and scope",
            "",
            details_box, "rule-editor-identity"));

        var condition_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        condition_content.append (labeled ("Combine matches", match_mode));
        condition_content.append (condition_box);
        var add_condition = add_row_button ("Add Condition");
        condition_content.append (add_condition);
        var condition_section = editor_section ("2", "Choose what to match",
            "Require all conditions, or match any.",
            condition_content, "rule-editor-conditions");
        condition_section.hexpand = true; condition_section.valign = Gtk.Align.START;

        var action_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        action_content.append (action_box);
        var add_action = add_row_button ("Add Action");
        action_content.append (add_action);
        var action_section = editor_section ("3", "Choose what happens",
            "Actions run from top to bottom.",
            action_content, "rule-editor-actions");
        action_section.hexpand = true; action_section.valign = Gtk.Align.START;
        var builder_columns = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        builder_columns.add_css_class ("rule-editor-builder-columns");
        builder_columns.append (condition_section); builder_columns.append (action_section);
        content.append (builder_columns);

        var preview_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        preview_card.add_css_class ("card"); preview_card.add_css_class ("rule-preview-card");
        var preview_eyebrow = new Gtk.Label ("RULE PREVIEW");
        preview_eyebrow.xalign = 0; preview_eyebrow.add_css_class ("caption");
        preview_eyebrow.add_css_class ("rule-preview-eyebrow");
        var preview_title = new Gtk.Label ("Untitled rule");
        preview_title.xalign = 0; preview_title.wrap = true;
        preview_title.add_css_class ("title-4"); preview_title.add_css_class ("rule-preview-title");
        var preview_text = new Gtk.Label ("");
        preview_text.xalign = 0; preview_text.wrap = true;
        preview_text.add_css_class ("rule-preview-text");
        var preview_scope = new Gtk.Label ("");
        preview_scope.xalign = 0; preview_scope.wrap = true;
        preview_scope.add_css_class ("caption"); preview_scope.add_css_class ("dim-label");
        preview_card.append (preview_eyebrow); preview_card.append (preview_title);
        preview_card.append (preview_text); preview_card.append (preview_scope);
        content.append (preview_card);

        var exception_expander = new Adw.ExpanderRow ();
        exception_expander.title = "Exceptions";
        exception_expander.subtitle = "Do not run when any exception matches";
        var exception_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        exception_content.set_margin_start (8); exception_content.set_margin_end (8);
        exception_content.set_margin_bottom (8);
        exception_content.append (exception_box);
        var add_exception = add_row_button ("Add Exception");
        exception_content.append (add_exception);
        exception_expander.add_row (exception_content);

        var advanced = new Adw.ExpanderRow ();
        advanced.title = "Advanced";
        advanced.subtitle = "Control how rules below this one are evaluated";
        var stop = new Adw.SwitchRow ();
        stop.title = "Stop processing later rules";
        stop.subtitle = "When this rule matches, rules below it will not run for that message.";
        stop.subtitle_lines = 2; advanced.add_row (stop);
        var fine_tune_group = new Adw.PreferencesGroup ();
        fine_tune_group.add (exception_expander); fine_tune_group.add (advanced);
        content.append (editor_section ("4", "Fine-tune the rule",
            "Optional exceptions and rule order.",
            fine_tune_group, "rule-editor-fine-tune"));

        var validation = new Gtk.Label (""); validation.xalign = 0; validation.wrap = true;
        validation.add_css_class ("caption"); validation.add_css_class ("error");
        validation.add_css_class ("rule-editor-validation");
        content.append (validation);

        if (existing == null) {
            var initial_condition = new MailRuleCondition (
                preset.field, preset.pattern, preset.operator);
            var initial_action = new MailRuleOperation (preset.action, preset.action_value);
            add_condition_row (cache, condition_box, conditions, initial_condition,
                false, initial_account_id);
            add_action_row (cache, action_box, actions, initial_action, initial_account_id);
        } else {
            name.text = existing.name; match_mode.selected = (uint) existing.match_mode;
            stop.active = existing.stop_processing;
            foreach (var item in existing.conditions)
                add_condition_row (cache, condition_box, conditions, item,
                    false, initial_account_id);
            foreach (var item in existing.exceptions)
                add_condition_row (cache, exception_box, exceptions, item,
                    true, initial_account_id);
            foreach (var item in existing.operations)
                add_action_row (cache, action_box, actions, item, initial_account_id);
            exception_expander.expanded = existing.exceptions.size > 0;
            advanced.expanded = existing.stop_processing;
        }

        var clamp = new Adw.Clamp (); clamp.maximum_size = 760; clamp.child = content;
        var scroller = new Gtk.ScrolledWindow (); scroller.child = clamp;
        scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        var dialog = new Adw.Dialog ();
        dialog.add_css_class ("rule-editor-dialog");
        dialog.add_css_class ("background");
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
        dialog.title = existing == null ? "New Rule" : "Edit Rule";
        bool qa_narrow = Environment.get_variable ("MAILFICIENT_QA_NARROW") == "1";
        dialog.set_size_request (qa_narrow ? 440 : 560, 460);
        dialog.content_width = qa_narrow ? 580 : 820;
        dialog.content_height = qa_narrow ? 660 : 680;
        var compact = new Adw.Breakpoint (
            new Adw.BreakpointCondition.length (
                Adw.BreakpointConditionLengthType.MAX_WIDTH, 700, Adw.LengthUnit.PX));
        compact.apply.connect (() => {
            details_box.orientation = Gtk.Orientation.VERTICAL;
            builder_columns.orientation = Gtk.Orientation.VERTICAL;
        });
        compact.unapply.connect (() => {
            details_box.orientation = Gtk.Orientation.HORIZONTAL;
            builder_columns.orientation = Gtk.Orientation.HORIZONTAL;
        });
        dialog.add_breakpoint (compact);
        var toolbar = new Adw.ToolbarView ();
        toolbar.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        header.show_start_title_buttons = false; header.show_end_title_buttons = false;
        var editor_title_label = new Gtk.Label (existing == null ? "New Rule" : "Edit Rule");
        editor_title_label.add_css_class ("heading");
        header.title_widget = editor_title_label;
        var cancel_button = new Gtk.Button.with_label ("Cancel");
        cancel_button.add_css_class ("flat"); header.pack_start (cancel_button);
        var save_button = new Gtk.Button.with_label (existing == null ? "Create Rule" : "Save Changes");
        save_button.add_css_class ("suggested-action"); header.pack_end (save_button);
        toolbar.add_top_bar (header); toolbar.content = scroller; dialog.child = toolbar;
        dialog.default_widget = save_button;

        SourceFunc update_validity = () => {
            bool valid = name.text.strip () != "" && conditions.size > 0 && actions.size > 0;
            string issue = name.text.strip () == "" ? "Give this rule a name." : "";
            foreach (var row in conditions) if (row.validation_issue () != "") {
                valid = false; issue = row.validation_issue ();
            }
            foreach (var row in exceptions) if (row.validation_issue () != "") {
                valid = false; issue = row.validation_issue ().replace ("condition", "exception");
            }
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
            bool terminal_transfer_seen = false;
            foreach (var row in actions) {
                var operation = row.value ();
                if ((operation.action == MailRuleAction.LABEL ||
                     operation.action == MailRuleAction.REMOVE_LABEL ||
                     operation.action == MailRuleAction.MOVE ||
                     operation.action == MailRuleAction.COPY) && operation.value == "") {
                    valid = false; issue = "Choose a label or destination for every action.";
                }
                if ((operation.action == MailRuleAction.MOVE ||
                     operation.action == MailRuleAction.COPY) &&
                    selected_account == "") {
                    valid = false; issue = "Move and copy actions require a specific account.";
                } else if ((operation.action == MailRuleAction.MOVE ||
                            operation.action == MailRuleAction.COPY) &&
                           row.destination_account_id () != selected_account) {
                    valid = false; issue = "Choose a destination from the rule’s account.";
                }
                bool terminal = operation.action == MailRuleAction.ARCHIVE ||
                    operation.action == MailRuleAction.TRASH ||
                    operation.action == MailRuleAction.MOVE ||
                    operation.action == MailRuleAction.MARK_JUNK ||
                    operation.action == MailRuleAction.MARK_NOT_JUNK;
                if ((terminal && terminal_transfer_seen) ||
                    (operation.action == MailRuleAction.COPY && terminal_transfer_seen)) {
                    valid = false; issue = terminal ? "A rule can move a message only once." :
                        "Place copy actions before the move action.";
                }
                if (terminal) terminal_transfer_seen = true;
            }
            preview_title.label = name.text.strip () == "" ?
                "Untitled rule" : name.text.strip ();
            preview_text.label = editor_preview_sentence (
                conditions, actions, (MailRuleMatchMode) match_mode.selected);
            string scope_name = account_names.get_string (account.selected);
            preview_scope.label = "Runs on this device • %s%s".printf (
                scope_name, exceptions.size == 0 ? "" :
                    " • %d %s".printf (exceptions.size,
                        exceptions.size == 1 ? "exception" : "exceptions"));
            validation.label = issue;
            validation.visible = !valid &&
                (name.text.strip () != "" || existing != null);
            save_button.sensitive = valid; return Source.REMOVE;
        };
        name.changed.connect (() => { update_validity (); });
        match_mode.notify["selected"].connect (() => { update_validity (); });
        stop.notify["active"].connect (() => { update_validity (); });
        account.notify["selected"].connect (() => {
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
            foreach (var row in conditions) row.set_account_scope (selected_account);
            foreach (var row in exceptions) row.set_account_scope (selected_account);
            foreach (var row in actions) row.set_account_scope (selected_account);
            update_validity ();
        });
        foreach (var row in conditions) row.changed.connect (() => { update_validity (); });
        foreach (var row in exceptions) row.changed.connect (() => { update_validity (); });
        foreach (var row in actions) row.changed.connect (() => { update_validity (); });
        add_condition.clicked.connect (() => {
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
            var row = add_condition_row (cache, condition_box, conditions,
                null, false, selected_account);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        add_exception.clicked.connect (() => {
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
            var row = add_condition_row (cache, exception_box, exceptions,
                null, true, selected_account);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        add_action.clicked.connect (() => {
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
            var row = add_action_row (cache, action_box, actions, null, selected_account);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        update_validity ();

        MailRule? result = null;
        bool finished = false;
        cancel_button.clicked.connect (() => dialog.close ());
        save_button.clicked.connect (() => {
            if (!save_button.sensitive) return;
            var first_condition = conditions[0].value ();
            var first_action = actions[0].value ();
            var candidate = new MailRule (existing == null ? 0 : existing.id,
                name.text.strip (), accounts[(int) account.selected],
                first_condition.field, first_condition.pattern,
                first_action.action, first_action.value,
                existing == null ? true : existing.enabled,
                existing == null ? 0 : existing.position,
                (MailRuleMatchMode) match_mode.selected, stop.active);
            candidate.replace_legacy_parts ();
            foreach (var row in conditions) candidate.conditions.add (row.value ());
            foreach (var row in exceptions) candidate.exceptions.add (row.value ());
            foreach (var row in actions) candidate.operations.add (row.value ());
            result = candidate;
            dialog.close ();
        });
        dialog.closed.connect (() => {
            if (finished) return;
            finished = true;
            choose.callback ();
        });
        ulong cancelled_handler = 0;
        if (cancellable != null)
            cancelled_handler = cancellable.cancelled.connect (() => dialog.close ());
        dialog.present (parent);
        yield;
        if (cancellable != null && cancelled_handler != 0)
            cancellable.disconnect (cancelled_handler);
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        return result;
    }

    private static Gtk.Widget editor_section (string number, string title,
                                               string description,
                                               Gtk.Widget section_content,
                                               string detail_class) {
        var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        section.add_css_class ("card"); section.add_css_class ("rule-editor-section");
        section.add_css_class (detail_class);
        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var step = new Gtk.Label (number);
        step.valign = Gtk.Align.START; step.add_css_class ("rule-editor-section-number");
        Accessibility.label (step, "Step " + number);
        header.append (step);
        var copy = new Gtk.Box (Gtk.Orientation.VERTICAL, 2); copy.hexpand = true;
        var heading = new Gtk.Label (title);
        heading.xalign = 0; heading.wrap = true; heading.add_css_class ("title-4");
        var detail = new Gtk.Label (description);
        detail.xalign = 0; detail.wrap = true; detail.add_css_class ("caption");
        detail.add_css_class ("dim-label");
        copy.append (heading);
        if (description != "") copy.append (detail);
        header.append (copy);
        section.append (header); section.append (section_content);
        return section;
    }

    private static string editor_preview_sentence (
        Gee.ArrayList<RuleConditionEditorRow> conditions,
        Gee.ArrayList<RuleActionEditorRow> actions,
        MailRuleMatchMode match_mode) {
        if (conditions.size == 0 || actions.size == 0)
            return "Choose at least one condition and one action.";
        var sentence = new StringBuilder ("When ");
        int index = 0;
        foreach (var row in conditions) {
            if (index >= 2) break;
            if (index > 0) sentence.append (
                match_mode == MailRuleMatchMode.ALL ? " and " : " or ");
            sentence.append (editor_condition_phrase (row.value ())); index++;
        }
        if (conditions.size > 2)
            sentence.append (" and %d more".printf (conditions.size - 2));
        sentence.append (", then "); index = 0;
        foreach (var row in actions) {
            if (index >= 2) break;
            if (index > 0) sentence.append (", then ");
            sentence.append (editor_action_phrase (row.value ())); index++;
        }
        if (actions.size > 2)
            sentence.append (" and %d more".printf (actions.size - 2));
        sentence.append (".");
        return sentence.str;
    }

    private static string editor_condition_phrase (MailRuleCondition condition) {
        string field;
        switch (condition.field) {
        case MailRuleField.SENDER: field = "the sender"; break;
        case MailRuleField.RECIPIENT: field = "a recipient"; break;
        case MailRuleField.SUBJECT: field = "the subject"; break;
        case MailRuleField.BODY: field = "the message body"; break;
        case MailRuleField.HAS_ATTACHMENT: field = "the message has an attachment"; break;
        case MailRuleField.IS_UNREAD: field = "the message is unread"; break;
        case MailRuleField.IS_FLAGGED: field = "the message is flagged"; break;
        case MailRuleField.CC: field = "Cc"; break;
        case MailRuleField.BCC: field = "Bcc"; break;
        case MailRuleField.ATTACHMENT_NAME: field = "an attachment name"; break;
        case MailRuleField.MESSAGE_SIZE: field = "the message size"; break;
        case MailRuleField.MAILBOX: field = "the folder"; break;
        case MailRuleField.REPLY_TO: field = "Reply-To"; break;
        case MailRuleField.DATE_RECEIVED: field = "the received date"; break;
        case MailRuleField.LABEL: field = "a label"; break;
        case MailRuleField.SECURITY_STATUS: field = "the security status"; break;
        case MailRuleField.MAILING_LIST: field = "the mailing list"; break;
        case MailRuleField.RAW_HEADERS: field = "the headers"; break;
        default: field = "the message"; break;
        }
        bool boolean_field = condition.field == MailRuleField.HAS_ATTACHMENT ||
            condition.field == MailRuleField.IS_UNREAD ||
            condition.field == MailRuleField.IS_FLAGGED;
        if (boolean_field)
            return condition.operator == MailRuleOperator.DOES_NOT_CONTAIN ?
                field + " is false" : field;
        string comparison;
        switch (condition.operator) {
        case MailRuleOperator.DOES_NOT_CONTAIN: comparison = "does not contain"; break;
        case MailRuleOperator.EQUALS: comparison = "is"; break;
        case MailRuleOperator.STARTS_WITH: comparison = "starts with"; break;
        case MailRuleOperator.ENDS_WITH: comparison = "ends with"; break;
        case MailRuleOperator.GREATER_THAN: comparison = "is greater than"; break;
        case MailRuleOperator.LESS_THAN: comparison = "is less than"; break;
        case MailRuleOperator.AFTER: comparison = "is after"; break;
        case MailRuleOperator.BEFORE: comparison = "is before"; break;
        default: comparison = "contains"; break;
        }
        string value = condition.pattern.strip ();
        if (condition.field == MailRuleField.MAILBOX)
            value = value == "" ? "a folder" : "the selected folder";
        else if (value == "") value = "…";
        else value = "“%s”".printf (value.replace ("\n", " ").replace ("\r", " "));
        return "%s %s %s".printf (field, comparison, value);
    }

    private static string editor_action_phrase (MailRuleOperation operation) {
        switch (operation.action) {
        case MailRuleAction.MARK_READ: return "mark it as read";
        case MailRuleAction.MARK_UNREAD: return "mark it as unread";
        case MailRuleAction.FLAG: return "flag it";
        case MailRuleAction.UNFLAG: return "remove its flag";
        case MailRuleAction.ARCHIVE: return "archive it";
        case MailRuleAction.TRASH: return "move it to Trash";
        case MailRuleAction.LABEL: return operation.value.strip () == "" ?
            "apply a label" : "apply the label “%s”".printf (operation.value.strip ());
        case MailRuleAction.REMOVE_LABEL: return operation.value.strip () == "" ?
            "remove a label" : "remove the label “%s”".printf (operation.value.strip ());
        case MailRuleAction.MOVE: return "move it to the selected folder";
        case MailRuleAction.COPY: return "copy it to the selected folder";
        case MailRuleAction.SET_FLAG_COLOR: return "set a %s flag".printf (
            operation.value == "" ? "colored" : operation.value);
        case MailRuleAction.MARK_JUNK: return "mark it as Junk";
        case MailRuleAction.MARK_NOT_JUNK: return "mark it as Not Junk";
        }
        return "apply the action";
    }

    private static Gtk.Button add_row_button (string title) {
        var content = new Adw.ButtonContent ();
        content.icon_name = "list-add-symbolic"; content.label = title;
        var button = new Gtk.Button (); button.child = content;
        button.halign = Gtk.Align.START; button.add_css_class ("flat");
        button.add_css_class ("rule-editor-add-row");
        return button;
    }

    internal static Gtk.Widget labeled (string title, Gtk.Widget child) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
        box.add_css_class ("rule-editor-field");
        box.hexpand = true;
        var label = new Gtk.Label (title); label.xalign = 0; label.add_css_class ("caption");
        box.append (label); box.append (child); return box;
    }

    private static RuleConditionEditorRow add_condition_row (
        CacheDatabase cache, Gtk.Box box, Gee.ArrayList<RuleConditionEditorRow> rows,
        MailRuleCondition? existing = null, bool allow_empty = false,
        string account_scope = "") {
        var row = new RuleConditionEditorRow (cache, existing, account_scope);
        rows.add (row); box.append (row);
        update_condition_remove_buttons (rows, allow_empty);
        row.remove.clicked.connect (() => {
            if (!allow_empty && rows.size <= 1) return;
            rows.remove (row); box.remove (row);
            update_condition_remove_buttons (rows, allow_empty);
            row.changed ();
        });
        return row;
    }

    private static void update_condition_remove_buttons (
        Gee.ArrayList<RuleConditionEditorRow> rows, bool allow_empty) {
        foreach (var item in rows) item.remove.sensitive = allow_empty || rows.size > 1;
    }

    internal static RuleActionEditorRow add_action_row (
        CacheDatabase cache, Gtk.Box box, Gee.ArrayList<RuleActionEditorRow> rows,
        MailRuleOperation? existing = null, string account_scope = "") {
        var row = new RuleActionEditorRow (cache, existing, account_scope);
        rows.add (row); box.append (row);
        update_action_remove_buttons (rows);
        row.remove.clicked.connect (() => {
            if (rows.size <= 1) return;
            rows.remove (row); box.remove (row); update_action_remove_buttons (rows);
            row.changed ();
        });
        return row;
    }

    private static void update_action_remove_buttons (
        Gee.ArrayList<RuleActionEditorRow> rows) {
        foreach (var item in rows) item.remove.sensitive = rows.size > 1;
    }
}

public class QuickStepEditorDialog : Object {
    public static async QuickStep? choose (Gtk.Window parent, CacheDatabase cache,
                                           Cancellable? cancellable = null) throws Error {
        var name = new Gtk.Entry (); name.placeholder_text = "Quick Step name";
        name.add_css_class ("quick-step-name-entry");
        Accessibility.label (name, "Quick Step name");
        var account_ids = new Gee.ArrayList<string> (); account_ids.add ("");
        var account_names = new Gtk.StringList (null); account_names.append ("All accounts");
        foreach (var item in cache.list_accounts ()) {
            account_ids.add (item.id);
            account_names.append ("%s — %s".printf (item.display_name, item.email));
        }
        var account = new Gtk.DropDown (account_names, null); account.hexpand = true;
        account.add_css_class ("quick-step-account-dropdown");
        Accessibility.label (account, "Quick Step account scope");
        Accessibility.description (account, "Quick Step account scope");
        var actions = new Gee.ArrayList<RuleActionEditorRow> ();
        var action_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        action_box.add_css_class ("quick-step-action-list");
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.add_css_class ("settings-subpage-editor");
        content.add_css_class ("quick-step-editor");

        var basics_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        basics_card.add_css_class ("settings-editor-card");
        basics_card.add_css_class ("quick-step-basics-card");
        var basics_title = new Gtk.Label ("Shortcut Details");
        basics_title.xalign = 0; basics_title.add_css_class ("settings-editor-heading");
        basics_card.append (basics_title);
        basics_card.append (RuleEditorDialog.labeled ("Name", name));
        basics_card.append (RuleEditorDialog.labeled ("Account", account));
        content.append (basics_card);

        var actions_card = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        actions_card.add_css_class ("settings-editor-card");
        actions_card.add_css_class ("quick-step-actions-card");
        var actions_title = new Gtk.Label ("Actions");
        actions_title.xalign = 0; actions_title.add_css_class ("settings-editor-heading");
        var actions_note = new Gtk.Label ("Actions run from top to bottom on the selected messages.");
        actions_note.xalign = 0; actions_note.wrap = true;
        actions_note.add_css_class ("settings-editor-note");
        actions_card.append (actions_title); actions_card.append (actions_note);
        actions_card.append (action_box);
        var add = new Gtk.Button.with_label ("Add Action"); add.halign = Gtk.Align.START;
        add.add_css_class ("settings-secondary-action");
        add.add_css_class ("quick-step-add-action");
        actions_card.append (add); content.append (actions_card);
        RuleEditorDialog.add_action_row (cache, action_box, actions);
        var dialog = new Adw.AlertDialog ("Add Quick Step",
            "Create a named one-click workflow for the selected messages.");
        dialog.add_css_class ("quick-step-editor-dialog");
        dialog.extra_child = content; dialog.add_response ("cancel", "Cancel"); dialog.add_response ("save", "Add Quick Step");
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "save"; dialog.close_response = "cancel";
        SourceFunc update_validity = () => {
            bool valid = name.text.strip () != "" && actions.size > 0;
            string selected_account = account.selected < account_ids.size ?
                account_ids[(int) account.selected] : "";
            foreach (var row in actions) {
                var operation = row.value ();
                if ((operation.action == MailRuleAction.LABEL ||
                     operation.action == MailRuleAction.MOVE ||
                     operation.action == MailRuleAction.COPY) && operation.value == "")
                    valid = false;
                if ((operation.action == MailRuleAction.MOVE ||
                     operation.action == MailRuleAction.COPY) &&
                    (selected_account == "" ||
                     row.destination_account_id () != selected_account))
                    valid = false;
            }
            dialog.set_response_enabled ("save", valid); return Source.REMOVE;
        };
        name.changed.connect (() => { update_validity (); });
        account.notify["selected"].connect (() => {
            string selected_account = account.selected < account_ids.size ?
                account_ids[(int) account.selected] : "";
            foreach (var row in actions) row.set_account_scope (selected_account);
            update_validity ();
        });
        foreach (var row in actions) row.changed.connect (() => { update_validity (); });
        add.clicked.connect (() => {
            string selected_account = account.selected < account_ids.size ?
                account_ids[(int) account.selected] : "";
            var row = RuleEditorDialog.add_action_row (
                cache, action_box, actions, null, selected_account);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        update_validity ();
        if ((yield dialog.choose (parent, cancellable)) != "save") return null;
        if (name.text.strip () == "") throw new MailError.STORAGE ("Enter a Quick Step name");
        var operations = new Gee.ArrayList<MailRuleOperation> ();
        string selected_account = account_ids[(int) account.selected];
        foreach (var row in actions) {
            var operation = row.value (); operations.add (operation);
            if (operation.action != MailRuleAction.MOVE &&
                operation.action != MailRuleAction.COPY) continue;
            if (selected_account == "")
                throw new MailError.STORAGE (
                    "Choose a specific account for move and copy actions");
            if (row.destination_account_id () != selected_account)
                throw new MailError.STORAGE (
                    "Choose a destination from the Quick Step account");
        }
        return cache.add_quick_step (name.text, selected_account, operations);
    }
}
}
