namespace Mailficient {
// Camel's folders.db is a private, forward-incompatible EDS cache. Native and
// bundled Mailficient builds can use different EDS branches on the same home
// directory, so they must never reopen one another's folder-summary schema.
internal class CamelCacheNamespace : Object {
    internal static string leaf_for_version (int major, int minor) {
        return "camel-cache-eds-%d-%d".printf (
            int.max (0, major), int.max (0, minor));
    }

    internal static string path_for (string parent_directory) {
        return Path.build_filename (parent_directory, leaf_for_version (
            E.EDS_MAJOR_VERSION, E.EDS_MINOR_VERSION));
    }
}
}
