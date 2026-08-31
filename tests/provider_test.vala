using Atoms;

private MainLoop loop;
private Error? async_error;
private ProviderRegistry registry;
private Provider selected_provider;
private string valid_store_index;

private void test_distributions () {
    async_error = null;
    selected_provider.list_distributions.begin (null, (object, result) => {
        try {
            var distributions = selected_provider.list_distributions.end (result);
            assert (distributions.size == 1);
            assert (distributions[0].origin == "github.com/containerpak/ubuntu");
            assert (distributions[0].version == "26.04");
            assert (distributions[0].icon_path != "");
        } catch (Error error) {
            async_error = error;
        }
        loop.quit ();
    });
    loop.run ();
    assert (async_error == null);
}

private void test_distribution_store_retry () {
    async_error = null;
    string marker = Path.build_filename (
        GLib.Environment.get_tmp_dir (),
        "atoms-cpak-lock-" + Uuid.string_random ()
    );
    GLib.Environment.set_variable ("ATOMS_CPAK_LOCK_ONCE", marker, true);
    selected_provider.list_distributions.begin (null, (object, result) => {
        try {
            var distributions = selected_provider.list_distributions.end (result);
            assert (distributions.size == 1);
        } catch (Error error) {
            async_error = error;
        }
        loop.quit ();
    });
    loop.run ();
    GLib.Environment.unset_variable ("ATOMS_CPAK_LOCK_ONCE");
    assert (FileUtils.test (marker, FileTest.EXISTS));
    FileUtils.remove (marker);
    assert (async_error == null);
}

private void test_environments_and_processes () {
    async_error = null;
    selected_provider.list_environments.begin (null, (object, result) => {
        try {
            var environments = selected_provider.list_environments.end (result);
            assert (environments.size == 1);
            assert (environments[0].policy.network);
            assert (environments[0].policy.can_usb);
            assert (environments[0].policy.audio);
            assert (environments[0].policy.can_audio);
            var argv = selected_provider.shell_argv (
                environments[0],
                "/bin/bash",
                { "-i" },
                true
            );
            assert ("--terminal" in argv);
            assert (argv[argv.length - 2] == "--");
            assert (argv[argv.length - 1] == "-i");
            var update = selected_provider.update_argv (environments[0]);
            assert (!("--terminal" in update));
            assert ("-lc" in update);
            assert (update[update.length - 1].index_of ("apt-get") >= 0);
            selected_provider.list_processes.begin (environments[0], null, (process_object, process_result) => {
                try {
                    var processes = selected_provider.list_processes.end (process_result);
                    assert (processes.size == 1);
                    assert (processes[0].pid == 42);
                    assert (processes[0].memory_label () == "2.0 MiB");
                } catch (Error error) {
                    async_error = error;
                }
                loop.quit ();
            });
        } catch (Error error) {
            async_error = error;
            loop.quit ();
        }
    });
    loop.run ();
    assert (async_error == null);
}

private void test_policy_round_trip () {
    async_error = null;
    selected_provider.list_environments.begin (null, (object, result) => {
        try {
            var environment = selected_provider.list_environments.end (result)[0];
            environment.policy.network = false;
            environment.policy.home = false;
            environment.policy.display = false;
            environment.policy.usb = false;
            environment.policy.input = false;
            environment.policy.audio = false;
            environment.policy.host_commands = false;
            selected_provider.update_policy.begin (environment, null, (update_object, update_result) => {
                try {
                    var narrowed = selected_provider.update_policy.end (update_result);
                    assert (!narrowed.policy.network);
                    assert (!narrowed.policy.home);
                    assert (!narrowed.policy.display);
                    assert (!narrowed.policy.usb);
                    assert (!narrowed.policy.input);
                    assert (!narrowed.policy.audio);
                    assert (!narrowed.policy.host_commands);

                    narrowed.policy.network = true;
                    narrowed.policy.home = true;
                    narrowed.policy.display = true;
                    narrowed.policy.usb = true;
                    narrowed.policy.input = true;
                    narrowed.policy.audio = true;
                    narrowed.policy.host_commands = true;
                    selected_provider.update_policy.begin (narrowed, null, (restore_object, restore_result) => {
                        try {
                            var restored = selected_provider.update_policy.end (restore_result);
                            assert (restored.policy.network);
                            assert (restored.policy.home);
                            assert (restored.policy.display);
                            assert (restored.policy.usb);
                            assert (restored.policy.input);
                            assert (restored.policy.audio);
                            assert (restored.policy.host_commands);
                            assert (restored.provider_data.index_of ("\"access\":\"read-write\"") >= 0);
                            assert (restored.provider_data.index_of ("\"provider\":\"containers\"") >= 0);
                            assert (restored.provider_data.index_of ("readOnly") < 0);
                        } catch (Error error) {
                            async_error = error;
                        }
                        loop.quit ();
                    });
                } catch (Error error) {
                    async_error = error;
                    loop.quit ();
                }
            });
        } catch (Error error) {
            async_error = error;
            loop.quit ();
        }
    });
    loop.run ();
    assert (async_error == null);
}

private void test_application_exports () {
    async_error = null;
    selected_provider.list_environments.begin (null, (object, result) => {
        try {
            var environment = selected_provider.list_environments.end (result)[0];
            selected_provider.list_applications.begin (environment, null, (list_object, list_result) => {
                try {
                    var applications = selected_provider.list_applications.end (list_result);
                    assert (applications.size == 1);
                    var application = applications[0];
                    assert (application.name == "Example application");
                    assert (!application.exported);
                    var requested = new DesktopApplication (
                        "cpak",
                        application.id,
                        "Forged application",
                        "",
                        "",
                        "/bin/sh -c 'touch /tmp/atoms-forged'"
                    );
                    selected_provider.set_application_exported.begin (
                        environment,
                        requested,
                        true,
                        null,
                        (export_object, export_result) => {
                            try {
                                selected_provider.set_application_exported.end (export_result);
                                assert (requested.exported);
                                string digest = Checksum.compute_for_string (
                                    ChecksumType.SHA256,
                                    environment.id + "\n" + application.id
                                );
                                string export_path = Path.build_filename (
                                    GLib.Environment.get_home_dir (),
                                    ".local",
                                    "share",
                                    "applications",
                                    "cpak-environment-" + digest + ".desktop"
                                );
                                string exported_data;
                                FileUtils.get_contents (export_path, out exported_data);
                                assert (exported_data.index_of ("/usr/bin/example %U") >= 0);
                                assert (exported_data.index_of ("atoms-forged") < 0);
                                selected_provider.list_applications.begin (
                                    environment,
                                    null,
                                    (verify_object, verify_result) => {
                                        try {
                                            var current = selected_provider.list_applications.end (
                                                verify_result
                                            );
                                            assert (current[0].exported);
                                            selected_provider.set_application_exported.begin (
                                                environment,
                                                current[0],
                                                false,
                                                null,
                                                (remove_object, remove_result) => {
                                                    try {
                                                        selected_provider.set_application_exported.end (
                                                            remove_result
                                                        );
                                                        assert (!current[0].exported);
                                                    } catch (Error error) {
                                                        async_error = error;
                                                    }
                                                    loop.quit ();
                                                }
                                            );
                                        } catch (Error error) {
                                            async_error = error;
                                            loop.quit ();
                                        }
                                    }
                                );
                            } catch (Error error) {
                                async_error = error;
                                loop.quit ();
                            }
                        }
                    );
                } catch (Error error) {
                    async_error = error;
                    loop.quit ();
                }
            });
        } catch (Error error) {
            async_error = error;
            loop.quit ();
        }
    });
    loop.run ();
    assert (async_error == null);
}

private void test_creation_progress () {
    async_error = null;
    var progress = new Gee.ArrayList<string> ();
    ulong handler = selected_provider.operation_progress.connect ((message) => {
        progress.add (message);
    });
    var distribution = new Distribution (
        "cpak",
        "github.com/containerpak/ubuntu",
        "Ubuntu",
        "26.04",
        "Ubuntu test distribution",
        "github.com/containerpak/ubuntu",
        ""
    );
    selected_provider.create_environment.begin (
        distribution,
        "Ubuntu test",
        null,
        (object, result) => {
            try {
                var environment = selected_provider.create_environment.end (result);
                assert (environment.id == "ubuntu-test");
            } catch (Error error) {
                async_error = error;
            }
            loop.quit ();
        }
    );
    loop.run ();
    selected_provider.disconnect (handler);
    assert (async_error == null);
    assert (progress.size == 3);
    assert (progress[0].has_prefix ("Installing Ubuntu"));
    assert (progress[1] == "Creating persistent environment storage");
    assert (progress[2] == "Reading environment permissions");
}

private void test_invalid_store () {
    async_error = null;
    GLib.Environment.set_variable (
        "ATOMS_CPAK_STORE_INDEX",
        GLib.Environment.get_variable ("ATOMS_CPAK_INVALID_STORE_INDEX"),
        true
    );
    selected_provider.list_distributions.begin (null, (object, result) => {
        try {
            selected_provider.list_distributions.end (result);
        } catch (Error error) {
            async_error = error;
        }
        loop.quit ();
    });
    loop.run ();
    GLib.Environment.set_variable ("ATOMS_CPAK_STORE_INDEX", valid_store_index, true);
    assert (async_error != null);
    assert (async_error.message == "cpak Store has an invalid Distributions category");
}

private void test_missing_cpak () {
    async_error = null;
    GLib.Environment.set_variable (
        "ATOMS_CPAK_TEST_BINARY",
        "/missing/atoms-test-cpak",
        true
    );
    string path = GLib.Environment.get_variable ("ATOMS_PROVIDER_PATH");
    var missing_registry = new ProviderRegistry ({ path });
    missing_registry.load ();
    Provider missing_provider;
    try {
        missing_provider = missing_registry.require ("cpak");
    } catch (Error error) {
        critical ("%s", error.message);
        assert_not_reached ();
    }
    missing_provider.list_distributions.begin (null, (object, result) => {
        try {
            missing_provider.list_distributions.end (result);
        } catch (Error error) {
            async_error = error;
        }
        loop.quit ();
    });
    loop.run ();
    GLib.Environment.set_variable (
        "ATOMS_CPAK_TEST_BINARY",
        GLib.Environment.get_variable ("ATOMS_CPAK_FAKE_BINARY"),
        true
    );
    assert (async_error != null);
    assert (async_error.message ==
        "cpak is not installed on the host. Install cpak, then reopen Atoms.");
}

int main (string[] args) {
    Test.init (ref args);
    loop = new MainLoop ();
    valid_store_index = GLib.Environment.get_variable ("ATOMS_CPAK_STORE_INDEX");
    string path = GLib.Environment.get_variable ("ATOMS_PROVIDER_PATH");
    string[] paths = { path };
    registry = new ProviderRegistry (paths);
    registry.load ();
    assert (registry.diagnostics.size == 0);
    assert (registry.providers.size == 1);
    try {
        selected_provider = registry.require ("cpak");
    } catch (Error error) {
        critical ("%s", error.message);
        return 1;
    }
    Test.add_func ("/atoms/provider-cpak/distributions", test_distributions);
    Test.add_func ("/atoms/provider-cpak/distribution-store-retry", test_distribution_store_retry);
    Test.add_func ("/atoms/provider-cpak/environments", test_environments_and_processes);
    Test.add_func ("/atoms/provider-cpak/creation-progress", test_creation_progress);
    Test.add_func ("/atoms/provider-cpak/policy-round-trip", test_policy_round_trip);
    Test.add_func ("/atoms/provider-cpak/application-exports", test_application_exports);
    Test.add_func ("/atoms/provider-cpak/invalid-store", test_invalid_store);
    Test.add_func ("/atoms/provider-cpak/missing-cpak", test_missing_cpak);
    return Test.run ();
}
