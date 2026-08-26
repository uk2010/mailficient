mailficient_resources = gnome.compile_resources(
  'mailficient-resources',
  'com.local.Mailficient.gresource.xml',
  source_dir: meson.current_source_dir(),
  c_name: 'mailficient',
)

install_data('com.local.Mailficient.desktop', install_dir: get_option('datadir') / 'applications')
install_data('com.local.Mailficient.service', install_dir: get_option('datadir') / 'dbus-1/services')
install_data('com.local.Mailficient.metainfo.xml', install_dir: get_option('datadir') / 'metainfo')
install_data('com.local.Mailficient.Background.desktop',
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart')
foreach icon_size : ['64x64', '128x128', '256x256', '512x512']
  install_data('icons/hicolor' / icon_size / 'apps/com.local.Mailficient.png',
    install_dir: get_option('datadir') / 'icons/hicolor' / icon_size / 'apps')
endforeach
