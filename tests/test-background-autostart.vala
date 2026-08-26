using Mailficient;

private const string AUTOSTART_ENTRY = """[Desktop Entry]
Type=Application
Name=Mailficient Background Delivery
Exec=mailficient --background
NoDisplay=true
""";

private void remove_test_tree (string root) {
    FileUtils.remove (Path.build_filename (root, "user", ".config", "autostart",
        "com.local.Mailficient.Background.desktop"));
    FileUtils.remove (Path.build_filename (root, "snap", "etc", "xdg", "autostart",
        "com.local.Mailficient.Background.desktop"));
    DirUtils.remove (Path.build_filename (root, "user", ".config", "autostart"));
    DirUtils.remove (Path.build_filename (root, "user", ".config"));
    DirUtils.remove (Path.build_filename (root, "user"));
    DirUtils.remove (Path.build_filename (root, "snap", "etc", "xdg", "autostart"));
    DirUtils.remove (Path.build_filename (root, "snap", "etc", "xdg"));
    DirUtils.remove (Path.build_filename (root, "snap", "etc"));
    DirUtils.remove (Path.build_filename (root, "snap"));
    DirUtils.remove (root);
}

private void test_snap_environment_detection () {
    assert_true (BackgroundAutostartService.is_snap_environment (
        "/snap/mailficient/current", "/home/user/snap/mailficient/current"));
    assert_false (BackgroundAutostartService.is_snap_environment (null,
        "/home/user/snap/mailficient/current"));
    assert_false (BackgroundAutostartService.is_snap_environment (
        "/snap/mailficient/current", null));
    assert_false (BackgroundAutostartService.is_snap_environment ("",
        "/home/user/snap/mailficient/current"));
    assert_false (BackgroundAutostartService.is_snap_environment (
        "/snap/mailficient/current", ""));
}

private void test_snap_autostart_copy () {
    string root = "";
    try {
        root = DirUtils.make_tmp ("mailficient-snap-autostart-XXXXXX");
        string snap_root = Path.build_filename (root, "snap");
        string snap_user_data = Path.build_filename (root, "user");
        string source_directory = Path.build_filename (snap_root, "etc", "xdg",
            "autostart");
        assert (DirUtils.create_with_parents (source_directory, 0700) == 0);
        string source = Path.build_filename (source_directory,
            "com.local.Mailficient.Background.desktop");
        FileUtils.set_contents (source, AUTOSTART_ENTRY);

        string? failure_message;
        assert_true (BackgroundAutostartService.install_snap_autostart_entry_for_paths (
            snap_root, snap_user_data, out failure_message));
        assert (failure_message == null);

        string destination = Path.build_filename (snap_user_data, ".config",
            "autostart", "com.local.Mailficient.Background.desktop");
        string copied;
        FileUtils.get_contents (destination, out copied);
        assert_cmpstr (copied, CompareOperator.EQ, AUTOSTART_ENTRY);
        var info = File.new_for_path (destination).query_info (
            FileAttribute.UNIX_MODE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        assert ((info.get_attribute_uint32 (FileAttribute.UNIX_MODE) & 0777) == 0600);
    } catch (Error error) {
        if (root != "") remove_test_tree (root);
        GLib.error ("Snap autostart copy test failed: %s", error.message);
    }
    if (root != "") remove_test_tree (root);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/background-autostart/snap-environment",
        test_snap_environment_detection);
    Test.add_func ("/background-autostart/copy-entry", test_snap_autostart_copy);
    return Test.run ();
}
