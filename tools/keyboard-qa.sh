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
PYATSPI_PATH=${MAIL_QA_PYATSPI_PATH:-/tmp/mailficient-pyatspi/usr/lib/python3/dist-packages}
QA_DATA_DIR=$(mktemp -d /tmp/mailficient-keyboard-data.XXXXXX)
LOG=/tmp/mailficient-keyboard-qa.log
APP_BINARY=${MAIL_KEYBOARD_BINARY:-$ROOT_DIR/build/src/mailficient}
case "$APP_BINARY" in
  /*) ;;
  *) APP_BINARY=$ROOT_DIR/$APP_BINARY ;;
esac

if [ ! -x "$XVFB" ]; then
  printf '%s\n' "Xvfb is required for keyboard QA" >&2
  exit 1
fi
if [ ! -x "$APP_BINARY" ]; then
  printf 'Mailficient QA binary is not executable: %s\n' "$APP_BINARY" >&2
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
    "$6" >>"$3" 2>&1 &
  app_pid=$!
  trap "kill $app_pid 2>/dev/null || true" EXIT
  sleep 3
  client_display=$4
  root_dir=$2
  pyatspi_path=$5
  xkey() { DISPLAY="$client_display" python3 "$root_dir/tools/x11-key.py" "$@"; }
  xkey key ctrl+f
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" Search
  xkey key ctrl+n
  sleep 1
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" Recipients
  xkey key Tab Tab Tab Tab Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" "Message body"
  xkey key Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" "Attach files"
  xkey key shift+Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" "Message body"
  xkey key ctrl+Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" "Message body" --contains-tab
  xkey key shift+Tab
  PYTHONPATH="$pyatspi_path${PYTHONPATH:+:$PYTHONPATH}" python3 "$2/tools/keyboard-focus-qa.py" "Message subject"
  xkey key ctrl+Return
  sleep 1
  kill -0 "$app_pid"
  printf "%s\n" "Keyboard QA passed: search/compose shortcuts, forward and reverse body traversal, Ctrl+Tab insertion, and safe Ctrl+Enter validation."
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  trap - EXIT
' sh "$QA_DATA_DIR" "$ROOT_DIR" "$LOG" "$CLIENT_DISPLAY" "$PYATSPI_PATH" "$APP_BINARY"
