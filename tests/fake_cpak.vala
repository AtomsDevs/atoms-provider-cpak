private const string ENVIRONMENT = "{\"id\":\"ubuntu-test\",\"name\":\"Ubuntu test\",\"version\":\"26.04\",\"origin\":\"github.com/containerpak/ubuntu\",\"policy\":{\"network\":true,\"displayX11\":true,\"socketWayland\":true,\"deviceUsb\":true,\"deviceInput\":true,\"hostActions\":[{\"provider\":\"containers\",\"capabilities\":[\"read\"]}],\"filesystem\":[{\"path\":\"home\",\"access\":\"read-write\"}]}}";
private const string PERMISSIONS = "{\"network\":true,\"displayX11\":true,\"socketWayland\":true,\"deviceUsb\":true,\"deviceInput\":true,\"hostActions\":[{\"provider\":\"containers\",\"capabilities\":[\"read\"]}],\"filesystem\":[{\"path\":\"home\",\"access\":\"read-write\"}]}";

private int fail (string message) {
    stderr.printf ("%s\n", message);
    return 1;
}

int main (string[] args) {
    if (args.length >= 3 && args[1] == "discover" && args[2] == "list") {
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
