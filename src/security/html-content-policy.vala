namespace Mailficient {
public class HtmlContentPolicy : Object {
    private const int MAX_REMOTE_URI_BYTES = 8192;

    public static string document (string sanitized_html, bool allow_remote_content,
                                   string print_header_html = "") {
        string image_sources = allow_remote_content ? "data: cid: https:" : "data: cid:";
        string policy = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; " +
            "connect-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'; " +
            "style-src 'unsafe-inline'; img-src " + image_sources;
        return "<!doctype html><html><head><meta charset='utf-8'>" +
            "<meta http-equiv='Content-Security-Policy' content=\"%s\">".printf (policy) +
            "<meta name='viewport' content='width=device-width, initial-scale=1'>" +
            "<meta name='color-scheme' content='light'>" +
            "<style>html{box-sizing:border-box;width:100%;max-width:100%;overflow-x:hidden;background:#fff;color:#000;color-scheme:light}" +
            "html,body{min-width:0}" +
            "body{box-sizing:border-box;width:100%;min-width:0;max-width:100%;font:16px system-ui;margin:0;" +
            "padding:clamp(12px,4vw,24px);" +
            "line-height:1.5;overflow-wrap:break-word;background:#fff;color:#000}" +
            "body>*{max-width:100%}" +
            "img,svg,video{max-width:100%!important;height:auto!important;object-fit:contain}" +
            "table{max-width:100%}" +
            "td,th{overflow-wrap:break-word}" +
            "h1,h2,h3,h4,h5,h6,p,div,span,a{max-width:100%;overflow-wrap:break-word}" +
            "pre,code{white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word}" +
            "blockquote{max-width:100%;margin-inline:1em;border-inline-start:3px solid currentColor;" +
            "padding-inline-start:1em;opacity:.85}" +
            ".mailficient-print-header{display:none}" +
            "@media print{@page{margin:14mm}html,body{max-width:none;overflow:visible}" +
            "body{margin:0;font-size:12pt;line-height:1.4}" +
            ".mailficient-print-header{display:block;margin:0 0 18pt;padding:0 0 12pt;" +
            "border-bottom:1px solid #bbb;break-after:avoid}" +
            ".mailficient-print-header h1{font-size:18pt;line-height:1.2;margin:0 0 9pt}" +
            ".mailficient-print-header p{font-size:10pt;line-height:1.35;margin:2pt 0;color:#333}" +
            "img,blockquote,tr{break-inside:avoid}}</style>" +
            "</head><body>" + print_header_html + sanitized_html +
            "</body></html>";
    }

    public static bool allows_resource (string uri, bool allow_remote_content) {
        string normalized = uri.strip ().down ();
        if (normalized == "about:blank" || normalized.has_prefix ("cid:")) return true;
        if (normalized.has_prefix ("data:image/png;base64,") ||
            normalized.has_prefix ("data:image/jpeg;base64,") ||
            normalized.has_prefix ("data:image/gif;base64,") ||
            normalized.has_prefix ("data:image/webp;base64,")) return true;
        return allow_remote_content && is_safe_remote_image_uri (uri);
    }

    public static bool is_safe_remote_image_uri (string value) {
        string candidate = value.strip ();
        if (candidate == "" || candidate.length > MAX_REMOTE_URI_BYTES ||
            candidate != value || has_control (candidate)) return false;
        try {
            var uri = Uri.parse (candidate, UriFlags.NONE);
            string? host_value = uri.get_host ();
            string host = host_value == null ? "" : host_value.down ();
            if (uri.get_scheme ().down () != "https" || host == "" ||
                uri.get_userinfo () != null ||
                (uri.get_port () != -1 && uri.get_port () != 443)) return false;
            return is_public_host (host);
        } catch (UriError error) {
            return false;
        }
    }

    public static bool is_public_host (string value) {
        string host = value.strip ().down ();
        while (host.has_suffix (".")) host = host.substring (0, host.length - 1);
        if (host == "" || host.length > 253 || host == "localhost" ||
            host.has_suffix (".localhost") || host.has_suffix (".local") ||
            host.has_suffix (".internal") || host.has_suffix (".home.arpa") ||
            !host.contains (".")) return false;

        InetAddress? literal = new InetAddress.from_string (host);
        if (literal == null)
            return valid_dns_hostname (host) && !looks_like_legacy_ipv4 (host);
        if (literal.is_any || literal.is_loopback || literal.is_link_local ||
            literal.is_site_local || literal.is_multicast) return false;
        unowned uint8[] bytes = literal.to_bytes ();
        if (literal.family == SocketFamily.IPV4) {
            // Cover ranges not classified as site-local by GLib: shared,
            // benchmarking, documentation, reserved, and link-local space.
            return !(bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 ||
                bytes[0] >= 224 ||
                (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0) ||
                (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) ||
                (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) ||
                (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113));
        }
        // IPv6 unique-local and documentation space are not public fetch
        // destinations even when a platform does not mark them site-local.
        return !((bytes[0] & 0xfe) == 0xfc ||
            (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8));
    }

    private static bool valid_dns_hostname (string host) {
        foreach (string label in host.split (".")) {
            if (label == "" || label.length > 63 || label.has_prefix ("-") ||
                label.has_suffix ("-")) return false;
            for (int index = 0; index < label.length; index++) {
                char character = label[index];
                if (!(character.isalnum () || character == '-')) return false;
            }
        }
        return true;
    }

    private static bool looks_like_legacy_ipv4 (string host) {
        string[] labels = host.split (".");
        if (labels.length < 1 || labels.length > 4) return false;
        foreach (string label in labels) {
            string digits = label;
            int radix = 10;
            if (label.has_prefix ("0x") && label.length > 2) {
                digits = label.substring (2);
                radix = 16;
            }
            if (digits == "") return false;
            for (int index = 0; index < digits.length; index++) {
                char character = digits[index];
                if (radix == 10 && !character.isdigit ()) return false;
                if (radix == 16 && !character.isxdigit ()) return false;
            }
        }
        return true;
    }

    private static bool has_control (string value) {
        for (int index = 0; index < value.length;) {
            unichar character = value.get_char (index);
            if (character.iscntrl () || character == 0x2028 || character == 0x2029)
                return true;
            index += character.to_utf8 (null);
        }
        return false;
    }
}
}
