#!/bin/sh
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_BINARY=${MAIL_GOA_TEST_BINARY:-$ROOT_DIR/build-camel-goa/camel-tests}
APP_ID=${MAIL_GOA_APP_ID:-com.local.Mailficient}
overall=0

if [ ! -x "$TEST_BINARY" ]; then
  printf '%s\n' "Build the Camel tests first or set MAIL_GOA_TEST_BINARY." >&2
  exit 2
fi
if ! flatpak info --user "$APP_ID" >/dev/null 2>&1; then
  printf 'Flatpak application %s is not installed.\n' "$APP_ID" >&2
  exit 2
fi

ulimit -c 0
for provider in Google Microsoft; do
  log=$(mktemp "/tmp/mailficient-goa-${provider}.XXXXXX")
  MAILFICIENT_TEST_LIVE_GOA=1 MAILFICIENT_TEST_GOA_PROVIDER="$provider" \
    timeout 40s flatpak run --user --no-documents-portal \
      --filesystem="$ROOT_DIR" --command="$TEST_BINARY" "$APP_ID" \
      -p /camel/integration/live-goa-connection >"$log" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s: PASS (connect and disconnect)\n' "$provider"
  elif grep -q "No mail-enabled GNOME Online Account" "$log"; then
    printf '%s: UNAVAILABLE (no mail-enabled account configured)\n' "$provider"
    overall=1
  elif grep -Eqi "NotAuthorized|needs authorization|No credentials found" "$log"; then
    printf '%s: AUTHORIZATION REQUIRED\n' "$provider"
    overall=1
  elif [ "$status" -eq 124 ]; then
    printf '%s: TIMEOUT after 40 seconds\n' "$provider"
    overall=1
  else
    printf '%s: FAIL (status %s)\n' "$provider" "$status"
    sed -E 's/[[:alnum:]._%+-]+@[[:alnum:].-]+/[account]/g' "$log" | tail -8
    overall=1
  fi
  rm -f "$log"
done
exit "$overall"
