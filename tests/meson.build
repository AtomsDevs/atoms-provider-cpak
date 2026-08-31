fake_cpak = executable(
  'fake-cpak',
  'fake_cpak.vala',
  dependencies: dependency('glib-2.0')
)

provider_test = executable(
  'atoms-provider-cpak-test',
  'provider_test.vala',
  dependencies: [
    atoms_core_dep,
    dependency('gio-2.0'),
    dependency('gee-0.8')
  ]
)

provider_test_env = environment()
provider_test_env.set('ATOMS_PROVIDER_PATH', meson.current_build_dir() / '..' / 'src')
provider_test_env.set('ATOMS_CPAK_STORE_INDEX', meson.current_source_dir() / 'store-index.json')
provider_test_env.set('ATOMS_CPAK_INVALID_STORE_INDEX', meson.current_source_dir() / 'store-invalid.json')
provider_test_env.set('ATOMS_CPAK_TEST_BINARY', fake_cpak.full_path())
provider_test_env.set('ATOMS_CPAK_FAKE_BINARY', fake_cpak.full_path())
provider_test_env.set('XDG_CACHE_HOME', meson.current_build_dir() / 'cache')
provider_test_env.set('HOME', meson.current_build_dir() / 'home')

test(
  'atoms-provider-cpak',
  provider_test,
  env: provider_test_env,
  depends: [atoms_provider_cpak_module, fake_cpak]
)
