#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/build"

# Reuse the repository's working native build when it is already configured.
# This is the exact build used by local QA and avoids needlessly entering the
# Flatpak SDK (which may be unavailable when its document portal is stale).
LOCAL_BUILD_DIR="$ROOT_DIR/build-local"
if command -v meson >/dev/null 2>&1 &&
   [ -f "$LOCAL_BUILD_DIR/build.ninja" ]; then
  meson compile -C "$LOCAL_BUILD_DIR" src/mailficient
  MAILFICIENT_DEV_INSTANCE=1 exec "$LOCAL_BUILD_DIR/src/mailficient" "$@"
fi

# Prefer a native build when the host provides Evolution Data Server's
# address-book API. The GNOME SDK used by the fallback build does not include
# libebook, which would compile Contacts support out of the application.
if command -v pkg-config >/dev/null 2>&1 &&
   pkg-config --exists gtk4 libadwaita-1 gee-0.8 gio-2.0 json-glib-1.0 sqlite3 \
     libsecret-1 webkitgtk-6.0 libxml-2.0 cairo pangocairo libebook-1.2; then
  BUILD_DIR="$ROOT_DIR/build-addressbook"
  if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    meson setup "$BUILD_DIR" "$ROOT_DIR" -Dcamel=disabled -Daddressbook=enabled
  fi
  meson compile -C "$BUILD_DIR" src/mailficient
  MAILFICIENT_DEV_INSTANCE=1 exec "$BUILD_DIR/src/mailficient" "$@"
fi

if ! command -v flatpak >/dev/null 2>&1; then
  printf '%s\n' "Flatpak is required to build Mailficient. See README.md for setup instructions." >&2
  exit 1
fi

if ! flatpak info --user org.gnome.Sdk//49 >/dev/null 2>&1; then
  printf '%s\n' "GNOME SDK 49 is not installed for this user." >&2
  printf '%s\n' "Install it with: flatpak install --user flathub org.gnome.Sdk//49" >&2
  exit 1
fi

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
  flatpak run --user --filesystem="$ROOT_DIR" --command=meson \
    org.gnome.Sdk//49 setup "$BUILD_DIR" "$ROOT_DIR"
fi

flatpak run --user --filesystem="$ROOT_DIR" --command=meson \
  org.gnome.Sdk//49 compile -C "$BUILD_DIR"

# The SDK sandbox cannot own com.local.Mailficient on the desktop session bus.
# Use the development application ID so this launcher always opens the binary
# built from this checkout instead of activating an installed Mailficient.
MAILFICIENT_DEV_INSTANCE=1 exec "$BUILD_DIR/src/mailficient" "$@"
