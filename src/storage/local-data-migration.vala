namespace Mailficient {
public class LocalDataMigration : Object {
    public static string prepare (string data_home) throws MailError {
        string destination_path = Path.build_filename (data_home, "mailficient");
        if (FileUtils.test (destination_path, FileTest.IS_DIR)) return destination_path;

        string legacy_path = Path.build_filename (data_home, "personal-mail");
        if (!FileUtils.test (legacy_path, FileTest.IS_DIR)) {
            create_private_directory (destination_path);
            return destination_path;
        }

        string staging_path = Path.build_filename (data_home,
            ".mailficient-migration-%s".printf (Uuid.string_random ()));
        try {
            copy_directory (File.new_for_path (legacy_path), File.new_for_path (staging_path));
            string staged_database = Path.build_filename (staging_path, "mail.db");
            if (FileUtils.test (staged_database, FileTest.IS_REGULAR))
                rewrite_attachment_paths (staged_database, legacy_path, destination_path);
            File.new_for_path (staging_path).move (File.new_for_path (destination_path),
                FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
        } catch (Error error) {
            try { remove_staging_directory (File.new_for_path (staging_path)); }
            catch (Error cleanup_error) {
                warning ("Could not remove failed migration staging data: %s", cleanup_error.message);
            }
            throw new MailError.STORAGE ("Could not migrate existing Mailficient data: %s".printf (error.message));
        }
        return destination_path;
    }

    private static void rewrite_attachment_paths (string database_path, string legacy_path,
                                                  string destination_path) throws MailError {
        Sqlite.Database database;
        if (Sqlite.Database.open (database_path, out database) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not open the staged legacy mail database");
        execute_database (database, "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE");
        try {
            foreach (string table in new string[] { "draft_attachments", "message_attachments" }) {
                if (!database_has_table (database, table)) continue;
                Sqlite.Statement statement;
                string sql = "UPDATE " + table + " SET path=? || substr(path,?) " +
                    "WHERE substr(path,1,?)=? AND (length(path)=? OR substr(path,?,1)='/')";
                if (database.prepare_v2 (sql, -1, out statement) != Sqlite.OK)
                    throw new MailError.STORAGE ("Could not prepare migrated attachment paths");
                int legacy_length = legacy_path.length;
                statement.bind_text (1, destination_path);
                statement.bind_int (2, legacy_length + 1);
                statement.bind_int (3, legacy_length);
                statement.bind_text (4, legacy_path);
                statement.bind_int (5, legacy_length);
                statement.bind_int (6, legacy_length + 1);
                if (statement.step () != Sqlite.DONE)
                    throw new MailError.STORAGE ("Could not update migrated attachment paths");
            }
            execute_database (database, "COMMIT");
            execute_database (database, "PRAGMA wal_checkpoint(TRUNCATE)");
        } catch (MailError error) {
            try { execute_database (database, "ROLLBACK"); } catch (MailError ignored) { }
            throw error;
        }
    }

    private static bool database_has_table (Sqlite.Database database, string table) throws MailError {
        Sqlite.Statement statement;
        if (database.prepare_v2 (
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
                -1, out statement) != Sqlite.OK)
            throw new MailError.STORAGE ("Could not inspect the staged mail database");
        statement.bind_text (1, table);
        int row = statement.step ();
        if (row != Sqlite.ROW && row != Sqlite.DONE)
            throw new MailError.STORAGE ("Could not inspect staged attachment storage");
        return row == Sqlite.ROW;
    }

    private static void execute_database (Sqlite.Database database, string sql) throws MailError {
        string? detail = null;
        if (database.exec (sql, null, out detail) != Sqlite.OK)
            throw new MailError.STORAGE (detail ?? "Could not update the staged mail database");
    }

    private static void copy_directory (File source, File destination) throws Error {
        destination.make_directory_with_parents (null);
        string? destination_path = destination.get_path ();
        if (destination_path != null) FileUtils.chmod (destination_path, 0700);
        var children = source.enumerate_children ("standard::name,standard::type",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        FileInfo? info;
        while ((info = children.next_file (null)) != null) {
            var source_child = source.get_child (info.get_name ());
            var destination_child = destination.get_child (info.get_name ());
            if (info.get_file_type () == FileType.DIRECTORY)
                copy_directory (source_child, destination_child);
            else if (info.get_file_type () == FileType.REGULAR)
                source_child.copy (destination_child,
                    FileCopyFlags.ALL_METADATA | FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
        }
    }

    private static void remove_staging_directory (File directory) throws Error {
        if (!directory.query_exists (null)) return;
        var children = directory.enumerate_children ("standard::name,standard::type",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        FileInfo? info;
        while ((info = children.next_file (null)) != null) {
            var child = directory.get_child (info.get_name ());
            if (info.get_file_type () == FileType.DIRECTORY)
                remove_staging_directory (child);
            else child.delete (null);
        }
        children.close (null);
        directory.delete (null);
    }

    private static void create_private_directory (string path) throws MailError {
        if (DirUtils.create_with_parents (path, 0700) != 0)
            throw new MailError.STORAGE ("Could not create the local Mailficient data directory");
        FileUtils.chmod (path, 0700);
    }
}
}
