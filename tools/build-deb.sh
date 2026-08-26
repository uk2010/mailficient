#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_tree=${MAILFICIENT_FLATPAK_APP_TREE:-"$root_dir/flatpak-build-custom-toolbar/files"}
native_build=${MAILFICIENT_NATIVE_BUILD:-"$root_dir/build-menu-state"}
mailficient_binary=${MAILFICIENT_NATIVE_BINARY:-"$native_build/src/mailficient"}
probe_binary=${MAILFICIENT_PROBE_BINARY:-"$native_build/src/mailficient-addressbook-probe"}
architecture=${MAILFICIENT_DEB_ARCHITECTURE:-$(dpkg --print-architecture)}
multiarch=${MAILFICIENT_DEB_MULTIARCH:-$(dpkg-architecture -qDEB_HOST_MULTIARCH)}
if [ -n "${MAILFICIENT_SDK_LIB:-}" ]; then
    sdk_lib=$MAILFICIENT_SDK_LIB
else
    sdk_location=$(flatpak info -l org.gnome.Sdk//49)
    sdk_lib="$sdk_location/files/lib/$multiarch"
fi
runtime_lib=${MAILFICIENT_RUNTIME_LIB_DIR:-"$app_tree/lib"}
provider_dir=${MAILFICIENT_PROVIDER_DIR:-"$runtime_lib/evolution-data-server/camel-providers"}
eds_private_lib=${MAILFICIENT_EDS_PRIVATE_LIB:-"$runtime_lib/evolution-data-server/libedbus-private.so"}
app_version=$(grep -o "version: '[0-9][^']*'" "$root_dir/meson.build" |
    head -n 1 |
    cut -d "'" -f 2)
package_version="$app_version-${MAILFICIENT_DEB_REVISION:-1}"
build_root=$(mktemp -d "$root_dir/build-deb.XXXXXX")
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
stage="$build_root/stage"
output_dir="$root_dir/dist"
output="$output_dir/mailficient_${package_version}_${architecture}.deb"
checksum="$output.sha256"
private_lib="$stage/usr/lib/mailficient"

require_file() {
    if [ ! -e "$1" ]; then
        printf 'Required build artifact is missing: %s\n' "$1" >&2
        exit 1
    fi
}

require_file "$mailficient_binary"
require_file "$probe_binary"
require_file "$provider_dir/libcamelimapx.so"

# ICU and Camel SONAMEs vary between distributions and architectures. Resolve
# them from the selected runtime instead of coupling packages to one SDK build.
set -- "$sdk_lib"/libicuuc.so.*
require_file "$1"
set -- "$sdk_lib"/libicui18n.so.*
require_file "$1"
set -- "$sdk_lib"/libicudata.so.*
require_file "$1"

# The executable and the privately bundled EDS/calendar stack must come from
# the same build environment. Mixing host EDS with the bundled provider can
# load incompatible Camel or ECal ABIs when mail or calendar support starts.
for soname in $(objdump -p "$mailficient_binary" |
    awk '/NEEDED/ && ($2 ~ /^lib(camel|ebook|ebook-contacts|edataserver|edata-book|ecal)-/ || $2 ~ /^libical(-glib)?\.so/) { print $2 }'); do
    require_file "$runtime_lib/$soname"
done

install -d \
    "$stage/DEBIAN" \
    "$stage/usr/bin" \
    "$private_lib/evolution-data-server" \
    "$stage/usr/share/applications" \
    "$stage/usr/share/dbus-1/services" \
    "$stage/usr/share/doc/mailficient" \
    "$stage/usr/share/icons/hicolor" \
    "$stage/usr/share/metainfo" \
    "$stage/etc/xdg/autostart"

install -m 0755 "$mailficient_binary" "$private_lib/mailficient.real"
install -m 0755 "$probe_binary" \
    "$private_lib/mailficient-addressbook-probe.real"
install -m 0755 "$root_dir/packaging/debian/mailficient" "$stage/usr/bin/mailficient"
install -m 0755 "$root_dir/packaging/debian/mailficient-addressbook-probe" \
    "$stage/usr/bin/mailficient-addressbook-probe"

cp -a "$runtime_lib"/*.so* "$private_lib/"
cp -a "$provider_dir" \
    "$private_lib/evolution-data-server/"
if [ -e "$eds_private_lib" ]; then
    cp -a "$eds_private_lib" \
        "$private_lib/evolution-data-server/"
fi
cp -a "$sdk_lib"/libicuuc.so.* "$private_lib/"
cp -a "$sdk_lib"/libicui18n.so.* "$private_lib/"
cp -a "$sdk_lib"/libicudata.so.* "$private_lib/"

sed 's|^Exec=.*$|Exec=/usr/bin/mailficient|' \
    "$root_dir/data/com.local.Mailficient.desktop" \
    > "$stage/usr/share/applications/com.local.Mailficient.desktop"
chmod 0644 "$stage/usr/share/applications/com.local.Mailficient.desktop"
sed 's|^Exec=.*$|Exec=/usr/bin/mailficient --background|' \
    "$root_dir/data/com.local.Mailficient.Background.desktop" \
    > "$stage/etc/xdg/autostart/com.local.Mailficient.Background.desktop"
chmod 0644 "$stage/etc/xdg/autostart/com.local.Mailficient.Background.desktop"
sed 's|Exec=/app/bin/mailficient|Exec=/usr/bin/mailficient|' \
    "$root_dir/data/com.local.Mailficient.service" \
    > "$stage/usr/share/dbus-1/services/com.local.Mailficient.service"
chmod 0644 "$stage/usr/share/dbus-1/services/com.local.Mailficient.service"
install -m 0644 "$root_dir/data/com.local.Mailficient.metainfo.xml" \
    "$stage/usr/share/metainfo/"

for icon_size in 64x64 128x128 256x256 512x512; do
    install -d "$stage/usr/share/icons/hicolor/$icon_size/apps"
    install -m 0644 \
        "$root_dir/data/icons/hicolor/$icon_size/apps/com.local.Mailficient.png" \
        "$stage/usr/share/icons/hicolor/$icon_size/apps/"
done
install -m 0644 "$root_dir/README.md" "$stage/usr/share/doc/mailficient/README.md"
install -m 0644 "$root_dir/RELEASE_NOTES.md" \
    "$stage/usr/share/doc/mailficient/RELEASE_NOTES.md"
install -m 0644 "$root_dir/packaging/debian/copyright" \
    "$stage/usr/share/doc/mailficient/copyright"

# Normalize permissions inherited from bundled runtime artifacts. Package
# payloads must never depend on the umask or ownership of the build machine.
find "$private_lib" -type d -exec chmod 0755 {} +
find "$private_lib" -type f -exec chmod 0644 {} +
find "$stage" -type d -exec chmod 0755 {} +
chmod 0755 \
    "$private_lib/mailficient.real" \
    "$private_lib/mailficient-addressbook-probe.real" \
    "$stage/usr/bin/mailficient" \
    "$stage/usr/bin/mailficient-addressbook-probe"

install -m 0755 "$root_dir/packaging/debian/postinst" "$stage/DEBIAN/postinst"
install -m 0755 "$root_dir/packaging/debian/postrm" "$stage/DEBIAN/postrm"

# Fail before packaging if launchers or desktop integration files have unsafe
# or unusable modes. dpkg-deb --root-owner-group normalizes package ownership.
test "$(stat -c %a "$stage/usr/bin/mailficient")" = 755
test "$(stat -c %a "$stage/usr/lib/mailficient/mailficient.real")" = 755
test "$(stat -c %a "$stage/usr/share/applications/com.local.Mailficient.desktop")" = 644
test "$(stat -c %a "$stage/etc/xdg/autostart/com.local.Mailficient.Background.desktop")" = 644
test "$(stat -c %a "$stage/usr/share/dbus-1/services/com.local.Mailficient.service")" = 644
if find "$stage" -xdev ! -type l -perm /0022 -print -quit | grep -q .; then
    printf '%s\n' "Package contains group- or world-writable files" >&2
    exit 1
fi

installed_size=$(du -sk "$stage/usr" "$stage/etc" |
    awk '{ total += $1 } END { print total }')
sed \
    -e "s/@VERSION@/$package_version/" \
    -e "s/@ARCHITECTURE@/$architecture/" \
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
