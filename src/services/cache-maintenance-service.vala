namespace Mailficient {
public class CacheMaintenanceService : Object {
    private CacheDatabase cache;
    private string[] managed_directories;

    public CacheMaintenanceService (CacheDatabase cache, string[] managed_directories) {
        this.cache = cache;
        this.managed_directories = managed_directories;
    }

    public CacheMaintenanceResult run () throws MailError {
        var result = new CacheMaintenanceResult ();
        var referenced = cache.referenced_attachment_paths ();
        foreach (var path in referenced) {
            if (!is_managed_path (path) || FileUtils.test (path, FileTest.EXISTS)) continue;
            try { cache.forget_attachment_path (path); result.removed_records++; }
            catch (Error error) { result.failures++; warning ("Could not reconcile a missing attachment: %s", error.message); }
        }
        referenced = cache.referenced_attachment_paths ();
        foreach (var directory in managed_directories) clean_directory (directory, referenced, result);
        cache.checkpoint ();
        return result;
    }

    private void clean_directory (string directory, Gee.Set<string> referenced,
                                  CacheMaintenanceResult result) {
        if (!FileUtils.test (directory, FileTest.IS_DIR)) return;
        try {
            var folder = File.new_for_path (directory);
            var children = folder.enumerate_children (FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file ()) != null) {
                if (info.get_file_type () != FileType.REGULAR && info.get_file_type () != FileType.SYMBOLIC_LINK) continue;
                string path = Path.build_filename (directory, info.get_name ());
                if (referenced.contains (path)) continue;
                try { File.new_for_path (path).delete (); result.deleted_files++; }
                catch (Error error) { result.failures++; warning ("Could not remove an orphaned attachment: %s", error.message); }
            }
            children.close ();
        } catch (Error error) {
            result.failures++; warning ("Could not inspect private attachment storage: %s", error.message);
        }
    }

    private bool is_managed_path (string path) {
        if (path == "" || path.contains ("://")) return false;
        string parent = Path.get_dirname (path);
        foreach (var directory in managed_directories)
            if (File.new_for_path (parent).equal (File.new_for_path (directory))) return true;
        return false;
    }
}
}
