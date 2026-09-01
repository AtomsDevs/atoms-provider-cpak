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
        private const size_t MAX_APPLICATION_BYTES = 64 * 1024;
        private const size_t MAX_ICON_BYTES = 1024 * 1024;
        private const string UPDATE_SCRIPT =
            "set -e; " +
            "if command -v apt-get >/dev/null 2>&1; then " +
            "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y; " +
            "elif command -v dnf >/dev/null 2>&1; then dnf upgrade --refresh -y; " +
            "elif command -v pacman >/dev/null 2>&1; then pacman -Syu --noconfirm; " +
            "elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive update; " +
            "elif command -v apk >/dev/null 2>&1; then apk update && apk upgrade; " +
            "else echo 'Atoms could not identify this distribution package manager.' >&2; exit 127; fi";
        private const string APPLICATION_LIST_SCRIPT =
            "for directory in /usr/share/applications /usr/local/share/applications \"$HOME/.local/share/applications\"; do " +
            "[ -d \"$directory\" ] || continue; " +
            "find \"$directory\" -maxdepth 1 -type f -name '*.desktop' -size -65537c -print; " +
            "done | LC_ALL=C sort -u | head -n 128 | while IFS= read -r path; do " +
            "[ -f \"$path\" ] && [ ! -L \"$path\" ] || continue; " +
            "printf '%s\\t' \"$(printf '%s' \"$path\" | base64 | tr -d '\\n')\"; " +
            "base64 \"$path\" | tr -d '\\n'; printf '\\n'; done";
        private const string APPLICATION_ICON_SCRIPT =
            "desktop=$1; [ -f \"$desktop\" ] && [ ! -L \"$desktop\" ] || exit 0; " +
            "icon=$(sed -n 's/^Icon[[:space:]]*=[[:space:]]*//p' \"$desktop\" | head -n 1); " +
            "[ -n \"$icon\" ] || exit 0; candidate=''; " +
            "case \"$icon\" in /*) case \"$icon\" in " +
            "/usr/share/icons/*.png|/usr/local/share/icons/*.png|/usr/share/pixmaps/*.png|\"$HOME\"/.local/share/icons/*.png|\"$HOME\"/.local/share/pixmaps/*.png) candidate=$icon;; esac;; *) " +
            "for root in /usr/share/icons /usr/local/share/icons /usr/share/pixmaps \"$HOME/.local/share/icons\" \"$HOME/.local/share/pixmaps\"; do " +
            "[ -d \"$root\" ] || continue; " +
            "candidate=$(find \"$root\" -type f \\( -name \"$icon.png\" -o -name \"$icon\" \\) -size -1048577c -print -quit 2>/dev/null); " +
            "[ -n \"$candidate\" ] && break; done;; esac; " +
            "[ -f \"$candidate\" ] && [ ! -L \"$candidate\" ] || exit 0; " +
            "case \"$candidate\" in *.png) ;; *) exit 0;; esac; " +
            "printf 'png\\t'; base64 \"$candidate\" | tr -d '\\n'; printf '\\n'";
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
                    : unavailable_message ();
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
            if (store_is_busy (catalog_result))
                catalog_result = yield run ({ "discover", "list" }, null, cancellable);
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

            operation_progress ("Installing %s with cpak".printf (
                distribution.display_name ()
            ));
            var install = yield run (
                { "discover", "install", distribution.origin },
                null,
                cancellable
            );
            ensure_success (install);

            operation_progress ("Creating persistent environment storage");
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
            operation_progress ("Reading environment permissions");
            return yield environment_from_json (root.get_object (), cancellable);
        }

        public string[] shell_argv (Environment environment,
                                    string command,
                                    string[] arguments,
                                    bool terminal) throws Error {
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
                environment.id
            })
                values.add (value);
            if (terminal)
                values.add ("--terminal");
            values.add ("--command");
            values.add (selected_command);
            if (arguments.length > 0)
                values.add ("--");
            foreach (var argument in arguments)
                values.add (argument);

            var argv = new string[values.size];
            for (int i = 0; i < values.size; i++)
                argv[i] = values[i];
            return argv;
        }

        public string[] update_argv (Environment environment) throws Error {
            return shell_argv (
                environment,
                "/bin/sh",
                { "-lc", UPDATE_SCRIPT },
                false
            );
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

        public async ArrayList<DesktopApplication> list_applications (
            Environment environment,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            var exported = yield exported_applications (environment, cancellable);
            var result = yield run ({
                "environment",
                "shell",
                "--environment",
                environment.id,
                "--command",
                "/bin/sh",
                "--",
                "-c",
                APPLICATION_LIST_SCRIPT
            }, null, cancellable);
            ensure_success (result);

            var applications = new ArrayList<DesktopApplication> ();
            foreach (var line in result.stdout_text.split ("\n")) {
                if (line == "")
                    continue;
                string[] fields = line.split ("\t");
                if (fields.length != 2)
                    continue;
                uint8[] path_data = Base64.decode (fields[0]);
                uint8[] content_data = Base64.decode (fields[1]);
                if (path_data.length == 0 || content_data.length == 0 ||
                    content_data.length > MAX_APPLICATION_BYTES)
                    continue;
                string path = (string) path_data;
                string content = (string) content_data;
                if (path.length != path_data.length ||
                    content.length != content_data.length ||
                    !valid_application_path (path) ||
                    !content.validate ())
                    continue;
                var application = parse_application (path, content, exported.contains (path));
                if (application != null)
                    applications.add (application);
            }
            applications.sort ((a, b) => strcmp (a.name, b.name));
            return applications;
        }

        public async void set_application_exported (
            Environment environment,
            DesktopApplication application,
            bool exported,
            Cancellable? cancellable = null
        ) throws Error {
            require_environment (environment);
            if (application.provider_id != id || !valid_application_path (application.id))
                throw new CoreError.INVALID_DATA ("application belongs to another provider");

            if (!exported) {
                var result = yield run ({
                    "environment",
                    "unexport-application",
                    "--environment",
                    environment.id,
                    "--application",
                    application.id,
                    "--json"
                }, null, cancellable);
                ensure_success (result);
                application.exported = false;
                return;
            }

            DesktopApplication? current = null;
            var applications = yield list_applications (environment, cancellable);
            foreach (var candidate in applications) {
                if (candidate.id == application.id) {
                    current = candidate;
                    break;
                }
            }
            if (current == null)
                throw new CoreError.NOT_FOUND ("application is no longer installed");

            Bytes? icon = yield load_application_icon (
                environment,
                current,
                cancellable
            );
            var request = new Json.Object ();
            request.set_string_member ("name", current.name);
            if (current.description != "")
                request.set_string_member ("description", current.description);
            request.set_string_member ("command", current.command);
            if (icon != null) {
                unowned uint8[] icon_data = icon.get_data ();
                request.set_string_member ("icon_png", Base64.encode (icon_data));
            }
            var result = yield run ({
                "environment",
                "export-application",
                "--environment",
                environment.id,
                "--application",
                current.id,
                "--application-data",
                "-",
                "--json"
            }, object_data (request), cancellable);
            ensure_success (result);
            application.exported = true;
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
            if (!valid_identifier (environment_id))
                throw invalid_response ("cpak returned an invalid environment identifier");
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
                audio = has_audio_permission (policy),
                host_commands = has_host_actions (policy),
                can_network = boolean_member (ceiling, "network"),
                can_home = has_home_permission (ceiling),
                can_display = has_display_permission (ceiling),
                can_usb = boolean_member (ceiling, "deviceUsb"),
                can_input = boolean_member (ceiling, "deviceInput"),
                can_audio = has_audio_permission (ceiling),
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
            foreach (var member in new string[] {
                "socketPulseAudio",
                "deviceAlsa"
            }) {
                raw.set_boolean_member (
                    member,
                    selected.audio && boolean_member (ceiling, member)
                );
            }
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

        private async HashSet<string> exported_applications (
            Environment environment,
            Cancellable? cancellable
        ) throws Error {
            var result = yield run ({
                "environment",
                "application-exports",
                "--environment",
                environment.id,
                "--json"
            }, null, cancellable);
            ensure_success (result);
            var parser = parse (result.stdout_text, "cpak environment application exports");
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != NodeType.ARRAY)
                throw invalid_response ("cpak returned invalid application exports");
            var applications = new HashSet<string> ();
            foreach (var node in root.get_array ().get_elements ()) {
                if (node.get_node_type () != NodeType.VALUE)
                    throw invalid_response ("cpak returned an invalid application export");
                string application = node.get_string ();
                if (!valid_application_path (application))
                    throw invalid_response ("cpak returned an invalid application identifier");
                applications.add (application);
            }
            return applications;
        }

        private DesktopApplication? parse_application (string path,
                                                       string content,
                                                       bool exported) {
            try {
                var key_file = new KeyFile ();
                key_file.load_from_data (content, content.length, KeyFileFlags.NONE);
                if (!key_file.has_group ("Desktop Entry") ||
                    key_file.get_string ("Desktop Entry", "Type") != "Application" ||
                    optional_boolean (key_file, "Hidden") ||
                    optional_boolean (key_file, "NoDisplay") ||
                    optional_boolean (key_file, "Terminal"))
                    return null;
                string name = key_file.get_locale_string ("Desktop Entry", "Name");
                string command = key_file.get_string ("Desktop Entry", "Exec");
                string description = optional_locale_string (key_file, "Comment");
                string icon = optional_string (key_file, "Icon");
                if (name.strip () == "" || command.strip () == "" ||
                    name.length > 240 || description.length > 1024 ||
                    command.length > 4096 || contains_control (name) ||
                    contains_control (description) || contains_control (command))
                    return null;
                return new DesktopApplication (
                    id,
                    path,
                    name,
                    description,
                    icon,
                    command,
                    exported
                );
            } catch (Error error) {
                debug ("Could not parse environment application %s: %s", path, error.message);
                return null;
            }
        }

        private async Bytes? load_application_icon (
            Environment environment,
            DesktopApplication application,
            Cancellable? cancellable
        ) throws Error {
            var result = yield run ({
                "environment",
                "shell",
                "--environment",
                environment.id,
                "--command",
                "/bin/sh",
                "--",
                "-c",
                APPLICATION_ICON_SCRIPT,
                "atoms-icon",
                application.id
            }, null, cancellable);
            ensure_success (result);
            string line = result.stdout_text.strip ();
            if (line == "")
                return null;
            string[] fields = line.split ("\t");
            if (fields.length != 2 || fields[0] != "png")
                return null;
            uint8[] data = Base64.decode (fields[1]);
            if (!valid_icon (fields[0], data))
                return null;
            return new Bytes (data);
        }

        private static bool valid_application_path (string path) {
            if (path.length > 4096 || !path.has_suffix (".desktop") ||
                contains_control (path) || path.index_of ("/../") >= 0)
                return false;
            return path.has_prefix ("/usr/share/applications/") ||
                   path.has_prefix ("/usr/local/share/applications/") ||
                   path.index_of ("/.local/share/applications/") > 0;
        }

        private static bool valid_identifier (string value) {
            if (value.length == 0 || value.length > 160)
                return false;
            foreach (uint8 character in value.data) {
                bool letter = (character >= 'a' && character <= 'z') ||
                              (character >= 'A' && character <= 'Z');
                bool digit = character >= '0' && character <= '9';
                if (!(letter || digit || character == '-' ||
                      character == '_' || character == '.'))
                    return false;
            }
            return true;
        }

        private static bool valid_icon (string suffix, uint8[] data) {
            if (data.length == 0 || data.length > MAX_ICON_BYTES)
                return false;
            return suffix == "png" && data.length >= 8 &&
                   data[0] == 0x89 && data[1] == 0x50 &&
                   data[2] == 0x4e && data[3] == 0x47 &&
                   data[4] == 0x0d && data[5] == 0x0a &&
                   data[6] == 0x1a && data[7] == 0x0a;
        }

        private static bool contains_control (string value) {
            foreach (unichar character in value.to_utf8 ()) {
                if (character < 0x20 || character == 0x7f)
                    return true;
            }
            return false;
        }

        private static bool optional_boolean (KeyFile key_file, string key) {
            try {
                return key_file.get_boolean ("Desktop Entry", key);
            } catch (Error error) {
                return false;
            }
        }

        private static string optional_string (KeyFile key_file, string key) {
            try {
                return key_file.get_string ("Desktop Entry", key);
            } catch (Error error) {
                return "";
            }
        }

        private static string optional_locale_string (KeyFile key_file, string key) {
            try {
                return key_file.get_locale_string ("Desktop Entry", key);
            } catch (Error error) {
                return "";
            }
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
            if (result.exit_code == -1 &&
                message.index_of ("No such file or directory") >= 0) {
                throw new CoreError.NOT_AVAILABLE (unavailable_message ());
            }
            if (message == "")
                message = "cpak exited with status %d".printf (result.exit_code);
            throw new CoreError.PROVIDER_FAILED (message);
        }

        private static bool store_is_busy (CommandResult result) {
            return !result.ok &&
                result.stderr_text.index_of ("wal: directory is already open") >= 0;
        }

        private void require_available () throws Error {
            if (!available)
                throw new CoreError.NOT_AVAILABLE (unavailable_reason);
        }

        private void require_environment (Environment environment) throws Error {
            require_available ();
            if (environment.provider_id != id || !valid_identifier (environment.id))
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

        private static bool has_audio_permission (Json.Object object) {
            return boolean_member (object, "socketPulseAudio") ||
                   boolean_member (object, "deviceAlsa");
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
            string? test_binary = GLib.Environment.get_variable ("ATOMS_CPAK_TEST_BINARY");
            if (test_binary != null)
                return new string[] { test_binary };
            string? configured = GLib.Environment.get_variable ("CPAK_BINARY");
            if (has_system_broker ()) {
                string? broker = GLib.Environment.find_program_in_path ("cpak-host");
                return broker == null ? new string[0] : new string[] { broker };
            }
            string flatpak_info = flatpak_info_path ();
            if (FileUtils.test (flatpak_info, FileTest.EXISTS)) {
                string? spawn = GLib.Environment.get_variable (
                    "ATOMS_CPAK_TEST_FLATPAK_SPAWN"
                ) ?? GLib.Environment.find_program_in_path ("flatpak-spawn");
                if (spawn == null)
                    return new string[0];
                string binary = bundled_cpak_path (flatpak_info);
                if (binary == "")
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
                prefix.add (binary);
                var result = new string[prefix.size];
                for (int i = 0; i < prefix.size; i++)
                    result[i] = prefix[i];
                return result;
            }

            string binary = configured ?? GLib.Environment.find_program_in_path ("cpak") ?? "";
            if (binary == "") {
                string local_binary = GLib.Path.build_filename (
                    GLib.Environment.get_home_dir (),
                    ".local",
                    "bin",
                    "cpak"
                );
                if (FileUtils.test (local_binary, FileTest.IS_EXECUTABLE))
                    binary = local_binary;
            }
            return binary == "" ? new string[0] : new string[] { binary };
        }

        private static string unavailable_message () {
            if (has_system_broker ())
                return "Atoms could not reach the cpak host service. Restart Atoms and try again.";
            if (FileUtils.test (flatpak_info_path (), FileTest.EXISTS))
                return "The bundled cpak executable is missing. Reinstall Atoms.";
            return "cpak is required to manage environments. Install it from https://cpak.it, then reopen Atoms.";
        }

        private static bool has_system_broker () {
            return GLib.Environment.get_variable ("CPAK_SYSTEM_BROKER_SOCKET") != null &&
                GLib.Environment.get_variable ("CPAK_SYSTEM_BROKER_TOKEN_FILE") != null;
        }

        private static string flatpak_info_path () {
            return GLib.Environment.get_variable ("ATOMS_CPAK_TEST_FLATPAK_INFO") ??
                "/.flatpak-info";
        }

        private static string bundled_cpak_path (string flatpak_info) {
            string sandbox_binary = GLib.Environment.get_variable (
                "ATOMS_CPAK_TEST_BUNDLED_BINARY"
            ) ?? "/app/libexec/atoms/cpak";
            if (!FileUtils.test (sandbox_binary, FileTest.IS_EXECUTABLE))
                return "";
            try {
                var info = new KeyFile ();
                info.load_from_file (flatpak_info, KeyFileFlags.NONE);
                string app_path = info.get_string ("Instance", "app-path");
                if (!GLib.Path.is_absolute (app_path))
                    return "";
                return GLib.Path.build_filename (
                    app_path,
                    "libexec",
                    "atoms",
                    "cpak"
                );
            } catch (Error error) {
                debug ("Could not locate bundled cpak: %s", error.message);
                return "";
            }
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
