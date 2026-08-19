Name:           mailficient
Version:        %{mailficient_version}
Release:        %{mailficient_release}
Summary:        Native GTK email client
License:        GPL-3.0-or-later
URL:            https://github.com/uk2010/mailficient

Requires:       gtk4 >= 4.12
Requires:       libadwaita >= 1.5
Requires:       libgee
Requires:       json-glib
Requires:       libsecret
Requires:       sqlite-libs
Requires:       webkitgtk6.0
Requires:       libxml2
Requires:       gnupg2
Recommends:     gnome-keyring
Recommends:     gsettings-desktop-schemas

%description
Mailficient is a native GTK4 and Libadwaita desktop email client with standard
IMAP and SMTP support, secure credential storage, offline mail, search, drafts,
attachments, and safe HTML message display.

%prep

%build

%install
rm -rf %{buildroot}

install -d \
    %{buildroot}%{_bindir} \
    %{buildroot}%{_libdir}/mailficient/evolution-data-server \
    %{buildroot}%{_datadir}/applications \
    %{buildroot}%{_datadir}/dbus-1/services \
    %{buildroot}%{_datadir}/doc/mailficient \
    %{buildroot}%{_datadir}/icons/hicolor \
    %{buildroot}%{_datadir}/metainfo

sed 's|@LIBDIR@|%{_libdir}|g' \
    %{mailficient_source_root}/packaging/rpm/mailficient \
    > %{buildroot}%{_bindir}/mailficient
install -m 0755 %{mailficient_app_tree}/bin/mailficient \
    %{buildroot}%{_libdir}/mailficient/mailficient.real

if test -x %{mailficient_app_tree}/bin/mailficient-addressbook-probe; then
    sed 's|@LIBDIR@|%{_libdir}|g' \
        %{mailficient_source_root}/packaging/rpm/mailficient-addressbook-probe \
        > %{buildroot}%{_bindir}/mailficient-addressbook-probe
    install -m 0755 %{mailficient_app_tree}/bin/mailficient-addressbook-probe \
        %{buildroot}%{_libdir}/mailficient/mailficient-addressbook-probe.real
fi

cp -a %{mailficient_app_tree}/lib/*.so* \
    %{buildroot}%{_libdir}/mailficient/
cp -a %{mailficient_app_tree}/lib/evolution-data-server \
    %{buildroot}%{_libdir}/mailficient/

command -v patchelf
find %{buildroot}%{_libdir}/mailficient -type f -exec sh -c '
    for elf_file do
        if file "$elf_file" | grep -q "ELF"; then
            patchelf --set-rpath \
                "%{_libdir}/mailficient:%{_libdir}/mailficient/evolution-data-server" \
                "$elf_file"
        fi
    done
' sh {} +

if test -d %{mailficient_app_tree}/share/evolution-data-server; then
    cp -a %{mailficient_app_tree}/share/evolution-data-server \
        %{buildroot}%{_datadir}/
fi

sed 's|^Exec=.*$|Exec=/usr/bin/mailficient|' \
    %{mailficient_app_tree}/share/applications/com.local.Mailficient.desktop \
    > %{buildroot}%{_datadir}/applications/com.local.Mailficient.desktop
sed 's|Exec=/app/bin/mailficient|Exec=/usr/bin/mailficient|' \
    %{mailficient_app_tree}/share/dbus-1/services/com.local.Mailficient.service \
    > %{buildroot}%{_datadir}/dbus-1/services/com.local.Mailficient.service
install -m 0644 %{mailficient_app_tree}/share/metainfo/com.local.Mailficient.metainfo.xml \
    %{buildroot}%{_datadir}/metainfo/

for icon_size in 64x64 128x128 256x256 512x512; do
    install -d %{buildroot}%{_datadir}/icons/hicolor/$icon_size/apps
    install -m 0644 \
        %{mailficient_app_tree}/share/icons/hicolor/$icon_size/apps/com.local.Mailficient.png \
        %{buildroot}%{_datadir}/icons/hicolor/$icon_size/apps/
done

install -m 0644 %{mailficient_source_root}/README.md \
    %{buildroot}%{_datadir}/doc/mailficient/README.md
install -m 0644 %{mailficient_source_root}/RELEASE_NOTES.md \
    %{buildroot}%{_datadir}/doc/mailficient/RELEASE_NOTES.md
install -m 0644 %{mailficient_source_root}/LICENSE \
    %{buildroot}%{_datadir}/doc/mailficient/LICENSE

find %{buildroot}%{_libdir}/mailficient -type d -exec chmod 0755 {} +
find %{buildroot}%{_libdir}/mailficient -type f -exec chmod 0644 {} +
chmod 0755 \
    %{buildroot}%{_bindir}/mailficient \
    %{buildroot}%{_libdir}/mailficient/mailficient.real
if test -e %{buildroot}%{_bindir}/mailficient-addressbook-probe; then
    chmod 0755 \
        %{buildroot}%{_bindir}/mailficient-addressbook-probe \
        %{buildroot}%{_libdir}/mailficient/mailficient-addressbook-probe.real
fi

%files
%license %{_datadir}/doc/mailficient/LICENSE
%doc %{_datadir}/doc/mailficient/README.md
%doc %{_datadir}/doc/mailficient/RELEASE_NOTES.md
%{_bindir}/mailficient
%if 0%{?mailficient_has_addressbook}
%{_bindir}/mailficient-addressbook-probe
%endif
%{_libdir}/mailficient/
%{_datadir}/applications/com.local.Mailficient.desktop
%{_datadir}/dbus-1/services/com.local.Mailficient.service
%{_datadir}/icons/hicolor/*/apps/com.local.Mailficient.png
%{_datadir}/metainfo/com.local.Mailficient.metainfo.xml
%{_datadir}/evolution-data-server/

%changelog
* Tue Aug 18 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.1.18-1
- Add x86_64 and aarch64 RPM packages for the 0.1.18 release.
