#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_tree=${MAILFICIENT_FLATPAK_APP_TREE:-"$root_dir/flatpak-build-custom-toolbar/files"}
native_build=${MAILFICIENT_NATIVE_BUILD:-"$root_dir/build-menu-state"}
sdk_location=$(flatpak info -l org.gnome.Sdk//49)
version=$(grep -o "version: '[0-9][^']*'" "$root_dir/meson.build" |
    head -n 1 |
    cut -d "'" -f 2)
build_root=$(mktemp -d "$root_dir/build-deb.XXXXXX")
stage="$build_root/stage"
output_dir="$root_dir/dist"
output="$output_dir/mailficient_${version}_amd64.deb"
checksum="$output.sha256"
private_lib="$stage/usr/lib/mailficient"

require_file() {
    if [ ! -e "$1" ]; then
        printf 'Required build artifact is missing: %s\n' "$1" >&2
        exit 1
    fi
}

require_file "$native_build/src/mailficient"
require_file "$native_build/src/mailficient-addressbook-probe"
require_file "$app_tree/lib/libcamel-1.2.so.67"
require_file "$app_tree/lib/evolution-data-server/camel-providers/libcamelimapx.so"
require_file "$sdk_location/files/lib/x86_64-linux-gnu/libicuuc.so.77"

install -d \
    "$stage/DEBIAN" \
    "$stage/usr/bin" \
    "$private_lib/evolution-data-server" \
    "$stage/usr/share/applications" \
    "$stage/usr/share/dbus-1/services" \
    "$stage/usr/share/doc/mailficient" \
    "$stage/usr/share/icons/hicolor" \
    "$stage/usr/share/metainfo"

install -m 0755 "$native_build/src/mailficient" "$private_lib/mailficient.real"
install -m 0755 "$native_build/src/mailficient-addressbook-probe" \
    "$private_lib/mailficient-addressbook-probe.real"
install -m 0755 "$root_dir/packaging/debian/mailficient" "$stage/usr/bin/mailficient"
install -m 0755 "$root_dir/packaging/debian/mailficient-addressbook-probe" \
    "$stage/usr/bin/mailficient-addressbook-probe"

cp -a "$app_tree"/lib/*.so* "$private_lib/"
cp -a "$app_tree/lib/evolution-data-server/camel-providers" \
    "$private_lib/evolution-data-server/"
cp -a "$app_tree/lib/evolution-data-server/libedbus-private.so" \
    "$private_lib/evolution-data-server/"
cp -a "$sdk_location"/files/lib/x86_64-linux-gnu/libicuuc.so.77* "$private_lib/"
cp -a "$sdk_location"/files/lib/x86_64-linux-gnu/libicui18n.so.77* "$private_lib/"
cp -a "$sdk_location"/files/lib/x86_64-linux-gnu/libicudata.so.77* "$private_lib/"

install -m 0644 "$root_dir/data/com.local.Mailficient.desktop" \
    "$stage/usr/share/applications/"
sed 's|Exec=/app/bin/mailficient|Exec=/usr/bin/mailficient|' \
    "$root_dir/data/com.local.Mailficient.service" \
    > "$stage/usr/share/dbus-1/services/com.local.Mailficient.service"
install -m 0644 "$root_dir/data/com.local.Mailficient.metainfo.xml" \
    "$stage/usr/share/metainfo/"

for icon_size in 64x64 128x128 256x256 512x512; do
    install -d "$stage/usr/share/icons/hicolor/$icon_size/apps"
    install -m 0644 \
        "$root_dir/data/icons/hicolor/$icon_size/apps/com.local.Mailficient.png" \
        "$stage/usr/share/icons/hicolor/$icon_size/apps/"
done
install -d "$stage/usr/share/icons/hicolor/scalable/apps"
install -m 0644 \
    "$root_dir/data/icons/hicolor/scalable/apps/com.local.Mailficient.svg" \
    "$stage/usr/share/icons/hicolor/scalable/apps/"

install -m 0644 "$root_dir/README.md" "$stage/usr/share/doc/mailficient/README.md"
install -m 0644 "$root_dir/RELEASE_NOTES.md" \
    "$stage/usr/share/doc/mailficient/RELEASE_NOTES.md"
install -m 0644 "$root_dir/packaging/debian/copyright" \
    "$stage/usr/share/doc/mailficient/copyright"

install -m 0755 "$root_dir/packaging/debian/postinst" "$stage/DEBIAN/postinst"
install -m 0755 "$root_dir/packaging/debian/postrm" "$stage/DEBIAN/postrm"

installed_size=$(du -sk "$stage/usr" | awk '{print $1}')
sed \
    -e "s/@VERSION@/$version/" \
    -e "s/@INSTALLED_SIZE@/$installed_size/" \
    "$root_dir/packaging/debian/control.in" > "$stage/DEBIAN/control"

install -d "$output_dir"
dpkg-deb --root-owner-group --build "$stage" "$output"
(
    cd "$output_dir"
    sha256sum "$(basename "$output")" > "$(basename "$checksum")"
)

printf 'Built %s\n' "$output"
printf 'Checksum %s\n' "$checksum"
dpkg-deb --info "$output"
