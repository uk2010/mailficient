namespace Mailficient {
public class Attachment : Object {
    public string id { get; construct; }
    public string path { get; construct; }
    public string name { get; construct; }
    public int64 size { get; construct; }
    public string content_type { get; construct; }
    public string content_id { get; construct; }
    public int remote_part_index { get; construct; }

    public Attachment (string id, string path, string name, int64 size, string content_type,
                       string content_id = "", int remote_part_index = 0) {
        Object (id: id, path: path, name: name, size: size, content_type: content_type,
                content_id: content_id, remote_part_index: remote_part_index);
    }

    public bool is_downloaded () { return path != ""; }

    public string formatted_size () {
        if (size <= 0) return "Size unavailable";
        if (size >= 1024 * 1024) return "%.1f MB".printf ((double) size / (1024.0 * 1024.0));
        if (size >= 1024) return "%.1f KB".printf ((double) size / 1024.0);
        return "%s bytes".printf (size.to_string ());
    }
}
}
