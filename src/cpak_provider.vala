using Gee;
using Json;

namespace Atoms {

    private errordomain CpakProviderError {
        INVALID_RESPONSE
    }

    private class CommandResult : GLib.Object {
        public bool ok { get; construct; }
        public string stdout_text { get; construct; }
        public string stderr_text { get; construct; }
        public int exit_code { get; construct; }

        public CommandResult (bool ok,
                              string stdout_text,
                              string stderr_text,
                              int exit_code) {
            GLib.Object (
                ok: ok,
                stdout_text: stdout_text,
                stderr_text: stderr_text,
                exit_code: exit_code
            );
        }
    }

    public class CpakProvider : GLib.Object, Provider {
        private const string STORE_INDEX =
            "https://raw.githubusercontent.com/Containerpak/store/main/index.json";
        private const size_t MAX_STORE_BYTES = 8 * 1024 * 1024;
        private string[] command_prefix;
        private HashMap<string, string> icons;

        public string id { owned get { return "cpak"; } }
        public string name { owned get { return "cpak"; } }
        public uint abi_version { get { return PROVIDER_ABI; } }
        public bool available { get { return command_prefix.length > 0; } }
        public string unavailable_reason {
            owned get {
                return available
                    ? ""
                    : "cpak is not installed or cannot be reached from Atoms";
            }
        }

        construct {
            command_prefix = resolve_command_prefix ();
            icons = new HashMap<string, string> ();
        }

        public async ArrayList<Distribution> list_distributions (
            Cancellable? cancellable = null
        ) throws Error {
            require_available ();
            var store = yield load_store (cancellable);
            var store_root = store.get_root ();
            if (store_root == null || store_root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak Store returned an invalid index");
            var root_object = store_root.get_object ();
            if (!root_object.has_member ("Distributions"))
                throw invalid_response ("cpak Store has no Distributions category");
            unowned Json.Node? category_node = root_object.get_member ("Distributions");
            if (category_node == null || category_node.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak Store has an invalid Distributions category");
            var category = category_node.get_object ();

            var catalog_result = yield run ({ "discover", "list" }, null, cancellable);
            ensure_success (catalog_result);
            var catalog = parse (catalog_result.stdout_text, "cpak discovery catalog");
            var catalog_root = catalog.get_root ();
            if (catalog_root == null || catalog_root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak returned an invalid discovery catalog");
            var catalog_object = catalog_root.get_object ();
            if (!catalog_object.has_member ("packages"))
                throw invalid_response ("cpak discovery catalog has no packages");
            unowned Json.Node? packages_node = catalog_object.get_member ("packages");
            if (packages_node == null || packages_node.get_node_type () != NodeType.ARRAY)
                throw invalid_response ("cpak discovery catalog has invalid packages");

            var packages = new HashMap<string, Json.Object> ();
            foreach (var node in packages_node.get_array ().get_elements ()) {
                if (node.get_node_type () != NodeType.OBJECT)
                    continue;
                var package = node.get_object ();
                string origin = string_member (package, "origin");
                if (origin != "")
                    packages[origin] = package;
            }

            var distributions = new ArrayList<Distribution> ();
            foreach (unowned string origin in category.get_members ()) {
                var package = packages[origin];
                if (package == null)
                    continue;
                string icon_path = cache_icon (
                    origin,
                    string_member (package, "icon_svg"),
                    string_member (package, "icon_png")
                );
                icons[origin] = icon_path;
                distributions.add (new Distribution (
                    id,
                    origin,
                    required_string (package, "name"),
                    string_member (package, "available_version"),
                    string_member (package, "description"),
                    origin,
                    icon_path
                ));
            }
            distributions.sort ((a, b) => strcmp (a.name, b.name));
            return distributions;
        }

        public async ArrayList<Environment> list_environments (
            Cancellable? cancellable = null
        ) throws Error {
            require_available ();
            if (icons.size == 0) {
                try {
                    yield list_distributions (cancellable);
                } catch (Error error) {
                    debug ("Could not load cpak distribution artwork: %s", error.message);
                }
            }

            var result = yield run (
                { "environment", "list", "--json" },
                null,
                cancellable
            );
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak environment list");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.ARRAY)
                throw invalid_response ("cpak returned an invalid environment list");

            var environments = new ArrayList<Environment> ();
            foreach (var node in root.get_array ().get_elements ()) {
                if (node.get_node_type () != NodeType.OBJECT)
                    throw invalid_response ("cpak returned an invalid environment entry");
                environments.add (yield environment_from_json (
                    node.get_object (),
                    cancellable
                ));
            }
            return environments;
        }

        public async Environment create_environment (
            Distribution distribution,
            string environment_name,
            Cancellable? cancellable = null
        ) throws Error {
            require_available ();
            if (distribution.provider_id != id)
                throw new CoreError.INVALID_DATA ("distribution belongs to another provider");
            string normalized_name = environment_name.strip ();
            if (normalized_name == "" || normalized_name.length > 80)
                throw new CoreError.INVALID_DATA ("environment name must contain 1 to 80 characters");

            var install = yield run (
                { "discover", "install", distribution.origin },
                null,
                cancellable
            );
            ensure_success (install);

            var create = yield run ({
                "environment",
                "create",
                "--name",
                normalized_name,
                "--origin",
                distribution.origin,
                "--json"
            }, null, cancellable);
            ensure_success (create);
            var parser = parse (create.stdout_text, "cpak environment");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak returned an invalid environment");
            return yield environment_from_json (root.get_object (), cancellable);
        }

        public string[] shell_argv (Environment environment,
                                    string command,
                                    string[] arguments) throws Error {
            require_environment (environment);
            string selected_command = command.strip ();
            if (selected_command == "")
                selected_command = "/bin/bash";

            var values = new ArrayList<string> ();
            foreach (var prefix in command_prefix)
                values.add (prefix);
            foreach (var value in new string[] {
                "environment",
                "shell",
                "--environment",
                environment.id,
                "--command",
                selected_command
            })
                values.add (value);
            foreach (var argument in arguments)
                values.add (argument);

            var argv = new string[values.size];
            for (int i = 0; i < values.size; i++)
                argv[i] = values[i];
            return argv;
        }

        public async Environment update_policy (
            Environment environment,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            var policy = parse_policy_data (environment.provider_data);
            var ceiling = yield permission_ceiling (environment.id, cancellable);
            apply_policy (policy, ceiling, environment.policy);
            var root = new Json.Node (NodeType.OBJECT);
            root.set_object (policy);
            var generator = new Json.Generator ();
            generator.set_root (root);

            var result = yield run ({
                "environment",
                "policy",
                "--environment",
                environment.id,
                "--policy",
                "-",
                "--json"
            }, generator.to_data (null), cancellable);
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak environment");
            var response_root = parser.get_root ();
            if (response_root == null || response_root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak returned an invalid environment");
            return yield environment_from_json (response_root.get_object (), cancellable);
        }

        public async ArrayList<ProcessInfo> list_processes (
            Environment environment,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            var result = yield run ({
                "environment",
                "processes",
                "--environment",
                environment.id,
                "--json"
            }, null, cancellable);
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak process list");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.ARRAY)
                throw invalid_response ("cpak returned an invalid process list");

            var processes = new ArrayList<ProcessInfo> ();
            foreach (var node in root.get_array ().get_elements ()) {
                if (node.get_node_type () != NodeType.OBJECT)
                    throw invalid_response ("cpak returned an invalid process entry");
                var process = node.get_object ();
                if (!process.has_member ("pid") || !process.has_member ("command"))
                    throw invalid_response ("cpak process data is incomplete");
                processes.add (new ProcessInfo (
                    (int) process.get_int_member ("pid"),
                    process.get_string_member ("command"),
                    double_member (process, "cpu_percent"),
                    uint_member (process, "memory_bytes"),
                    boolean_member (process, "can_signal")
                ));
            }
            return processes;
        }

        public async string[] list_signals (
            Cancellable? cancellable = null
        ) throws Error {
            require_available ();
            var result = yield run ({ "environment", "signals", "--json" }, null, cancellable);
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak signal list");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.ARRAY)
                throw invalid_response ("cpak returned an invalid signal list");

            var values = new ArrayList<string> ();
            foreach (var node in root.get_array ().get_elements ()) {
                string value = node.get_string ();
                if (value != "")
                    values.add (value);
            }
            var signals = new string[values.size];
            for (int i = 0; i < values.size; i++)
                signals[i] = values[i];
            return signals;
        }

        public async void signal_process (
            Environment environment,
            int pid,
            string signal_name,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            if (pid <= 0)
                throw new CoreError.INVALID_DATA ("process id must be positive");
            var result = yield run ({
                "environment",
                "signal",
                "--environment",
                environment.id,
                "--pid",
                pid.to_string (),
                "--signal",
                signal_name
            }, null, cancellable);
            ensure_success (result);
        }

        public async void stop_environment (
            Environment environment,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            var result = yield run ({
                "environment",
                "stop",
                "--environment",
                environment.id
            }, null, cancellable);
            ensure_success (result);
        }

        public async void delete_environment (
            Environment environment,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            var result = yield run ({
                "environment",
                "delete",
                "--environment",
                environment.id
            }, null, cancellable);
            ensure_success (result);
        }

        private async Environment environment_from_json (
            Json.Object object,
            Cancellable? cancellable
        ) throws Error {
            string environment_id = required_string (object, "id");
            string origin = required_string (object, "origin");
            Json.Object policy = object.has_member ("policy")
                ? object.get_object_member ("policy")
                : new Json.Object ();
            var ceiling = yield permission_ceiling (environment_id, cancellable);
            string policy_data = object_data (policy);
            return new Environment (
                id,
                environment_id,
                required_string (object, "name"),
                string_member (object, "version"),
                origin,
                icons[origin] ?? "",
                policy_data,
                policy_from_json (policy, ceiling)
            );
        }

        private async Json.Object permission_ceiling (
            string environment_id,
            Cancellable? cancellable
        ) throws Error {
            var result = yield run ({
                "environment",
                "permissions",
                "--environment",
                environment_id,
                "--json"
            }, null, cancellable);
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak environment permissions");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak returned invalid permissions");
            return root.get_object ();
        }

        private EnvironmentPolicy policy_from_json (Json.Object policy,
                                                      Json.Object ceiling) {
            return new EnvironmentPolicy () {
                network = boolean_member (policy, "network"),
                home = has_home_permission (policy),
                display = has_display_permission (policy),
                usb = boolean_member (policy, "deviceUsb"),
                input = boolean_member (policy, "deviceInput"),
                host_commands = has_host_actions (policy),
                can_network = boolean_member (ceiling, "network"),
                can_home = has_home_permission (ceiling),
                can_display = has_display_permission (ceiling),
                can_usb = boolean_member (ceiling, "deviceUsb"),
                can_input = boolean_member (ceiling, "deviceInput"),
                can_host_commands = has_host_actions (ceiling)
            };
        }

        private void apply_policy (Json.Object raw,
                                   Json.Object ceiling,
                                   EnvironmentPolicy selected) {
            selected.clamp ();
            raw.set_boolean_member (
                "network",
                selected.network && boolean_member (ceiling, "network")
            );
            foreach (var member in new string[] {
                "displayX11",
                "socketX11",
                "socketWayland"
            }) {
                raw.set_boolean_member (
                    member,
                    selected.display && boolean_member (ceiling, member)
                );
            }
            raw.set_boolean_member (
                "deviceUsb",
                selected.usb && boolean_member (ceiling, "deviceUsb")
            );
            raw.set_boolean_member (
                "deviceInput",
                selected.input && boolean_member (ceiling, "deviceInput")
            );
            if (selected.host_commands && ceiling.has_member ("hostActions")) {
                raw.set_array_member (
                    "hostActions",
                    copy_array (ceiling.get_array_member ("hostActions"))
                );
            } else {
                raw.set_array_member ("hostActions", new Json.Array ());
            }
            update_home_permission (raw, ceiling, selected.home);
        }

        private void update_home_permission (Json.Object policy,
                                             Json.Object ceiling,
                                             bool enabled) {
            var permissions = new Json.Array ();
            if (policy.has_member ("filesystem")) {
                foreach (var node in policy.get_array_member ("filesystem").get_elements ()) {
                    if (node.get_node_type () == NodeType.OBJECT &&
                        string_member (node.get_object (), "path") == "home")
                        continue;
                    permissions.add_element (node.copy ());
                }
            }
            if (enabled && ceiling.has_member ("filesystem")) {
                foreach (var node in ceiling.get_array_member ("filesystem").get_elements ()) {
                    if (node.get_node_type () == NodeType.OBJECT &&
                        string_member (node.get_object (), "path") == "home")
                        permissions.add_element (node.copy ());
                }
            }
            policy.set_array_member ("filesystem", permissions);
        }

        private static Json.Array copy_array (Json.Array source) {
            var copy = new Json.Array ();
            foreach (var node in source.get_elements ())
                copy.add_element (node.copy ());
            return copy;
        }

        private async Json.Parser load_store (Cancellable? cancellable) throws Error {
            string source = GLib.Environment.get_variable ("ATOMS_CPAK_STORE_INDEX")
                ?? STORE_INDEX;
            if (GLib.Path.is_absolute (source)) {
                string contents;
                FileUtils.get_contents (source, out contents);
                if (contents.length > MAX_STORE_BYTES)
                    throw invalid_response ("cpak Store index exceeds the size limit");
                return parse (contents, "cpak Store index");
            }
            if (!source.has_prefix ("https://"))
                throw new CoreError.INVALID_DATA ("cpak Store index must use HTTPS");

            var session = new Soup.Session ();
            session.timeout = 30;
            var message = new Soup.Message ("GET", source);
            var bytes = yield session.send_and_read_async (
                message,
                Priority.DEFAULT,
                cancellable
            );
            if (message.status_code != Soup.Status.OK)
                throw new CoreError.PROVIDER_FAILED (
                    "cpak Store returned HTTP %u".printf (message.status_code)
                );
            if (bytes.length > MAX_STORE_BYTES)
                throw invalid_response ("cpak Store index exceeds the size limit");

            unowned uint8[] data = bytes.get_data ();
            var parser = new Json.Parser ();
            parser.load_from_data ((string) data, (ssize_t) data.length);
            return parser;
        }

        private string cache_icon (string origin,
                                   string vector,
                                   string raster) {
            if (vector == "" && raster == "")
                return "";
            string directory = GLib.Path.build_filename (
                GLib.Environment.get_user_cache_dir (),
                "atoms",
                "providers",
                id,
                "icons"
            );
            if (DirUtils.create_with_parents (directory, 0700) != 0)
                return "";
            string digest = Checksum.compute_for_string (ChecksumType.SHA256, origin);
            try {
                if (vector != "") {
                    if (vector.length > 512 * 1024 ||
                        vector.index_of ("<svg") < 0 ||
                        vector.down ().index_of ("<script") >= 0)
                        return "";
                    string path = GLib.Path.build_filename (directory, digest + ".svg");
                    FileUtils.set_contents (path, vector);
                    return path;
                }
                uint8[] decoded = Base64.decode (raster);
                if (decoded.length > 1024 * 1024)
                    return "";
                string path = GLib.Path.build_filename (directory, digest + ".png");
                FileUtils.set_data (path, decoded);
                return path;
            } catch (Error error) {
                debug ("Could not cache cpak artwork: %s", error.message);
                return "";
            }
        }

        private async CommandResult run (string[] arguments,
                                         string? input,
                                         Cancellable? cancellable) {
            if (!available)
                return new CommandResult (false, "", unavailable_reason, -1);

            string[] argv = new string[command_prefix.length + arguments.length];
            for (int i = 0; i < command_prefix.length; i++)
                argv[i] = command_prefix[i];
            for (int i = 0; i < arguments.length; i++)
                argv[i + command_prefix.length] = arguments[i];

            try {
                var launcher = new SubprocessLauncher (
                    SubprocessFlags.STDIN_PIPE |
                    SubprocessFlags.STDOUT_PIPE |
                    SubprocessFlags.STDERR_PIPE
                );
                launcher.setenv ("LC_ALL", "C", true);
                var process = launcher.spawnv (argv);
                string? stdout_text;
                string? stderr_text;
                yield process.communicate_utf8_async (
                    input,
                    cancellable,
                    out stdout_text,
                    out stderr_text
                );
                return new CommandResult (
                    process.get_successful (),
                    stdout_text ?? "",
                    stderr_text ?? "",
                    process.get_exit_status ()
                );
            } catch (Error error) {
                return new CommandResult (false, "", error.message, -1);
            }
        }

        private void ensure_success (CommandResult result) throws Error {
            if (result.ok)
                return;
            string message = result.stderr_text.strip ();
            if (message == "")
                message = "cpak exited with status %d".printf (result.exit_code);
            throw new CoreError.PROVIDER_FAILED (message);
        }

        private void require_available () throws Error {
            if (!available)
                throw new CoreError.NOT_AVAILABLE (unavailable_reason);
        }

        private void require_environment (Environment environment) throws Error {
            require_available ();
            if (environment.provider_id != id)
                throw new CoreError.INVALID_DATA ("environment belongs to another provider");
        }

        private Json.Parser parse (string data, string source) throws Error {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (data);
            } catch (Error error) {
                throw invalid_response ("%s returned invalid JSON: %s".printf (
                    source,
                    error.message
                ));
            }
            return parser;
        }

        private Json.Object parse_policy_data (string data) throws Error {
            var parser = parse (data == "" ? "{}" : data, "cpak environment policy");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.OBJECT)
                throw invalid_response ("cpak environment policy is invalid");
            var copied = root.copy ();
            return copied.get_object ();
        }

        private string object_data (Json.Object object) {
            var root = new Json.Node (NodeType.OBJECT);
            root.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (root);
            return generator.to_data (null);
        }

        private static bool has_display_permission (Json.Object object) {
            return boolean_member (object, "displayX11") ||
                   boolean_member (object, "socketX11") ||
                   boolean_member (object, "socketWayland");
        }

        private static bool has_host_actions (Json.Object object) {
            return object.has_member ("hostActions") &&
                   object.get_array_member ("hostActions").get_length () > 0;
        }

        private static bool has_home_permission (Json.Object object) {
            if (!object.has_member ("filesystem"))
                return false;
            foreach (var node in object.get_array_member ("filesystem").get_elements ()) {
                if (node.get_node_type () == NodeType.OBJECT &&
                    string_member (node.get_object (), "path") == "home")
                    return true;
            }
            return false;
        }

        private static string required_string (Json.Object object,
                                               string member) throws Error {
            string value = string_member (object, member);
            if (value == "")
                throw invalid_response ("cpak data is missing %s".printf (member));
            return value;
        }

        private static string string_member (Json.Object object,
                                             string member) {
            if (!object.has_member (member))
                return "";
            return object.get_string_member (member);
        }

        private static bool boolean_member (Json.Object object,
                                            string member) {
            return object.has_member (member) && object.get_boolean_member (member);
        }

        private static double double_member (Json.Object object,
                                             string member) {
            return object.has_member (member)
                ? object.get_double_member (member)
                : 0;
        }

        private static uint64 uint_member (Json.Object object,
                                           string member) {
            return object.has_member (member)
                ? (uint64) object.get_int_member (member)
                : 0;
        }

        private static CpakProviderError invalid_response (string message) {
            return new CpakProviderError.INVALID_RESPONSE (message);
        }

        private static string[] resolve_command_prefix () {
            string? configured = GLib.Environment.get_variable ("CPAK_BINARY");
            if (FileUtils.test ("/.flatpak-info", FileTest.EXISTS)) {
                string? spawn = GLib.Environment.find_program_in_path ("flatpak-spawn");
                if (spawn == null)
                    return new string[0];
                var prefix = new ArrayList<string> ();
                prefix.add (spawn);
                prefix.add ("--host");
                foreach (var variable in new string[] {
                    "CPAK_INSTALLATION_PATH",
                    "CPAK_OPTS_FILE",
                    "CPAK_STORAGE_DRIVER",
                    "CPAK_STORAGE_DRIVER_BINARY",
                    "CPAK_STORAGE_DRIVER_TRUSTED"
                }) {
                    string? value = GLib.Environment.get_variable (variable);
                    if (value != null && value != "")
                        prefix.add ("--env=%s=%s".printf (variable, value));
                }
                prefix.add (configured ?? "cpak");
                var result = new string[prefix.size];
                for (int i = 0; i < prefix.size; i++)
                    result[i] = prefix[i];
                return result;
            }

            string binary = configured ?? GLib.Environment.find_program_in_path ("cpak") ?? "";
            return binary == "" ? new string[0] : new string[] { binary };
        }
    }
}

[CCode (cname = "peas_register_types")]
public void register_types (Peas.ObjectModule module) {
    module.register_extension_type (
        typeof (Atoms.Provider),
        typeof (Atoms.CpakProvider)
    );
}
