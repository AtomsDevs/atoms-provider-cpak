gio_dep = dependency('gio-2.0')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
libpeas_dep = dependency('libpeas-2', version: '>= 2.0')
libsoup_dep = dependency('libsoup-3.0')

provider_dir = get_option('prefix') / get_option('libdir') / 'atoms' / 'providers'

atoms_provider_cpak_module = shared_module(
  'atoms-provider-cpak',
  'cpak_provider.vala',
  dependencies: [
    atoms_core_dep,
    gio_dep,
    gee_dep,
    json_dep,
    libpeas_dep,
    libsoup_dep
  ],
  install: true,
  install_dir: provider_dir,
  install_rpath: get_option('prefix') / get_option('libdir')
)

provider_metadata = configure_file(
  input: '../atoms-provider-cpak.plugin',
  output: 'atoms-provider-cpak.plugin',
  copy: true
)

install_data(
  '../atoms-provider-cpak.plugin',
  install_dir: provider_dir
)
