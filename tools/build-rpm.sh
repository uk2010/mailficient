#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_tree=${MAILFICIENT_FLATPAK_APP_TREE:-"$root_dir/flatpak-build/files"}
rpm_architecture=${MAILFICIENT_RPM_ARCHITECTURE:-$(uname -m)}
case "$rpm_architecture" in
    amd64|x86_64) rpm_architecture=x86_64 ;;
    arm64|aarch64) rpm_architecture=aarch64 ;;
    *) printf 'Unsupported RPM architecture: %s\n' "$rpm_architecture" >&2; exit 1 ;;
esac

if [ -n "${MAILFICIENT_SDK_LIB:-}" ]; then
    sdk_lib=$MAILFICIENT_SDK_LIB
else
    sdk_location=$(flatpak info -l org.gnome.Sdk//49)
    case "$rpm_architecture" in
        x86_64) sdk_multiarch=x86_64-linux-gnu ;;
        aarch64) sdk_multiarch=aarch64-linux-gnu ;;
    esac
    sdk_lib="$sdk_location/files/lib/$sdk_multiarch"
fi

if [ ! -x "$app_tree/bin/mailficient" ]; then
    printf 'Required application binary is missing: %s\n' "$app_tree/bin/mailficient" >&2
    exit 1
fi
for required_file in \
    "$app_tree/share/applications/com.local.Mailficient.desktop" \
    "$app_tree/share/dbus-1/services/com.local.Mailficient.service" \
    "$app_tree/share/metainfo/com.local.Mailficient.metainfo.xml"; do
    if [ ! -f "$required_file" ]; then
        printf 'Required application file is missing: %s\n' "$required_file" >&2
        exit 1
    fi
done
for sdk_library in libxml2.so.* libicuuc.so.* libicui18n.so.* libicudata.so.*; do
    set -- "$sdk_lib"/$sdk_library
    if ! [ -e "$1" ]; then
        printf 'Required SDK library is missing: %s/%s\n' "$sdk_lib" "$sdk_library" >&2
        exit 1
    fi
done

app_version=$(grep -o "version: '[0-9][^']*'" "$root_dir/meson.build" |
    head -n 1 |
    cut -d "'" -f 2)
rpm_release=${MAILFICIENT_RPM_RELEASE:-1}
build_root=$(mktemp -d "$root_dir/build-rpm.XXXXXX")
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
topdir="$build_root/rpmbuild"
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

has_addressbook=0
if [ -x "$app_tree/bin/mailficient-addressbook-probe" ]; then
    has_addressbook=1
fi

rpmbuild \
    --target "$rpm_architecture" \
    --define "_topdir $topdir" \
    --define "mailficient_version $app_version" \
    --define "mailficient_release $rpm_release" \
    --define "mailficient_source_root $root_dir" \
    --define "mailficient_app_tree $app_tree" \
    --define "mailficient_sdk_lib $sdk_lib" \
    --define "mailficient_has_addressbook $has_addressbook" \
    -bb "$root_dir/packaging/rpm/mailficient.spec"

output_dir="$root_dir/dist"
output="$output_dir/mailficient-$app_version-$rpm_release.$rpm_architecture.rpm"
mkdir -p "$output_dir"
find "$topdir/RPMS/$rpm_architecture" -maxdepth 1 -type f -name '*.rpm' -exec cp -f {} "$output" \;
if [ ! -f "$output" ]; then
    printf 'rpmbuild did not produce the expected package for %s\n' "$rpm_architecture" >&2
    exit 1
fi
checksum="$output.sha256"
(
    cd "$output_dir"
    sha256sum "$(basename "$output")" > "$(basename "$checksum")"
)

printf 'Built %s\n' "$output"
printf 'Checksum %s\n' "$checksum"
rpm -qip "$output"
