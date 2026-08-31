private const string ENVIRONMENT = "{\"id\":\"ubuntu-test\",\"name\":\"Ubuntu test\",\"version\":\"26.04\",\"origin\":\"github.com/containerpak/ubuntu\",\"policy\":{\"network\":true,\"displayX11\":true,\"socketWayland\":true,\"socketPulseAudio\":true,\"deviceAlsa\":true,\"deviceUsb\":true,\"deviceInput\":true,\"hostActions\":[{\"provider\":\"containers\",\"capabilities\":[\"read\"]}],\"filesystem\":[{\"path\":\"home\",\"access\":\"read-write\"}]}}";
private const string PERMISSIONS = "{\"network\":true,\"displayX11\":true,\"socketWayland\":true,\"socketPulseAudio\":true,\"deviceAlsa\":true,\"deviceUsb\":true,\"deviceInput\":true,\"hostActions\":[{\"provider\":\"containers\",\"capabilities\":[\"read\"]}],\"filesystem\":[{\"path\":\"home\",\"access\":\"read-write\"}]}";
private const string DESKTOP_ENTRY = "[Desktop Entry]\nType=Application\nName=Example application\nComment=Example from the environment\nExec=/usr/bin/example %U\nIcon=example\n";

private int fail (string message) {
    stderr.printf ("%s\n", message);
    return 1;
}

private string argument_value (string[] args, string name) {
    for (int index = 1; index + 1 < args.length; index++) {
        if (args[index] == name)
            return args[index + 1];
    }
    return "";
}

private string export_path (string[] args) {
    string environment = argument_value (args, "--environment");
    string application = argument_value (args, "--application");
    string digest = Checksum.compute_for_string (
        ChecksumType.SHA256,
        environment + "\n" + application
    );
    return Path.build_filename (
        Environment.get_home_dir (),
        ".local",
        "share",
        "applications",
        "cpak-environment-" + digest + ".desktop"
    );
}

int main (string[] args) {
    if (args.length >= 3 && args[1] == "discover" && args[2] == "list") {
        string? lock_once = Environment.get_variable ("ATOMS_CPAK_LOCK_ONCE");
        if (lock_once != null && lock_once != "" && !FileUtils.test (lock_once, FileTest.EXISTS)) {
            try {
                FileUtils.set_contents (lock_once, "retried\n");
            } catch (Error error) {
                return fail (error.message);
            }
            return fail ("Error: wal: lock test: wal: directory is already open");
        }
        stdout.printf ("{\"schema\":1,\"release\":\"test\",\"packages\":[{\"origin\":\"github.com/containerpak/ubuntu\",\"name\":\"Ubuntu\",\"description\":\"Ubuntu test distribution\",\"icon_svg\":\"<svg xmlns='http://www.w3.org/2000/svg'/>\",\"available_version\":\"26.04\",\"installed\":true,\"installable\":true},{\"origin\":\"github.com/containerpak/other\",\"name\":\"Other\",\"description\":\"Not a distribution\",\"available_version\":\"1\",\"installed\":false,\"installable\":true}]}\n");
        return 0;
    }
    if (args.length >= 4 && args[1] == "discover" && args[2] == "install")
        return 0;
    if (args.length < 3 || args[1] != "environment")
        return fail ("unsupported fake cpak command");

    switch (args[2]) {
        case "list":
            stdout.printf ("[%s]\n", ENVIRONMENT);
            return 0;
        case "create":
            stdout.printf ("%s\n", ENVIRONMENT);
            return 0;
        case "policy":
            var input = new StringBuilder ();
            string? line;
            while ((line = stdin.read_line ()) != null)
                input.append (line);
            stdout.printf ("{\"id\":\"ubuntu-test\",\"name\":\"Ubuntu test\",\"version\":\"26.04\",\"origin\":\"github.com/containerpak/ubuntu\",\"policy\":%s}\n", input.str);
            return 0;
        case "permissions":
            stdout.printf ("%s\n", PERMISSIONS);
            return 0;
        case "processes":
            stdout.printf ("[{\"pid\":42,\"command\":\"/bin/bash\",\"cpu_percent\":1.5,\"memory_bytes\":2097152,\"can_signal\":true}]\n");
            return 0;
        case "shell":
            foreach (var argument in args) {
                if (argument.index_of ("APPLICATION_LIST") >= 0)
                    return fail ("unexpected test marker");
                if (argument.index_of ("/usr/share/applications") >= 0) {
                    stdout.printf (
                        "%s\t%s\n",
                        Base64.encode ("/usr/share/applications/example.desktop".data),
                        Base64.encode (DESKTOP_ENTRY.data)
                    );
                    return 0;
                }
                if (argument.index_of ("desktop=$1") >= 0) {
                    uint8[] png = { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
                    stdout.printf ("png\t%s\n", Base64.encode (png));
                    return 0;
                }
            }
            return fail ("unsupported fake cpak environment shell");
        case "application-exports":
            string application = "/usr/share/applications/example.desktop";
            string[] lookup = {
                args[0],
                args[1],
                args[2],
                "--environment",
                argument_value (args, "--environment"),
                "--application",
                application
            };
            if (FileUtils.test (export_path (lookup), FileTest.IS_REGULAR))
                stdout.printf ("[\"%s\"]\n", application);
            else
                stdout.printf ("[]\n");
            return 0;
        case "export-application":
            var input = new StringBuilder ();
            string? line;
            while ((line = stdin.read_line ()) != null)
                input.append (line);
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (input.str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                    return fail ("invalid application export");
                var request = root.get_object ();
                string path = export_path (args);
                if (DirUtils.create_with_parents (Path.get_dirname (path), 0755) != 0)
                    return fail ("could not create application export directory");
                var key_file = new KeyFile ();
                key_file.set_string ("Desktop Entry", "Type", "Application");
                key_file.set_string ("Desktop Entry", "Name", request.get_string_member ("name"));
                key_file.set_string ("Desktop Entry", "Exec", request.get_string_member ("command"));
                key_file.set_string ("Desktop Entry", "X-cpak-Environment", argument_value (args, "--environment"));
                key_file.set_string ("Desktop Entry", "X-cpak-Environment-Application", argument_value (args, "--application"));
                size_t length;
                string data = key_file.to_data (out length);
                FileUtils.set_contents (path, data, (ssize_t) length);
            } catch (Error error) {
                return fail (error.message);
            }
            stdout.printf ("{\"application\":\"%s\",\"exported\":true}\n", argument_value (args, "--application"));
            return 0;
        case "unexport-application":
            FileUtils.remove (export_path (args));
            stdout.printf ("{\"application\":\"%s\",\"exported\":false}\n", argument_value (args, "--application"));
            return 0;
        case "signals":
            stdout.printf ("[\"TERM\",\"KILL\"]\n");
            return 0;
        case "signal":
        case "stop":
        case "delete":
            return 0;
        default:
            return fail ("unsupported fake cpak environment command");
    }
}
