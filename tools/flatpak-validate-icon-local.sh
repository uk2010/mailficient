#!/bin/sh
set -eu

# Flatpak normally invokes its system icon validator in a bubblewrap sandbox.
# Restricted development environments cannot create that namespace, so this
# validator performs the same essential checks with ImageMagick.
if [ "${1:-}" = "--sandbox" ]; then shift; fi
if [ "$#" -ne 3 ]; then
    echo "usage: $0 [--sandbox] WIDTH HEIGHT ICON" >&2
    exit 2
fi
expected_width=$1
expected_height=$2
icon_path=$3
details=$(identify -quiet -format '%m %w %h' "$icon_path")
set -- $details
if [ "$#" -ne 3 ] || [ "$1" != "PNG" ] || [ "$2" -ne "$3" ] ||
   [ "$2" -gt "$expected_width" ] || [ "$3" -gt "$expected_height" ]; then
    echo "invalid Flatpak PNG icon: $icon_path (maximum ${expected_width}x${expected_height}; got ${details:-unreadable})" >&2
    exit 1
fi
