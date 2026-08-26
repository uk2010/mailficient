#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DISPLAY_NUMBER=${MAIL_A11Y_DISPLAY:-:98}
CLIENT_DISPLAY="127.0.0.1${DISPLAY_NUMBER}"
if command -v Xvfb >/dev/null 2>&1; then
  XVFB=$(command -v Xvfb)
else
  XVFB=/tmp/mailficient-xvfb/root/usr/bin/Xvfb
fi
PYATSPI_PATH=${MAIL_QA_PYATSPI_PATH:-/tmp/mailficient-pyatspi/usr/lib/python3/dist-packages}
QA_DATA_DIR=$(mktemp -d /tmp/mailficient-a11y-data.XXXXXX)
LOG=/tmp/mailficient-accessibility-qa.log
APP_BINARY=${MAIL_A11Y_BINARY:-$ROOT_DIR/build/src/mailficient}
case "$APP_BINARY" in
  /*) ;;
  *) APP_BINARY=$ROOT_DIR/$APP_BINARY ;;
esac

if [ ! -x "$XVFB" ]; then
  printf '%s\n' "Xvfb is required for accessibility QA" >&2
  exit 1
fi
if [ ! -x "$APP_BINARY" ]; then
  printf 'Mailficient QA binary is not executable: %s\n' "$APP_BINARY" >&2
  exit 1
fi
if ! PYTHONPATH="$PYATSPI_PATH${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import pyatspi' 2>/dev/null; then
  printf '%s\n' "python3-pyatspi is required for accessibility QA" >&2
  exit 1
fi

"$XVFB" "$DISPLAY_NUMBER" -ac -screen 0 1400x900x24 -nolisten unix -nolisten local -listen tcp >"$LOG" 2>&1 &
XVFB_PID=$!
cleanup() {
  status=$?
  kill "$XVFB_PID" 2>/dev/null || true
  rm -rf "$QA_DATA_DIR"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
sleep 1
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
  sed -n '1,120p' "$LOG"
  exit 1
fi

cd "$ROOT_DIR"
DISPLAY="$CLIENT_DISPLAY" dbus-run-session -- sh -c '
  set -eu
  GDK_BACKEND=x11 GTK_A11Y=atspi MAILFICIENT_QA=1 XDG_DATA_HOME="$1" \
    "$5" >>"$3" 2>&1 &
  app_pid=$!
  trap "kill $app_pid 2>/dev/null || true" EXIT
  sleep 3
  status=0
  PYTHONPATH="$4${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/accessibility-qa.py" || status=$?
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  trap - EXIT
  exit "$status"
' sh "$QA_DATA_DIR" "$ROOT_DIR" "$LOG" "$PYATSPI_PATH" "$APP_BINARY"
