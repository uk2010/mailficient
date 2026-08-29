#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DISPLAY_NUMBER=${MAIL_SIDEBAR_QA_DISPLAY:-:96}
CLIENT_DISPLAY="127.0.0.1${DISPLAY_NUMBER}"
if command -v Xvfb >/dev/null 2>&1; then
  XVFB=$(command -v Xvfb)
else
  XVFB=/tmp/mailficient-xvfb/root/usr/bin/Xvfb
fi
APP_BINARY=${MAIL_SIDEBAR_QA_BINARY:-$ROOT_DIR/build/src/mailficient}
QA_DATA_DIR=$(mktemp -d /tmp/mailficient-sidebar-actions.XXXXXX)
LOG=${MAIL_SIDEBAR_QA_LOG:-/tmp/mailficient-sidebar-context-qa.log}
SHOT=${MAIL_SIDEBAR_QA_SHOT:-/tmp/mailficient-sidebar-context-action.png}

case "$APP_BINARY" in
  /*) ;;
  *) APP_BINARY=$ROOT_DIR/$APP_BINARY ;;
esac

if [ ! -x "$XVFB" ]; then
  printf '%s\n' "Xvfb is required for sidebar context QA" >&2
  exit 1
fi
if [ ! -x "$APP_BINARY" ]; then
  printf 'Mailficient QA binary is not executable: %s\n' "$APP_BINARY" >&2
  exit 1
fi

"$XVFB" "$DISPLAY_NUMBER" -ac -screen 0 1400x900x24 -nolisten unix \
  -nolisten local -listen tcp >"$LOG" 2>&1 &
XVFB_PID=$!
APP_PID=
cleanup () {
  status=$?
  if [ -n "$APP_PID" ]; then
    kill -TERM "-$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  kill "$XVFB_PID" 2>/dev/null || true
  rm -rf "$QA_DATA_DIR"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
sleep 1

cd "$ROOT_DIR"
DISPLAY="$CLIENT_DISPLAY" setsid dbus-run-session -- env \
  GDK_BACKEND=x11 G_DEBUG=fatal-criticals NO_AT_BRIDGE=1 GTK_A11Y=none \
  MAILFICIENT_QA=1 MAILFICIENT_QA_SIDEBAR_MENU=1 \
  XDG_DATA_HOME="$QA_DATA_DIR" "$APP_BINARY" >>"$LOG" 2>&1 &
APP_PID=$!
sleep 4

# The QA hook opens the real Flagged-row context popover at a stable point.
# Clicking its New Rule item exercises the same popover/action dispatch path
# as a physical secondary-click, including the deferred action-group lifetime.
DISPLAY="$CLIENT_DISPLAY" python3 tools/x11-click.py 96 400
sleep 2

DISPLAY="$CLIENT_DISPLAY" xwininfo -root -tree >>"$LOG" 2>&1
if ! grep -q '"Rules"' "$LOG"; then
  printf '%s\n' "Sidebar New Rule action did not open the Rules window" >&2
  sed -n '1,240p' "$LOG"
  exit 1
fi
DISPLAY="$CLIENT_DISPLAY" import -window root "$SHOT"
if grep -E '\(mailficient.*(CRITICAL|ERROR)' "$LOG"; then
  exit 1
fi
printf '%s\n' "Sidebar context QA passed: New Rule dispatched and opened Rules."
printf '%s\n' "$SHOT"
