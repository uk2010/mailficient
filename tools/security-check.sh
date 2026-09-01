#!/bin/sh
set -eu

failed=0

check_absent() {
  description=$1
  pattern=$2
  shift 2
  if grep -R -n -E -- "$pattern" "$@"; then
    printf 'security check failed: %s\n' "$description" >&2
    failed=1
  fi
}

check_present() {
  description=$1
  pattern=$2
  file=$3
  if ! grep -q -E -- "$pattern" "$file"; then
    printf 'security check failed: %s\n' "$description" >&2
    failed=1
  fi
}

# Marketplace action tags are mutable. Every remote workflow action must use
# an immutable 40-character commit id; local actions are exempt.
for workflow in .github/workflows/*.yml; do
  while IFS= read -r reference; do
    case "$reference" in
      ./*) ;;
      *@????????????????????????????????????????) ;;
      *)
        printf 'security check failed: unpinned action %s in %s\n' \
          "$reference" "$workflow" >&2
        failed=1
        ;;
    esac
  done <<EOF
$(sed -n -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*([^[:space:]#]+).*/\2/p' "$workflow")
EOF
done

check_absent 'Flatpak must not expose unconditional X11' \
  '"--socket=x11"' packaging
check_absent 'Snap must use document portals instead of broad home access' \
  '^[[:space:]]*-[[:space:]]*(home|removable-media)[[:space:]]*$' snap
check_present 'WebKitGTK security floor is missing' \
  "webkitgtk-6.0.*version: '>= 2\\.52\\.6'" meson.build
check_present 'the patched WebKitGTK release is not bundled' \
  'webkitgtk-2.52.6.tar.xz' packaging/com.local.Mailficient.Devel.json
check_present 'the libical overflow backport is not in the Flatpak manifest' \
  'libical-3.0.20-merge-overflow.patch' packaging/com.local.Mailficient.Devel.json
test -s packaging/patches/libical-3.0.20-merge-overflow.patch || {
  printf 'security check failed: libical overflow patch is absent\n' >&2
  failed=1
}

if git grep -n -E -- \
    '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' \
    -- . ':!tools/security-check.sh'; then
  printf 'security check failed: a likely credential was committed\n' >&2
  failed=1
fi

exit "$failed"
