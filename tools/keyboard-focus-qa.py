#!/usr/bin/env python3
"""Inspect the focused Mailficient control through AT-SPI."""

import sys
import time

import pyatspi


def descendants(node):
    yield node
    for index in range(node.childCount):
        child = node.getChildAtIndex(index)
        if child is not None:
            yield from descendants(child)


expected = sys.argv[1].casefold() if len(sys.argv) > 1 else ""
require_tab = len(sys.argv) > 2 and sys.argv[2] == "--contains-tab"
deadline = time.monotonic() + 5
last_focus = None
while time.monotonic() < deadline:
    desktop = pyatspi.Registry.getDesktop(0)
    app = next(
        (
            desktop.getChildAtIndex(index)
            for index in range(desktop.childCount)
            if "mailficient"
            in ((desktop.getChildAtIndex(index).name or "").casefold())
        ),
        None,
    )
    if app is not None:
        focused = next(
            (item for item in descendants(app) if item.getState().contains(pyatspi.STATE_FOCUSED)),
            None,
        )
        if focused is not None:
            name = (focused.name or "").strip()
            role = focused.getRoleName()
            last_focus = (role, name)
            text_matches = True
            if require_tab:
                try:
                    text_matches = "\t" in focused.queryText().getText(0, -1)
                except NotImplementedError:
                    text_matches = False
            if expected in name.casefold() and text_matches:
                print(f"Focused control: {role} {name!r}")
                raise SystemExit(0)
    time.sleep(0.1)

print(
    f"No focused Mailficient control matched {expected!r}; last focus was {last_focus!r}",
    file=sys.stderr,
)
raise SystemExit(1)
