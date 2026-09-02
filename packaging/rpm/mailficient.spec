Name:           mailficient
Version:        %{mailficient_version}
Release:        %{mailficient_release}
Summary:        Native GTK email client
License:        GPL-3.0-or-later
URL:            https://github.com/uk2010/mailficient

Requires:       gtk4 >= 4.12
Requires:       evolution-data-server
Requires:       geoclue2-libs
Requires:       libadwaita >= 1.5
Requires:       libgee
Requires:       json-glib
Requires:       libsecret
Requires:       sqlite-libs
Requires:       webkitgtk6.0 >= 2.52.6
Requires:       libxml2
Requires:       gnupg2
Recommends:     gnome-keyring
Recommends:     gsettings-desktop-schemas
Recommends:     geoclue2
Recommends:     enchant2
Recommends:     hunspell-en-US

%description
Mailficient is a native GTK4 and Libadwaita desktop email client with standard
IMAP and SMTP support, secure credential storage, offline mail, search, drafts,
attachments, tasks, calendar invitations, compose safeguards, automation, and
phishing-aware message display.

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
    %{buildroot}%{_datadir}/metainfo \
    %{buildroot}%{_sysconfdir}/xdg/autostart

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

for app_library in %{mailficient_app_tree}/lib/*.so*; do
    case "$(basename "$app_library")" in
        libwebkitgtk-6.0.so*|libjavascriptcoregtk-6.0.so*) continue ;;
    esac
    cp -a "$app_library" %{buildroot}%{_libdir}/mailficient/
done
cp -a %{mailficient_app_tree}/lib/evolution-data-server \
    %{buildroot}%{_libdir}/mailficient/
cp -a %{mailficient_app_tree}/lib/libgweather-4 \
    %{buildroot}%{_libdir}/mailficient/

install -d %{buildroot}%{_libdir}/mailficient/schemas
install -m 0644 \
    %{mailficient_app_tree}/share/glib-2.0/schemas/org.gnome.calendar.gschema.xml \
    %{mailficient_app_tree}/share/glib-2.0/schemas/org.gnome.calendar.enums.xml \
    %{mailficient_app_tree}/share/glib-2.0/schemas/org.gnome.GWeather4.gschema.xml \
    %{buildroot}%{_libdir}/mailficient/schemas/
glib-compile-schemas %{buildroot}%{_libdir}/mailficient/schemas

for sdk_library in %{mailficient_sdk_lib}/libxml2.so.* \
    %{mailficient_sdk_lib}/libicuuc.so.* \
    %{mailficient_sdk_lib}/libicui18n.so.* \
    %{mailficient_sdk_lib}/libicudata.so.*; do
    if test -e "$sdk_library"; then
        cp -a "$sdk_library" \
            %{buildroot}%{_libdir}/mailficient/
    fi
done

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
sed 's|^Exec=.*$|Exec=/usr/bin/mailficient --background|' \
    %{mailficient_source_root}/data/com.local.Mailficient.Background.desktop \
    > %{buildroot}%{_sysconfdir}/xdg/autostart/com.local.Mailficient.Background.desktop
chmod 0644 \
    %{buildroot}%{_sysconfdir}/xdg/autostart/com.local.Mailficient.Background.desktop
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
%config(noreplace) %{_sysconfdir}/xdg/autostart/com.local.Mailficient.Background.desktop
%{_datadir}/applications/com.local.Mailficient.desktop
%{_datadir}/dbus-1/services/com.local.Mailficient.service
%{_datadir}/icons/hicolor/*/apps/com.local.Mailficient.png
%{_datadir}/metainfo/com.local.Mailficient.metainfo.xml
%{_datadir}/evolution-data-server/

%changelog
* Tue Sep 01 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.7.0-0.1.beta
- Embed the GNOME Calendar interface and its weather data while continuing to
  use the shared Evolution Data Server calendar store.

* Tue Sep 01 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.6.0-0.1.beta
- Promote Today, Events, and Calendar to direct GNOME Calendar-backed Favorites.
- Harden HTML rendering and application security for the beta release.

* Mon Aug 31 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.5.0-0.1.beta
- Open the Mailficient 0.5 public beta and preserve the Junk toolbar label in
  Icon and Text mode when the action icon changes.

* Mon Aug 31 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.4.4-1
- Restore explicit minimize and maximize controls in the custom main-window
  toolbar across supported desktops and architectures.

* Mon Aug 31 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.4.3-1
- Prevent selection crashes during mail checks and bound HTML-reader memory
  during rapid message navigation.

* Sun Aug 30 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.4.2-1
- Bound memory during repeated favorite switching and remove populated-to-empty
  favorite navigation stalls.

* Sun Aug 30 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.4.1-1
- Add drag-and-drop toolbar customization and whole-app color selection, and
  fix adaptive styling, toolbar responsiveness, and retained memory.

* Fri Aug 28 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.4.0-1
- Add provider-backed folder and subfolder management, a dedicated advanced
  Rules window, and a compact adaptive interface across mail and settings.

* Thu Aug 27 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.3.2-1
- Make foreground sending reliable, make Undo Send optional and move it to a
  bottom-window action, and fix stale conversation and unread indicators.

* Thu Aug 27 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.3.1-1
- Remove the 500-message ceiling and stabilize Inbox refreshes during large
  initial synchronization.

* Thu Aug 27 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.3.0-1
- Move sender safety lists into a separate searchable management window.

* Wed Aug 26 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.9-1
- Improve mail-check speed, task navigation, draft cleanup, HTML rendering,
  folder state updates, message selection, and interface polish.

* Tue Aug 25 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.8-1
- Add compose safeguards, tasks, calendar RSVP, message safety, advanced rules,
  Quick Steps, server search, and release polish.

* Sun Aug 23 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.7-1
- Clear and persist unread state when messages are opened directly.

* Sun Aug 23 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.6-1
- Keep unread indicators, mailbox counts, and read-action labels synchronized.

* Sun Aug 23 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.5-1
- Improve favorite switching and update move and copy destinations immediately.

* Sun Aug 23 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.4-1
- Improve responsive toolbar spacing and compact-toolbar hover rendering.

* Sun Aug 23 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.3-1
- Enable GNOME Contacts and publish refreshed 0.2.3 packages.

* Sat Aug 22 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.2.2-1
- Require Ctrl for letter-based mail shortcuts and publish 0.2.2 packages.

* Fri Aug 21 2026 Mailficient Maintainers <uk2010@users.noreply.github.com> - 0.1.19-1
- Add x86_64 and aarch64 RPM packages for the 0.1.19 release.
