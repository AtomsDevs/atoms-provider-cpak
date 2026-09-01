int main (string[] args) {
    if (args.length < 3 || args[1] != "--host")
        return 2;

    string[] command = new string[args.length - 1];
    for (int i = 2; i < args.length; i++)
        command[i - 2] = args[i];
    command[args.length - 2] = null;
    Posix.execv (command[0], command);
    return 127;
}
