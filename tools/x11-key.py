#!/usr/bin/env python3
"""Focus an X11 window or inject key presses for headless UI QA."""

import ctypes
import os
import sys
import time


Window = ctypes.c_ulong
Display = ctypes.c_void_p

x11 = ctypes.CDLL("libX11.so.6")
xtst = ctypes.CDLL("libXtst.so.6")
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = Display
x11.XDefaultRootWindow.argtypes = [Display]
x11.XDefaultRootWindow.restype = Window
x11.XQueryTree.argtypes = [
    Display,
    Window,
    ctypes.POINTER(Window),
    ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)),
    ctypes.POINTER(ctypes.c_uint),
]
x11.XQueryTree.restype = ctypes.c_int
x11.XFetchName.argtypes = [Display, Window, ctypes.POINTER(ctypes.c_char_p)]
x11.XFetchName.restype = ctypes.c_int
x11.XFree.argtypes = [ctypes.c_void_p]
x11.XRaiseWindow.argtypes = [Display, Window]
x11.XSetInputFocus.argtypes = [Display, Window, ctypes.c_int, ctypes.c_ulong]
x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
x11.XStringToKeysym.restype = ctypes.c_ulong
x11.XKeysymToKeycode.argtypes = [Display, ctypes.c_ulong]
x11.XKeysymToKeycode.restype = ctypes.c_ubyte
x11.XFlush.argtypes = [Display]
x11.XSync.argtypes = [Display, ctypes.c_int]
x11.XCloseDisplay.argtypes = [Display]
xtst.XTestFakeKeyEvent.argtypes = [Display, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]


def window_name(display, window):
    value = ctypes.c_char_p()
    if not x11.XFetchName(display, window, ctypes.byref(value)) or not value.value:
        return ""
    try:
        return value.value.decode("utf-8", errors="replace")
    finally:
        x11.XFree(ctypes.cast(value, ctypes.c_void_p))


def descendants(display, parent):
    root = Window()
    returned_parent = Window()
    children = ctypes.POINTER(Window)()
    count = ctypes.c_uint()
    if not x11.XQueryTree(
        display,
        parent,
        ctypes.byref(root),
        ctypes.byref(returned_parent),
        ctypes.byref(children),
        ctypes.byref(count),
    ):
        return
    try:
        for index in reversed(range(count.value)):
            child = children[index]
            yield child
            yield from descendants(display, child)
    finally:
        if children:
            x11.XFree(children)


def find_window(display, title):
    expected = title.casefold()
    root = x11.XDefaultRootWindow(display)
    return next(
        (window for window in descendants(display, root) if expected in window_name(display, window).casefold()),
        None,
    )


def key_code(display, name):
    symbol = x11.XStringToKeysym(name.encode("ascii"))
    code = x11.XKeysymToKeycode(display, symbol)
    if not symbol or not code:
        raise SystemExit(f"unknown X11 key {name!r}")
    return code


def send_key(display, expression):
    parts = expression.split("+")
    modifier_names = {
        "ctrl": "Control_L",
        "control": "Control_L",
        "shift": "Shift_L",
        "alt": "Alt_L",
    }
    modifiers = [key_code(display, modifier_names[part.casefold()]) for part in parts[:-1]]
    key = key_code(display, parts[-1])
    for modifier in modifiers:
        xtst.XTestFakeKeyEvent(display, modifier, True, 0)
    xtst.XTestFakeKeyEvent(display, key, True, 0)
    xtst.XTestFakeKeyEvent(display, key, False, 0)
    for modifier in reversed(modifiers):
        xtst.XTestFakeKeyEvent(display, modifier, False, 0)
    x11.XFlush(display)


if len(sys.argv) < 3 or sys.argv[1] not in ("focus", "key"):
    raise SystemExit("usage: x11-key.py focus WINDOW_TITLE | key KEY [KEY ...]")

display_name = os.environ.get("DISPLAY", "").encode()
display = x11.XOpenDisplay(display_name)
if not display:
    raise SystemExit(f"could not open X display {display_name!r}")
try:
    if sys.argv[1] == "focus":
        deadline = time.monotonic() + 5
        window = None
        while window is None and time.monotonic() < deadline:
            window = find_window(display, sys.argv[2])
            if window is None:
                time.sleep(0.1)
        if window is None:
            raise SystemExit(f"no X11 window matched {sys.argv[2]!r}")
        x11.XRaiseWindow(display, window)
        x11.XSetInputFocus(display, window, 2, 0)
        x11.XSync(display, False)
    else:
        for expression in sys.argv[2:]:
            send_key(display, expression)
            time.sleep(0.05)
finally:
    x11.XCloseDisplay(display)
