namespace Mailficient {
public class HtmlContentPolicy : Object {
    public static string document (string sanitized_html, bool allow_remote_content,
                                   string print_header_html = "") {
        string image_sources = allow_remote_content ? "data: cid: https: http:" : "data: cid:";
        string policy = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; " +
            "connect-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'; " +
            "style-src 'unsafe-inline'; img-src " + image_sources;
        return "<!doctype html><html><head><meta charset='utf-8'>" +
            "<meta http-equiv='Content-Security-Policy' content=\"%s\">".printf (policy) +
            "<meta name='viewport' content='width=device-width, initial-scale=1'>" +
            "<meta name='color-scheme' content='light'>" +
            "<style>html{max-width:100%;overflow-x:hidden;background:#fff;color:#000;color-scheme:light}" +
            "body{box-sizing:border-box;max-width:100%;font:16px system-ui;margin:clamp(12px,4vw,24px);" +
            "line-height:1.5;overflow-wrap:anywhere;word-break:break-word;background:#fff;color:#000}" +
            "img{max-width:100%!important;height:auto!important;object-fit:contain}" +
            "table{max-width:100%!important;border-collapse:collapse;table-layout:auto}" +
            "td,th{max-width:100%;overflow-wrap:anywhere;word-break:break-word}" +
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
            "</head><body>" + print_header_html + sanitized_html + "</body></html>";
    }

    public static bool allows_resource (string uri, bool allow_remote_content) {
        string normalized = uri.strip ().down ();
        if (normalized == "about:blank" || normalized.has_prefix ("cid:")) return true;
        if (normalized.has_prefix ("data:image/png;base64,") ||
            normalized.has_prefix ("data:image/jpeg;base64,") ||
            normalized.has_prefix ("data:image/gif;base64,") ||
            normalized.has_prefix ("data:image/webp;base64,")) return true;
        return allow_remote_content &&
            (normalized.has_prefix ("https://") || normalized.has_prefix ("http://"));
    }
}
}
