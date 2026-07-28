#!/usr/bin/env python3
import ctypes
import os
import sys
import time


if len(sys.argv) not in (3, 4, 5, 6):
    raise SystemExit("usage: x11-click.py X Y [DELAY_SECONDS] [BUTTON] [CLICKS]")

delay = float(sys.argv[3]) if len(sys.argv) == 4 else 0.0
if len(sys.argv) >= 4:
    delay = float(sys.argv[3])
button = int(sys.argv[4]) if len(sys.argv) >= 5 else 1
clicks = int(sys.argv[5]) if len(sys.argv) >= 6 else 1
time.sleep(delay)

x11 = ctypes.CDLL("libX11.so.6")
xtst = ctypes.CDLL("libXtst.so.6")
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XFlush.argtypes = [ctypes.c_void_p]
xtst.XTestFakeMotionEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong
]
xtst.XTestFakeButtonEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong
]

display_name = os.environ.get("DISPLAY", "").encode()
display = x11.XOpenDisplay(display_name)
if not display:
    raise SystemExit(f"could not open X display {display_name!r}")

xtst.XTestFakeMotionEvent(display, -1, int(sys.argv[1]), int(sys.argv[2]), 0)
for _ in range(clicks):
    xtst.XTestFakeButtonEvent(display, button, 1, 0)
    xtst.XTestFakeButtonEvent(display, button, 0, 0)
x11.XFlush(display)
