#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/build"

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
exec "$BUILD_DIR/src/mailficient" "$@"
