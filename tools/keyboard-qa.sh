#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DISPLAY_NUMBER=${MAIL_KEYBOARD_DISPLAY:-:97}
CLIENT_DISPLAY="127.0.0.1${DISPLAY_NUMBER}"
if command -v Xvfb >/dev/null 2>&1; then
  XVFB=$(command -v Xvfb)
else
  XVFB=/tmp/mailficient-xvfb/root/usr/bin/Xvfb
fi
if command -v xdotool >/dev/null 2>&1; then
  XDOTOOL=$(command -v xdotool)
  XDO_LIBRARY_PATH=
else
  XDOTOOL=/tmp/mailficient-xdotool/usr/bin/xdotool
  XDO_LIBRARY_PATH=/tmp/mailficient-xdotool/usr/lib/x86_64-linux-gnu
fi
PYATSPI_PATH=${MAIL_QA_PYATSPI_PATH:-/tmp/mailficient-pyatspi/usr/lib/python3/dist-packages}
QA_DATA_DIR=$(mktemp -d /tmp/mailficient-keyboard-data.XXXXXX)
LOG=/tmp/mailficient-keyboard-qa.log

if [ ! -x "$XVFB" ] || [ ! -x "$XDOTOOL" ]; then
  printf '%s\n' "Xvfb and xdotool are required for keyboard QA" >&2
  exit 1
fi
if ! PYTHONPATH="$PYATSPI_PATH${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import pyatspi' 2>/dev/null; then
  printf '%s\n' "python3-pyatspi is required for keyboard QA" >&2
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

cd "$ROOT_DIR"
DISPLAY="$CLIENT_DISPLAY" dbus-run-session -- sh -c '
  set -eu
  GDK_BACKEND=x11 GTK_A11Y=atspi MAILFICIENT_QA=1 XDG_DATA_HOME="$1" \
    "$2/build/src/mailficient" >>"$3" 2>&1 &
  app_pid=$!
  trap "kill $app_pid 2>/dev/null || true" EXIT
  sleep 3
  client_display=$4
  xdo_library_path=$5
  xdotool=$6
  pyatspi_path=$7
  xdo() { DISPLAY="$client_display" LD_LIBRARY_PATH="$xdo_library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$xdotool" "$@"; }
  main_window=$(xdo search --onlyvisible --name "Mailficient" | head -1)
  test -n "$main_window"
  xdo windowfocus --sync "$main_window" key --clearmodifiers ctrl+f
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" Search
  xdo key --clearmodifiers ctrl+n
  sleep 1
  compose_window=$(xdo search --onlyvisible --name "New Message" | head -1)
  test -n "$compose_window"
  xdo windowfocus --sync "$compose_window" key --clearmodifiers Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" ""
  printf "%s\n" "Keyboard QA passed: Ctrl+F focused Search, Ctrl+N opened compose, and Tab moved focus."
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  trap - EXIT
' sh "$QA_DATA_DIR" "$ROOT_DIR" "$LOG" "$CLIENT_DISPLAY" "$XDO_LIBRARY_PATH" "$XDOTOOL" "$PYATSPI_PATH"
