namespace Mailficient {
public class HtmlSanitizer : Object {
    private const int MAX_INPUT_BYTES = 8 * 1024 * 1024;
    private const int MAX_TREE_DEPTH = 128;
    private const int MAX_DATA_IMAGE_BYTES = 5 * 1024 * 1024;
    private const int MAX_STYLE_BYTES = 4096;
    private const int MAX_STYLESHEET_BYTES = 256 * 1024;

    public static string sanitize (string html, bool allow_remote_content = false,
                                   bool full_html_formatting = false) {
        if (html.length > MAX_INPUT_BYTES)
            return "<p>This message is too large to display safely as HTML.</p>";

        int options = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR |
            Html.ParserOption.NOWARNING | Html.ParserOption.NONET | Html.ParserOption.COMPACT;
        Html.Doc* document = Html.Doc.read_memory ((char[]) html.data, html.length,
            "about:blank", "UTF-8", options);
        if (document == null) return "";

        var output = new StringBuilder ();
        Xml.Node* root = document->get_root_element ();
        if (root != null)
            serialize_children (root, output, allow_remote_content, full_html_formatting, 0);
        delete document;
        return output.str;
    }

    public static string to_plain_text (string html) {
        if (html.strip () == "" || html.length > MAX_INPUT_BYTES) return "";

        int options = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR |
            Html.ParserOption.NOWARNING | Html.ParserOption.NONET | Html.ParserOption.COMPACT;
        Html.Doc* document = Html.Doc.read_memory ((char[]) html.data, html.length,
            "about:blank", "UTF-8", options);
        if (document == null) return "";

        var output = new StringBuilder ();
        Xml.Node* root = document->get_root_element ();
        if (root != null) append_plain_children (root, output, 0);
        delete document;
        return normalize_plain_text (output.str);
    }

    public static bool has_remote_content (string html) {
        if (html.strip () == "" || html.length > MAX_INPUT_BYTES) return false;

        int options = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR |
            Html.ParserOption.NOWARNING | Html.ParserOption.NONET | Html.ParserOption.COMPACT;
        Html.Doc* document = Html.Doc.read_memory ((char[]) html.data, html.length,
            "about:blank", "UTF-8", options);
        if (document == null) return false;

        Xml.Node* root = document->get_root_element ();
        bool remote = root != null && node_has_remote_content (root, 0);
        delete document;
        return remote;
    }

    private static bool node_has_remote_content (Xml.Node* node, int depth) {
        if (depth >= MAX_TREE_DEPTH) return false;
        if (node->type == Xml.ElementType.ELEMENT_NODE) {
            string element = ((string) node->name).down ();
            for (Xml.Attr* attribute = node->properties;
                 attribute != null; attribute = attribute->next) {
                if (attribute->ns != null) continue;
                string name = ((string) attribute->name).down ();
                string value = attribute->children == null ? "" :
                    attribute->children->get_content ();
                bool fetch_attribute = name == "src" || name == "srcset" ||
                    name == "background" || name == "poster" || name == "style" ||
                    (element == "link" && name == "href");
                if (fetch_attribute && contains_remote_url (value)) return true;
            }
            if (element == "style" && contains_remote_url (node->get_content ()))
                return true;
        }
        for (Xml.Node* child = node->children; child != null; child = child->next)
            if (node_has_remote_content (child, depth + 1)) return true;
        return false;
    }

    private static bool contains_remote_url (string value) {
        string normalized = value.down ();
        return normalized.contains ("http://") || normalized.contains ("https://");
    }

    private static void append_plain_children (Xml.Node* parent, StringBuilder output, int depth) {
        if (depth >= MAX_TREE_DEPTH) return;
        for (Xml.Node* child = parent->children; child != null; child = child->next)
            append_plain_node (child, output, depth + 1);
    }

    private static void append_plain_node (Xml.Node* node, StringBuilder output, int depth) {
        if (depth >= MAX_TREE_DEPTH) return;
        if (node->type == Xml.ElementType.TEXT_NODE ||
            node->type == Xml.ElementType.CDATA_SECTION_NODE) {
            output.append (node->content ?? "");
            return;
        }
        if (node->type != Xml.ElementType.ELEMENT_NODE) return;

        string name = ((string) node->name).down ();
        if (discard_with_contents (name, false)) return;
        bool block = plain_block_element (name);
        if (block) append_plain_break (output);
        if (name == "li") output.append ("• ");
        if (name == "br") append_plain_break (output);
        else if (name == "img") {
            string alt = node->get_prop ("alt") ?? "";
            if (alt.strip () != "") output.append ("[").append (alt.strip ()).append ("]");
        } else {
            append_plain_children (node, output, depth);
        }
        if (block) append_plain_break (output);
    }

    private static bool plain_block_element (string name) {
        switch (name) {
        case "address": case "article": case "aside": case "blockquote":
        case "caption": case "dd": case "details": case "div": case "dl":
        case "dt": case "figcaption": case "figure": case "footer":
        case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
        case "header": case "hr": case "li": case "main": case "ol": case "p":
        case "pre": case "section": case "summary": case "table": case "tbody":
        case "td": case "tfoot": case "th": case "thead": case "tr": case "ul":
            return true;
        default:
            return false;
        }
    }

    private static void append_plain_break (StringBuilder output) {
        if (output.len > 0 && output.str[output.len - 1] != '\n') output.append_c ('\n');
    }

    private static string normalize_plain_text (string text) {
        var output = new StringBuilder ();
        bool pending_space = false;
        int newline_count = 0;
        for (int index = 0; index < text.length;) {
            unichar character = text.get_char (index);
            index += character.to_utf8 (null);
            if (character == '\r') continue;
            if (character == '\n') {
                pending_space = false;
                newline_count++;
                continue;
            }
            if (character.isspace ()) {
                pending_space = output.len > 0;
                continue;
            }
            if (newline_count > 0) {
                int breaks = int.min (2, newline_count);
                while (breaks-- > 0 && output.len > 0) output.append_c ('\n');
            } else if (pending_space && output.len > 0) {
                output.append_c (' ');
            }
            newline_count = 0;
            pending_space = false;
            output.append_unichar (character);
        }
        return output.str.strip ();
    }

    private static void serialize_children (Xml.Node* parent, StringBuilder output,
                                            bool allow_remote_content,
                                            bool full_html_formatting, int depth) {
        if (depth >= MAX_TREE_DEPTH) return;
        for (Xml.Node* child = parent->children; child != null; child = child->next)
            serialize_node (child, output, allow_remote_content, full_html_formatting, depth + 1);
    }

    private static void serialize_node (Xml.Node* node, StringBuilder output,
                                        bool allow_remote_content,
                                        bool full_html_formatting, int depth) {
        if (depth >= MAX_TREE_DEPTH) return;
        if (node->type == Xml.ElementType.TEXT_NODE ||
            node->type == Xml.ElementType.CDATA_SECTION_NODE) {
            output.append (Markup.escape_text (node->content ?? ""));
            return;
        }
        if (node->type != Xml.ElementType.ELEMENT_NODE) return;

        string name = ((string) node->name).down ();
        if (name == "head") {
            serialize_children (node, output, allow_remote_content, full_html_formatting, depth);
            return;
        }
        if (discard_with_contents (name, full_html_formatting)) return;
        if (name == "style") {
            string? stylesheet = safe_stylesheet (node->get_content ());
            if (stylesheet == null) return;
            output.append ("<style>");
            output.append (stylesheet.replace ("<", "\\3c "));
            output.append ("</style>");
            return;
        }
        if (!allowed_element (name, full_html_formatting)) {
            serialize_children (node, output, allow_remote_content, full_html_formatting, depth);
            return;
        }

        output.append_c ('<'); output.append (name);
        serialize_attributes (node, name, output, allow_remote_content, full_html_formatting);
        output.append_c ('>');
        if (!void_element (name)) {
            serialize_children (node, output, allow_remote_content, full_html_formatting, depth);
            output.append ("</"); output.append (name); output.append_c ('>');
        }
    }

    private static void serialize_attributes (Xml.Node* node, string element,
                                              StringBuilder output, bool allow_remote_content,
                                              bool full_html_formatting) {
        for (Xml.Attr* attribute = node->properties; attribute != null; attribute = attribute->next) {
            if (attribute->ns != null) continue;
            string name = ((string) attribute->name).down ();
            string value = attribute->children == null ? "" : attribute->children->get_content ();
            string? safe = safe_attribute (
                element, name, value, allow_remote_content, full_html_formatting);
            if (safe == null) continue;
            output.append_c (' '); output.append (name); output.append ("=\"");
            output.append (Markup.escape_text (safe)); output.append_c ('\"');
        }
        if (element == "a") output.append (" rel=\"noreferrer noopener\"");
    }

    private static string? safe_attribute (string element, string name, string value,
                                           bool allow_remote_content,
                                           bool full_html_formatting) {
        if (name == "title" || name == "dir" || name == "lang" || name == "aria-label")
            return value;
        if (name == "style") return safe_style (value);
        if (name == "class" || name == "id") return safe_css_identifier_list (value, name == "class");
        if (element == "a" && name == "href") return safe_link (value);
        if (element == "img" && name == "src") return safe_image (value, allow_remote_content);
        if (element == "img" && (name == "alt" || name == "width" || name == "height"))
            return safe_dimension_or_text (name, value);
        if (full_html_formatting &&
            (element == "table" || element == "tr" || element == "td" || element == "th") &&
            (name == "bgcolor" || name == "bordercolor")) return safe_color (value);
        if (full_html_formatting && element == "font" && name == "color")
            return safe_color (value);
        if (full_html_formatting && element == "font" && name == "face")
            return safe_font_face (value);
        if (full_html_formatting && element == "font" && name == "size")
            return safe_font_size (value);
        if ((element == "td" || element == "th") &&
            (name == "colspan" || name == "rowspan" || name == "width" || name == "height"))
            return safe_positive_number (value);
        if ((element == "td" || element == "th" || element == "tr" || element == "table") &&
            (name == "align" || name == "valign")) return safe_alignment (name, value);
        if (element == "table" &&
            (name == "width" || name == "cellpadding" || name == "cellspacing" || name == "border"))
            return safe_positive_number (value);
        return null;
    }

    // Email clients rely heavily on inline CSS for layout. Keep the useful,
    // presentation-only subset while rejecting every property that can load a
    // resource, execute script, or position content over the application UI.
    private static string? safe_style (string value) {
        string source = value.strip ();
        if (source == "" || source.length > MAX_STYLE_BYTES || has_unsafe_css_token (source))
            return null;
        var output = new StringBuilder ();
        int accepted = 0;
        foreach (string raw_declaration in source.split (";")) {
            string declaration = raw_declaration.strip ();
            int separator = declaration.index_of_char (':');
            if (separator <= 0 || separator + 1 >= declaration.length) continue;
            string property = declaration.substring (0, separator).strip ().down ();
            string property_value = declaration.substring (separator + 1).strip ();
            if (!safe_style_property (property) || !safe_style_value (property_value)) continue;
            if (accepted++ > 0) output.append ("; ");
            output.append (property); output.append (": "); output.append (property_value);
        }
        return accepted == 0 ? null : output.str;
    }

    private static bool safe_style_property (string property) {
        switch (property) {
        case "color": case "background": case "background-color":
        case "font": case "font-family": case "font-size": case "font-style":
        case "font-weight": case "line-height": case "text-align":
        case "text-decoration": case "text-transform": case "letter-spacing":
        case "white-space": case "vertical-align": case "width": case "height":
        case "min-width": case "max-width": case "min-height": case "max-height":
        case "margin": case "margin-top": case "margin-right": case "margin-bottom":
        case "margin-left": case "padding": case "padding-top": case "padding-right":
        case "padding-bottom": case "padding-left": case "border": case "border-top":
        case "border-right": case "border-bottom": case "border-left":
        case "border-color": case "border-style": case "border-width":
        case "border-radius": case "display": case "float": case "clear":
        case "overflow": case "overflow-wrap": case "word-break": case "opacity":
            return true;
        default:
            return false;
        }
    }

    private static bool safe_style_value (string value) {
        if (value == "" || value.length > 1024 || has_unsafe_css_token (value)) return false;
        for (int index = 0; index < value.length; index++) {
            char character = value[index];
            if (character.iscntrl () || character == '<' || character == '>' ||
                character == '{' || character == '}' || character == ';') return false;
        }
        return true;
    }

    private static bool has_unsafe_css_token (string value) {
        string lower = value.down ();
        return lower.contains ("url(") || lower.contains ("expression") ||
            lower.contains ("javascript") || lower.contains ("vbscript") ||
            lower.contains ("behavior") || lower.contains ("-moz-binding") ||
            lower.contains ("@import") || lower.contains ("data:") ||
            lower.contains ("http:") || lower.contains ("https:") ||
            lower.contains ("file:") || lower.contains ("var(");
    }

    private static string? safe_css_identifier_list (string value, bool allow_list) {
        string source = value.strip ();
        if (source == "" || source.length > 512 || has_control_character (source)) return null;
        string[] identifiers = allow_list ? source.split_set (" \t\r\n") : new string[] { source };
        var output = new StringBuilder ();
        int accepted = 0;
        foreach (string identifier in identifiers) {
            if (identifier == "") continue;
            if (identifier.length > 128 || !safe_css_identifier (identifier)) return null;
            if (accepted++ > 0) output.append_c (' ');
            output.append (identifier);
        }
        return accepted == 0 ? null : output.str;
    }

    private static bool safe_css_identifier (string value) {
        if (value == "") return false;
        char first = value[0];
        if (!(first.isalpha () || first == '_' || first == '-')) return false;
        for (int index = 1; index < value.length; index++) {
            char character = value[index];
            if (!(character.isalnum () || character == '_' || character == '-')) return false;
        }
        return true;
    }

    private static bool has_control_character (string value) {
        for (int index = 0; index < value.length; index++) {
            char character = value[index];
            if ((character == '\t' || character == '\n' || character == '\r') ||
                !character.iscntrl ()) continue;
            return true;
        }
        return false;
    }

    private static string? safe_stylesheet (string value) {
        if (value.strip () == "" || value.length > MAX_STYLESHEET_BYTES ||
            has_control_character (value) || value.contains ("<")) return null;
        string lower = value.down ();
        if (has_unsafe_css_token (value) || lower.contains ("@font-face") ||
            lower.contains ("@keyframes")) return null;
        return value;
    }

    private static string safe_link (string value) {
        string normalized = value.strip ();
        string lower = normalized.down ();
        if (lower.has_prefix ("https://") || lower.has_prefix ("http://") ||
            lower.has_prefix ("mailto:") || normalized.has_prefix ("#")) return normalized;
        return "about:blank";
    }

    private static string safe_image (string value, bool allow_remote_content) {
        string normalized = value.strip ();
        string lower = normalized.down ();
        if (lower.has_prefix ("cid:")) return normalized;
        if (lower.has_prefix ("data:image/png;base64,") ||
            lower.has_prefix ("data:image/jpeg;base64,") ||
            lower.has_prefix ("data:image/gif;base64,") ||
            lower.has_prefix ("data:image/webp;base64,"))
            return safe_data_image (normalized) ? normalized : "about:blank";
        if (allow_remote_content && HtmlContentPolicy.is_safe_remote_image_uri (normalized))
            return normalized;
        return "about:blank";
    }

    private static bool safe_data_image (string value) {
        int comma = value.index_of_char (',');
        if (comma < 0 || comma + 1 >= value.length) return false;
        string media_type = value.substring (5, comma - 5).split (";", 2)[0].down ();
        uint8[] decoded = Base64.decode (value.substring (comma + 1));
        if (decoded.length == 0 || decoded.length > MAX_DATA_IMAGE_BYTES ||
            !AttachmentSafety.preview_signature_matches (
                AttachmentPreviewKind.IMAGE, media_type, decoded, decoded.length))
            return false;
        int width;
        int height;
        return AttachmentSafety.preview_image_dimensions_are_safe (
            media_type, decoded, decoded.length, out width, out height);
    }

    private static string? safe_dimension_or_text (string name, string value) {
        return name == "alt" ? value : safe_positive_number (value);
    }

    private static string? safe_positive_number (string value) {
        string normalized = value.strip ();
        if (normalized.length == 0 || normalized.length > 6) return null;
        int digit_count = normalized.has_suffix ("%") ? normalized.length - 1 : normalized.length;
        if (digit_count == 0) return null;
        for (int index = 0; index < digit_count; index++)
            if (normalized[index] < '0' || normalized[index] > '9') return null;
        return normalized;
    }

    private static string? safe_alignment (string name, string value) {
        string normalized = value.strip ().down ();
        if (name == "align" && (normalized == "left" || normalized == "center" || normalized == "right"))
            return normalized;
        if (name == "valign" && (normalized == "top" || normalized == "middle" || normalized == "bottom"))
            return normalized;
        return null;
    }

    private static string? safe_color (string value) {
        string normalized = value.strip ();
        if (normalized.length == 0 || normalized.length > 24) return null;
        if (normalized[0] == '#') {
            int digits = normalized.length - 1;
            if (digits != 3 && digits != 4 && digits != 6 && digits != 8) return null;
            for (int index = 1; index < normalized.length; index++)
                if (!normalized[index].isxdigit ()) return null;
            return normalized;
        }
        for (int index = 0; index < normalized.length; index++)
            if (!normalized[index].isalpha () && normalized[index] != '-') return null;
        return normalized;
    }

    private static string? safe_font_face (string value) {
        string normalized = value.strip ();
        if (normalized.length == 0 || normalized.length > 128) return null;
        for (int index = 0; index < normalized.length; index++) {
            char character = normalized[index];
            if (!(character.isalnum () || character.isspace () || character == '-' ||
                  character == '_' || character == ',' || character == '\'')) return null;
        }
        return normalized;
    }

    private static string? safe_font_size (string value) {
        string normalized = value.strip ();
        if (normalized.length == 0 || normalized.length > 2) return null;
        int start = (normalized[0] == '+' || normalized[0] == '-') ? 1 : 0;
        if (start == normalized.length) return null;
        for (int index = start; index < normalized.length; index++)
            if (!normalized[index].isdigit ()) return null;
        int size = int.parse (normalized.substring (start));
        return size >= 1 && size <= 7 ? normalized : null;
    }

    private static bool discard_with_contents (string name, bool full_html_formatting) {
        switch (name) {
        case "head":
        case "title":
        case "script": case "iframe": case "object": case "embed":
        case "form": case "svg": case "math": case "template": case "canvas":
        case "audio": case "video": case "noscript":
            return true;
        default:
            return false;
        }
    }

    private static bool allowed_element (string name, bool full_html_formatting) {
        if (name == "style") return true;
        switch (name) {
        case "a": case "abbr": case "address": case "article": case "aside":
        case "b": case "bdi": case "bdo": case "blockquote": case "br": case "caption":
        case "center": case "cite": case "code": case "col": case "colgroup": case "dd": case "del":
        case "details": case "dfn": case "div": case "dl": case "dt": case "em":
        case "figcaption": case "figure": case "font": case "footer": case "h1": case "h2": case "h3":
        case "h4": case "h5": case "h6": case "header": case "hr": case "i": case "img":
        case "ins": case "kbd": case "li": case "main": case "mark": case "ol": case "p":
        case "pre": case "q": case "s": case "samp": case "section": case "small":
        case "span": case "strong": case "sub": case "summary": case "sup": case "table":
        case "tbody": case "td": case "tfoot": case "th": case "thead": case "time":
        case "tr": case "u": case "ul": case "var": case "wbr":
            return true;
        default:
            return false;
        }
    }

    private static bool void_element (string name) {
        return name == "br" || name == "hr" || name == "img" || name == "col" || name == "wbr";
    }
}
}
