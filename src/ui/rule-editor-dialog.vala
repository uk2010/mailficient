namespace Mailficient {
internal class RuleConditionEditorRow : Gtk.Box {
    public signal void changed ();
    public Gtk.DropDown field = new Gtk.DropDown.from_strings ({
        "Sender", "Recipients", "Subject", "Body", "Has attachment", "Is unread", "Is flagged",
        "Cc", "Bcc", "Attachment name", "Message size", "Mailbox"
    });
    public Gtk.DropDown operator = new Gtk.DropDown.from_strings ({
        "contains", "does not contain", "equals", "starts with", "ends with", "is greater than", "is less than"
    });
    public Gtk.Entry pattern = new Gtk.Entry ();
    public new Gtk.Button remove = new Gtk.Button.from_icon_name ("list-remove-symbolic");

    public RuleConditionEditorRow (MailRuleCondition? existing = null) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 6);
        field.set_size_request (145, -1); operator.set_size_request (155, -1);
        pattern.hexpand = true; pattern.placeholder_text = "Value";
        Accessibility.label (field, "Condition field");
        Accessibility.description (field, "Condition field");
        Accessibility.label (operator, "Condition comparison");
        Accessibility.description (operator, "Condition comparison");
        Accessibility.label (pattern, "Condition value");
        remove.tooltip_text = "Remove condition"; Accessibility.label (remove, "Remove condition");
        append (field); append (operator); append (pattern); append (remove);
        field.notify["selected"].connect (() => { update_hint (); changed (); });
        operator.notify["selected"].connect (() => changed ());
        pattern.changed.connect (() => changed ());
        if (existing != null) {
            field.selected = (uint) existing.field; operator.selected = (uint) existing.operator;
            pattern.text = existing.pattern;
        }
        update_hint ();
    }

    public MailRuleCondition value () {
        return new MailRuleCondition ((MailRuleField) field.selected, pattern.text,
            (MailRuleOperator) operator.selected);
    }

    private void update_hint () {
        var selected_field = (MailRuleField) field.selected;
        bool boolean_field = selected_field == MailRuleField.HAS_ATTACHMENT ||
            selected_field == MailRuleField.IS_UNREAD ||
            selected_field == MailRuleField.IS_FLAGGED;
        if (boolean_field) {
            pattern.placeholder_text = "true or false";
            if ((MailRuleOperator) operator.selected != MailRuleOperator.DOES_NOT_CONTAIN)
                operator.selected = (uint) MailRuleOperator.EQUALS;
        } else if (selected_field == MailRuleField.MESSAGE_SIZE) {
            pattern.placeholder_text = "Size in bytes, KB, MB, or GB";
        } else {
            pattern.placeholder_text = "Value";
        }
    }
}

internal class RuleActionEditorRow : Gtk.Box {
    public signal void changed ();
    public Gtk.DropDown action = new Gtk.DropDown.from_strings ({
        "Mark read", "Flag", "Archive", "Move to Trash", "Apply label", "Mark unread", "Unflag",
        "Move to mailbox", "Copy to mailbox"
    });
    public Gtk.Entry value_entry = new Gtk.Entry ();
    public Gtk.DropDown destination;
    public new Gtk.Button remove = new Gtk.Button.from_icon_name ("list-remove-symbolic");
    private Gtk.Stack value_stack = new Gtk.Stack ();
    private Gee.ArrayList<string> destination_ids = new Gee.ArrayList<string> ();
    private Gee.ArrayList<string> destination_account_ids = new Gee.ArrayList<string> ();

    public RuleActionEditorRow (CacheDatabase cache, MailRuleOperation? existing = null) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 6);
        action.set_size_request (210, -1); value_entry.hexpand = true;
        value_entry.placeholder_text = "Label name";
        Accessibility.label (action, "Rule action");
        Accessibility.description (action, "Rule action");
        Accessibility.label (value_entry, "Action value");
        var destination_names = new Gtk.StringList (null);
        destination_names.append ("Choose a mailbox…"); destination_ids.add ("");
        destination_account_ids.add ("");
        try {
            foreach (var mailbox in cache.list_cached_mailboxes ()) {
                string account_name = mailbox.account_id;
                var account = cache.find_account (mailbox.account_id);
                if (account != null) account_name = account.email;
                destination_names.append ("%s — %s".printf (account_name, mailbox.name));
                destination_ids.add (mailbox.id);
                destination_account_ids.add (mailbox.account_id);
            }
        } catch (Error error) {
            warning ("Could not load rule destinations: %s", error.message);
        }
        destination = new Gtk.DropDown (destination_names, null);
        destination.hexpand = true;
        Accessibility.label (destination, "Destination mailbox");
        Accessibility.description (destination, "Destination mailbox");
        var no_value = new Gtk.Label ("No additional value needed");
        no_value.xalign = 0; no_value.add_css_class ("dim-label");
        value_stack.hexpand = true;
        value_stack.add_named (no_value, "none");
        value_stack.add_named (value_entry, "label");
        value_stack.add_named (destination, "mailbox");
        remove.tooltip_text = "Remove action"; Accessibility.label (remove, "Remove action");
        append (action); append (value_stack); append (remove);
        action.notify["selected"].connect (() => { update_hint (); changed (); });
        value_entry.changed.connect (() => changed ());
        destination.notify["selected"].connect (() => changed ());
        if (existing != null) {
            action.selected = (uint) existing.action; value_entry.text = existing.value;
            if (existing.action == MailRuleAction.MOVE || existing.action == MailRuleAction.COPY) {
                int selected = -1;
                for (int index = 0; index < destination_ids.size; index++)
                    if (destination_ids[index] == existing.value) { selected = index; break; }
                if (selected < 0 && existing.value != "") {
                    destination_names.append ("Unavailable mailbox — " + existing.value);
                    destination_ids.add (existing.value); destination_account_ids.add ("");
                    selected = destination_ids.size - 1;
                }
                if (selected >= 0) destination.selected = (uint) selected;
            }
        }
        update_hint ();
    }

    public MailRuleOperation value () {
        var selected_action = (MailRuleAction) action.selected;
        string value = "";
        if (selected_action == MailRuleAction.LABEL) value = value_entry.text;
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

    private void update_hint () {
        var selected_action = (MailRuleAction) action.selected;
        bool label = selected_action == MailRuleAction.LABEL;
        bool mailbox = selected_action == MailRuleAction.MOVE ||
            selected_action == MailRuleAction.COPY;
        value_stack.visible_child_name = label ? "label" : mailbox ? "mailbox" : "none";
    }
}

public class RuleEditorDialog : Object {
    public static async MailRule? choose (Gtk.Window parent, CacheDatabase cache,
                                          MailRule? existing = null,
                                          Cancellable? cancellable = null) throws Error {
        var accounts = new Gee.ArrayList<string> (); accounts.add ("");
        var account_names = new Gtk.StringList (null); account_names.append ("All accounts");
        foreach (var account in cache.list_accounts ()) {
            accounts.add (account.id); account_names.append ("%s — %s".printf (account.display_name, account.email));
        }
        var name = new Gtk.Entry (); name.placeholder_text = "Rule name"; name.hexpand = true;
        Accessibility.label (name, "Rule name");
        var account = new Gtk.DropDown (account_names, null); account.hexpand = true;
        Accessibility.label (account, "Rule account scope");
        Accessibility.description (account, "Rule account scope");
        var match_mode = new Gtk.DropDown.from_strings ({ "Match every condition (AND)", "Match any condition (OR)" });
        match_mode.hexpand = true; Accessibility.label (match_mode, "Condition matching mode");
        Accessibility.description (match_mode, "Condition matching mode");
        var stop = new Gtk.Switch (); stop.valign = Gtk.Align.CENTER;
        Accessibility.label (stop, "Stop processing later rules");

        var conditions = new Gee.ArrayList<RuleConditionEditorRow> ();
        var exceptions = new Gee.ArrayList<RuleConditionEditorRow> ();
        var actions = new Gee.ArrayList<RuleActionEditorRow> ();
        var condition_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var exception_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var action_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (8); content.set_margin_bottom (8);
        content.append (labeled ("Name", name)); content.append (labeled ("Account", account));
        content.append (labeled ("Conditions", match_mode)); content.append (condition_box);
        var add_condition = new Gtk.Button.with_label ("Add Condition"); add_condition.halign = Gtk.Align.START;
        content.append (add_condition);
        var exception_label = new Gtk.Label ("Exceptions"); exception_label.xalign = 0; exception_label.add_css_class ("heading");
        content.append (exception_label); content.append (exception_box);
        var add_exception = new Gtk.Button.with_label ("Add Exception"); add_exception.halign = Gtk.Align.START;
        content.append (add_exception);
        var action_label = new Gtk.Label ("Actions"); action_label.xalign = 0; action_label.add_css_class ("heading");
        content.append (action_label); content.append (action_box);
        var add_action = new Gtk.Button.with_label ("Add Action"); add_action.halign = Gtk.Align.START;
        content.append (add_action);
        var stop_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var stop_label = new Gtk.Label ("Stop processing later rules after this rule matches");
        stop_label.xalign = 0; stop_label.hexpand = true; stop_label.wrap = true;
        stop_row.append (stop_label); stop_row.append (stop); content.append (stop_row);

        if (existing == null) {
            add_condition_row (condition_box, conditions);
            add_action_row (cache, action_box, actions);
        } else {
            name.text = existing.name; match_mode.selected = (uint) existing.match_mode;
            stop.active = existing.stop_processing;
            for (int index = 0; index < accounts.size; index++)
                if (accounts[index] == existing.account_id) account.selected = (uint) index;
            foreach (var item in existing.conditions) add_condition_row (condition_box, conditions, item);
            foreach (var item in existing.exceptions) add_condition_row (exception_box, exceptions, item, true);
            foreach (var item in existing.operations) add_action_row (cache, action_box, actions, item);
        }

        var scroller = new Gtk.ScrolledWindow (); scroller.child = content;
        scroller.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_size_request (650, 500);
        var dialog = new Adw.AlertDialog (existing == null ? "Add Mail Rule" : "Edit Mail Rule",
            "Rules run in order. Exceptions always prevent the actions.");
        dialog.extra_child = scroller; dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("save", existing == null ? "Add Rule" : "Save Rule");
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "save"; dialog.close_response = "cancel";
        SourceFunc update_validity = () => {
            bool valid = name.text.strip () != "" && conditions.size > 0 && actions.size > 0;
            foreach (var row in conditions) if (row.pattern.text.strip () == "") valid = false;
            foreach (var row in exceptions) if (row.pattern.text.strip () == "") valid = false;
            string selected_account = account.selected < accounts.size ?
                accounts[(int) account.selected] : "";
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
        account.notify["selected"].connect (() => { update_validity (); });
        foreach (var row in conditions) row.changed.connect (() => { update_validity (); });
        foreach (var row in exceptions) row.changed.connect (() => { update_validity (); });
        foreach (var row in actions) row.changed.connect (() => { update_validity (); });
        add_condition.clicked.connect (() => {
            var row = add_condition_row (condition_box, conditions);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        add_exception.clicked.connect (() => {
            var row = add_condition_row (exception_box, exceptions, null, true);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        add_action.clicked.connect (() => {
            var row = add_action_row (cache, action_box, actions);
            row.changed.connect (() => { update_validity (); }); update_validity ();
        });
        update_validity ();
        if ((yield dialog.choose (parent, cancellable)) != "save") return null;
        if (name.text.strip () == "" || conditions.size == 0 || actions.size == 0)
            throw new MailError.STORAGE ("Enter a rule name with at least one condition and action");
        var first_condition = conditions[0].value (); var first_action = actions[0].value ();
        var result = new MailRule (existing == null ? 0 : existing.id, name.text.strip (),
            accounts[(int) account.selected], first_condition.field, first_condition.pattern,
            first_action.action, first_action.value, existing == null ? true : existing.enabled,
            existing == null ? 0 : existing.position, (MailRuleMatchMode) match_mode.selected, stop.active);
        result.replace_legacy_parts ();
        foreach (var row in conditions) {
            var item = row.value (); if (item.pattern.strip () == "") throw new MailError.STORAGE ("Every condition needs a value");
            result.conditions.add (item);
        }
        foreach (var row in exceptions) {
            var item = row.value (); if (item.pattern.strip () == "") throw new MailError.STORAGE ("Every exception needs a value");
            result.exceptions.add (item);
        }
        foreach (var row in actions) result.operations.add (row.value ());
        foreach (var row in actions) {
            var operation = row.value ();
            if (operation.action != MailRuleAction.MOVE &&
                operation.action != MailRuleAction.COPY) continue;
            string selected_account = accounts[(int) account.selected];
            if (selected_account == "")
                throw new MailError.STORAGE (
                    "Choose a specific account for move and copy actions");
            if (row.destination_account_id () != selected_account)
                throw new MailError.STORAGE (
                    "Choose a destination from the rule account");
        }
        return result;
    }

    internal static Gtk.Widget labeled (string title, Gtk.Widget child) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        var label = new Gtk.Label (title); label.xalign = 0; label.add_css_class ("caption");
        box.append (label); box.append (child); return box;
    }

    private static RuleConditionEditorRow add_condition_row (
        Gtk.Box box, Gee.ArrayList<RuleConditionEditorRow> rows,
        MailRuleCondition? existing = null, bool allow_empty = false) {
        var row = new RuleConditionEditorRow (existing); rows.add (row); box.append (row);
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
        MailRuleOperation? existing = null) {
        var row = new RuleActionEditorRow (cache, existing); rows.add (row); box.append (row);
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
        Accessibility.label (name, "Quick Step name");
        var account_ids = new Gee.ArrayList<string> (); account_ids.add ("");
        var account_names = new Gtk.StringList (null); account_names.append ("All accounts");
        foreach (var item in cache.list_accounts ()) {
            account_ids.add (item.id);
            account_names.append ("%s — %s".printf (item.display_name, item.email));
        }
        var account = new Gtk.DropDown (account_names, null); account.hexpand = true;
        Accessibility.label (account, "Quick Step account scope");
        Accessibility.description (account, "Quick Step account scope");
        var actions = new Gee.ArrayList<RuleActionEditorRow> ();
        var action_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
        content.append (RuleEditorDialog.labeled ("Name", name));
        content.append (RuleEditorDialog.labeled ("Account", account));
        content.append (action_box);
        var add = new Gtk.Button.with_label ("Add Action"); add.halign = Gtk.Align.START;
        content.append (add);
        RuleEditorDialog.add_action_row (cache, action_box, actions);
        var dialog = new Adw.AlertDialog ("Add Quick Step",
            "Create a named one-click workflow for the selected messages.");
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
        account.notify["selected"].connect (() => { update_validity (); });
        foreach (var row in actions) row.changed.connect (() => { update_validity (); });
        add.clicked.connect (() => {
            var row = RuleEditorDialog.add_action_row (cache, action_box, actions);
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
