namespace Mailficient {
public class SignatureService : Object {
    private MailSettingsStore settings;

    public SignatureService (MailSettingsStore settings) { this.settings = settings; }

    public string configured_block_for (string account_id) {
        string value = settings.signature (account_id).strip ();
        return value == "" ? "" : "\n\n-- \n" + value;
    }

    public string block_for (string account_id) {
        if (!settings.signature_enabled (account_id)) return "";
        return configured_block_for (account_id);
    }

    public string apply (string account_id, string body, out string applied_block) {
        applied_block = block_for (account_id);
        return applied_block + body;
    }

    public string replace (string old_block, string account_id, string body, out string applied_block) {
        string replacement = block_for (account_id);
        int position = old_block == "" ? -1 : body.index_of (old_block);
        if (position >= 0) {
            applied_block = replacement;
            return body.substring (0, position) + replacement + body.substring (position + old_block.length);
        }
        if (body.strip () == "" && replacement != "") {
            applied_block = replacement; return replacement;
        }
        applied_block = "";
        return body;
    }
}
}
