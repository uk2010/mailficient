#!/usr/bin/env python3
"""Audit visible Mailficient controls through the same AT-SPI tree Orca uses."""

import sys
import time

import pyatspi


INTERACTIVE_ROLES = {
    pyatspi.ROLE_PUSH_BUTTON,
    pyatspi.ROLE_TOGGLE_BUTTON,
    pyatspi.ROLE_CHECK_BOX,
    pyatspi.ROLE_RADIO_BUTTON,
    pyatspi.ROLE_COMBO_BOX,
    pyatspi.ROLE_ENTRY,
    pyatspi.ROLE_PASSWORD_TEXT,
    pyatspi.ROLE_MENU_ITEM,
    pyatspi.ROLE_CHECK_MENU_ITEM,
    pyatspi.ROLE_RADIO_MENU_ITEM,
    pyatspi.ROLE_LIST_ITEM,
}


def find_application():
    for _ in range(50):
        desktop = pyatspi.Registry.getDesktop(0)
        for index in range(desktop.childCount):
            application = desktop.getChildAtIndex(index)
            if application and "mailficient" in (application.name or "").lower():
                return application
        time.sleep(0.1)
    return None


def walk(node, depth=0):
    yield node, depth
    for index in range(node.childCount):
        child = node.getChildAtIndex(index)
        if child is not None:
            yield from walk(child, depth + 1)


def descendant_names(node, limit=3):
    names = []
    for descendant, depth in walk(node):
        if depth == 0:
            continue
        name = (descendant.name or "").strip()
        if name and name not in names:
            names.append(name)
            if len(names) >= limit:
                break
    return names


def main():
    application = find_application()
    if application is None:
        print("Mailficient did not appear on the AT-SPI desktop", file=sys.stderr)
        return 1

    unnamed = []
    visible_controls = 0
    for node, depth in walk(application):
        try:
            role = node.getRole()
            state = node.getState()
            showing = state.contains(pyatspi.STATE_SHOWING)
            name = (node.name or "").strip()
            if role in INTERACTIVE_ROLES and showing:
                visible_controls += 1
                if not name:
                    child_names = descendant_names(node)
                    # GTK list rows expose their readable label through their
                    # contents rather than duplicating it on the wrapper.
                    if role == pyatspi.ROLE_LIST_ITEM and child_names:
                        continue
                    unnamed.append((node.getRoleName(), depth, child_names))
        except Exception as error:  # A disappearing transient must not abort traversal.
            print(f"AT-SPI node changed during audit: {error}", file=sys.stderr)

    print(f"AT-SPI visible interactive controls: {visible_controls}")
    if unnamed:
        for role, depth, child_names in unnamed:
            detail = f"; named children: {child_names}" if child_names else ""
            print(f"Unnamed visible {role} at accessibility depth {depth}{detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
