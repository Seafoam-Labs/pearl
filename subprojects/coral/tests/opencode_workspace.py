#!/usr/bin/env python3
"""Drive the native OpenCode composer and isolated worktree review through GTK accessibility."""
import argparse
import json
import os
import queue
import secrets
import signal
import socket
import base64
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

CORAL = Path(__file__).resolve().parents[1]
PEARL = CORAL.parents[1]
sys.path[:0] = [str(PEARL / "scripts"), str(PEARL / "tests/integration")]


def review_text(first=1, last=1):
    middle = "".join(f"line {i:02d}\n" for i in range(24))
    return f"first = {first}\n" + middle + f"last = {last}\n"


def drive(offline=False, adaptive=False, diagnostics=False, permissions=False, terminal=False, desktop=False, crash_review=False, two_windows=False, showcase=False):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi, GLib

    def descendants(node):
        yield node
        for index in range(node.get_child_count()):
            child = node.get_child_at_index(index)
            if child:
                yield from descendants(child)

    def lookup(name, actionable=True, root=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            for obj in descendants(root if root is not None else Atspi.get_desktop(0)):
                if obj.get_name() != name or not obj.get_state_set().contains(Atspi.StateType.SHOWING):
                    continue
                if not actionable or (obj.get_role() != Atspi.Role.LABEL and obj.get_n_actions() > 0
                                      and obj.get_state_set().contains(Atspi.StateType.SENSITIVE)):
                    return obj
            time.sleep(.05)
        names = [obj.get_name() for obj in descendants(root if root is not None else Atspi.get_desktop(0)) if obj.get_name() and obj.get_state_set().contains(Atspi.StateType.SHOWING)]
        matches = [(o.get_role_name(), o.get_n_actions(), o.get_interfaces(), o.get_state_set().contains(Atspi.StateType.SENSITIVE))
                   for o in descendants(root if root is not None else Atspi.get_desktop(0)) if o.get_name() == name]
        raise AssertionError(f"Missing GTK control {name!r}. Matches {matches}. Visible controls {names!r}")

    def click(name, root=None):
        deadline = time.monotonic() + 5
        while True:
            try:
                control = lookup(name, root=root)
                if control.get_role() == Atspi.Role.RADIO_BUTTON:
                    index = next(i for i in range(control.get_n_actions()) if Atspi.Action.get_localized_name(control, i) == "model.select")
                else:
                    index = 0
                assert control.do_action(index), name
                return
            except GLib.Error as error:
                # GTK can publish its action list one iteration after a model refresh.
                if "No action with index" not in str(error) or time.monotonic() >= deadline:
                    raise
                time.sleep(.05)

    def fixture(action, **fields):
        request = Request(os.environ["WORKSPACE_FIXTURE_URL"] + "/test", data=json.dumps({"action": action, **fields}).encode(),
                          headers={"Authorization": os.environ["WORKSPACE_FIXTURE_AUTH"]})
        with urlopen(request, timeout=5) as reply:
            return json.load(reply)

    def buffer_with(text, contains=False, root=None, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            seen = []
            for node in descendants(root if root is not None else Atspi.get_desktop(0)):
                if node.get_state_set().contains(Atspi.StateType.SHOWING) and "Text" in node.get_interfaces():
                    contents = Atspi.Text.get_text(node, 0, -1)
                    if contents == text or (contains and text in contents):
                        return node
                    if "EditableText" in node.get_interfaces():
                        seen.append((node.get_name(), contents[:90]))
            time.sleep(.05)
        raise AssertionError(f"No visible GTK buffer contains {text!r}. Editable controls contained {seen!r}")

    def capture(name):
        if directory := os.environ.get("WORKSPACE_TEST_CAPTURES"):
            subprocess.run(["grim", "-g", os.environ["WORKSPACE_TEST_GEOMETRY"],
                            str(Path(directory) / (name + ".png"))], check=True)

    def key(name, *modifiers):
        keys = ["wtype", "-s", "60"]
        for modifier in modifiers:
            keys.extend(["-M", modifier])
        keys.extend(["-k", name])
        for modifier in reversed(modifiers):
            keys.extend(["-m", modifier])
        subprocess.run(keys, check=True)

    def open_folder(path):
        key("p", "ctrl", "shift")
        lookup("Command Palette…", actionable=False)
        subprocess.run(["wtype", "-s", "100", "--", "Open Folder"], check=True)
        key("Return")
        lookup("Location", False)
        key("l", "ctrl")
        time.sleep(.15)
        key("a", "ctrl")
        subprocess.run(["wtype", "-s", "100", "--", str(path)], check=True)
        buffer_with(str(path))
        key("Return")
        time.sleep(.3)
        key("Return", "ctrl")

    def pointer_activate(control, target_title=None):
        frame = control
        while frame is not None and frame.get_role() != Atspi.Role.FRAME:
            frame = frame.get_parent()
        assert frame is not None
        rect = control.get_extents(Atspi.CoordType.WINDOW)
        fixture("widget-click", title=frame.get_name(), x=rect.x + rect.width // 2, y=rect.y + rect.height // 2,
                target=target_title)

    if showcase:
        from pearl_session import wait_for
        for name in ("src", "workspace", "session.zig"):
            def file_row():
                return next((node for node in descendants(Atspi.get_desktop(0))
                             if node.get_role() == Atspi.Role.LABEL and (node.get_name() or "").strip().removeprefix("▸ ").strip() == name
                             and node.get_state_set().contains(Atspi.StateType.SHOWING)), None)
            try:
                row = wait_for(file_row, 3)
            except TimeoutError:
                names = [n.get_name() for n in descendants(Atspi.get_desktop(0)) if n.get_role() == Atspi.Role.LABEL]
                raise AssertionError(f"Explorer did not expose {name}. Labels {names}")
            pointer_activate(row)
        tab = wait_for(lambda: next((n for n in descendants(Atspi.get_desktop(0)) if n.get_role() == Atspi.Role.LABEL
                                    and (n.get_name() or "").endswith(" · src/workspace/session.zig")
                                    and n.get_state_set().contains(Atspi.StateType.SHOWING)), None))
        pointer_activate(tab)
        editor = buffer_with("pub const Session = struct", contains=True)
        code = Atspi.Text.get_text(editor, 0, -1)
        start = code.index("    pub fn restore(")
        end = code.index("    }", start) + 5
        assert Atspi.Text.add_selection(editor, start, end)
        key("a", "ctrl", "shift")
        lookup("Restore session cursor", False)
        lookup("Branch · workspace-review", False)
        lookup("Trusted", False)
        click("New terminal")
        time.sleep(.4)
        subprocess.run(["wtype", "-s", "100", "--", "git branch --show-current"], check=True)
        key("Return")
        terminal = buffer_with("git branch --show-current", contains=True)
        wait_for(lambda: "workspace-review" in Atspi.Text.get_text(terminal, 0, -1))
        click("Change session model, currently Claude Sonnet 4")
        assert lookup("Claude Sonnet 4").get_state_set().contains(Atspi.StateType.CHECKED)
        lookup("GPT-4.1")
        lookup("GPT-4.1 mini")
        capture("model-selection")
        return

    if two_windows:
        from pearl_session import wait_for
        other = Path(os.environ["WORKSPACE_TEST_PROJECT"]).parent / "second-project"

        def frame_of(node):
            while node is not None and node.get_role() != Atspi.Role.FRAME:
                node = node.get_parent()
            assert node is not None
            return node

        def assert_thread(frame, own, foreign):
            node = buffer_with(own, contains=True, root=frame, timeout=10)
            text = Atspi.Text.get_text(node, 0, -1)
            assert text.count(own) == 1 and foreign not in text, text

        left = frame_of(lookup("Restore cursor"))
        lookup("Branch · workspace-review", False, left)
        lookup("Change session model, currently Birch", root=left)
        assert lookup("Message OpenCode", False, left).set_text_contents("First project draft")
        key("n", "ctrl", "shift")
        wait_for(lambda: sum(n.get_role() == Atspi.Role.FRAME for n in descendants(Atspi.get_desktop(0))) == 2)
        open_folder(other)
        right = frame_of(lookup("Second project thread"))
        assert left != right
        lookup("Branch · topic/right", False, right)
        detached = fixture("checkout-test-branch", detached=True)
        lookup("Detached HEAD · " + detached, False, right)
        lookup("Branch · workspace-review", False, left)
        fixture("checkout-test-branch", detached=False)
        lookup("Branch · topic/right", False, right)
        for window in (left, right):
            lookup("Show project project", root=window)
            lookup("Show project second-project", root=window)
        def switch_project(frame, name, target):
            card = lookup("Show project " + name, root=frame)
            pointer_activate(card, target.get_name())
        switch_project(right, "project", left)
        switch_project(left, "second-project", right)
        key("f", "ctrl")
        lookup("Next match · F3", False, right)
        key("Escape")
        lookup("Change session model, currently Cedar", root=right)
        assert lookup("Message OpenCode", False, right).set_text_contents("Second project draft")
        fixture("two-streams", step=1)
        assert_thread(left, "Left response 1", "Right response")
        assert_thread(right, "Right response 1", "Left response")
        click("Change session model, currently Cedar", right)
        click("Juniper · remote", right)
        lookup("Change session model, currently Juniper · remote", root=right)
        lookup("Change session model, currently Birch", root=left)
        fixture("two-streams", step=2)
        assert_thread(left, "Left response 2", "Right response")
        assert_thread(right, "Right response 2", "Left response")
        buffer_with("First project draft", root=left)
        buffer_with("Second project draft", root=right)
        # Disconnect while both windows are alive. Their authoritative histories
        # advance during the gap and must be reconciled via one new stream.
        fixture("two-streams", step=3, disconnect=True)
        assert_thread(left, "Left response 3", "Right response")
        assert_thread(right, "Right response 3", "Left response")
        key("w", "ctrl", "shift")
        wait_for(lambda: sum(n.get_role() == Atspi.Role.FRAME for n in descendants(Atspi.get_desktop(0))) == 1)
        wait_for(lambda: not any(n.get_name() == "Show project second-project" for n in descendants(left)))
        fixture("two-streams", step=4)
        assert_thread(left, "Left response 4", "Right response")
        buffer_with("First project draft", root=left)
        return

    if crash_review:
        if os.environ["WORKSPACE_REVIEW_PHASE"] == "before":
            buffer_with(review_text())
            click("New OpenCode session")
            lookup("Worktree test", actionable=False)
            click("Review changes")
            lookup("review.txt   ·   1/2   ·   +2 −2", actionable=False)
            click("Apply hunk")
            return
        click("Restore")
        lookup("Recovery copied safely", actionable=False)
        click("Keep for later")
        buffer_with(review_text(first=2))
        click("Review changes")
        lookup("Previously applied to the editor", actionable=False)
        click("Next change")
        lookup("review.txt   ·   2/2   ·   +2 −2", actionable=False)
        assert not any(n.get_name() == "Previously applied to the editor" and n.get_state_set().contains(Atspi.StateType.SHOWING)
                       for n in descendants(Atspi.get_desktop(0)))
        click("Apply hunk")
        lookup("Applied to unsaved buffer", actionable=False)
        click("Return to editor")
        buffer_with(review_text(first=2, last=2))
        return

    if desktop:
        from pearl_session import wait_for
        lookup("Start OpenCode with opencode service start, then reconnect.", actionable=False)
        buffer_with("staged and edited locally\n")
        key("1", "ctrl")
        key("End", "ctrl")
        subprocess.run(["wtype", "Edited from the desktop launcher"], check=True)
        key("s", "ctrl")
        path = Path(os.environ["WORKSPACE_TEST_PROJECT"]) / "hello.txt"
        wait_for(lambda: path.read_text() == "staged and edited locally\nEdited from the desktop launcher")
        key("q", "ctrl")
        return

    if terminal:
        from pearl_session import wait_for
        project = Path(os.environ["WORKSPACE_TEST_PROJECT"])
        other = project.parent / "second-project"
        other.mkdir()

        def type_text(text):
            subprocess.run(["wtype", "-s", "100", "--", str(text)], check=True)

        def command(text):
            type_text(text)
            key("Return")

        def grid(directory, name):
            output = directory / name
            command("stty size > " + name)
            wait_for(lambda: output.exists() and len(output.read_text().split()) == 2)
            return tuple(map(int, output.read_text().split()))

        def running():
            return any("running" in (node.get_name() or "") and "Terminal " in node.get_name()
                       for node in descendants(Atspi.get_desktop(0)))

        def start_terminal():
            click("New terminal")
            try:
                wait_for(running)
            except TimeoutError:
                state = [n.get_name() for n in descendants(Atspi.get_desktop(0)) if n.get_name()]
                raise AssertionError(f"Shell failed to start. Accessible controls: {state}")

        lookup("Trusted", actionable=False)
        start_terminal()
        command("pwd -P > terminal-cwd")
        wait_for(lambda: (project / "terminal-cwd").exists())
        assert (project / "terminal-cwd").read_text().strip() == str(project)
        before = grid(project, "grid-before")
        command('echo Coral "VTE ready"')
        buffer_with("Coral VTE ready", contains=True)
        capture("workspace-terminal")
        fixture("resize", width=1080)
        after = grid(project, "grid-after")
        assert after[1] < before[1] and min(*before, *after) > 0, (before, after)

        # The folder picker changes the active project with a live shell.
        open_folder(other)
        lookup("second-project", actionable=False)
        lookup("Session model", actionable=False)
        assert not any(n.get_name() in ("Restore cursor", "Birch") and n.get_state_set().contains(Atspi.StateType.SHOWING)
                       for n in descendants(Atspi.get_desktop(0)))
        lookup("Terminal · 0/8 sessions", actionable=False)
        start_terminal()
        command("pwd -P > terminal-cwd")
        wait_for(lambda: (other / "terminal-cwd").exists())
        assert (other / "terminal-cwd").read_text().strip() == str(other)
        command("printf second > new-project-only")
        wait_for(lambda: (other / "new-project-only").exists())
        assert not (project / "new-project-only").exists()
        command("exit 7")
        wait_for(lambda: any("exit 7" in (n.get_name() or "") for n in descendants(Atspi.get_desktop(0))))
        click("Restart terminal")
        wait_for(running)
        command("echo restarted > restart-result")
        wait_for(lambda: (other / "restart-result").exists())
        click("Close terminal")
        lookup("Terminal · 0/8 sessions", actionable=False)
        print(f"Verified VTE shell I/O, resize {before} to {after}, isolated project cwd and exit status.")
        return

    if permissions:
        messages = []
        def announced(event):
            messages.append(str(event.any_data))

        listener = Atspi.EventListener.new(announced)
        assert listener.register("object:announcement")
        def wait_for(predicate, explanation):
            deadline = time.monotonic() + 6
            while time.monotonic() < deadline:
                while GLib.MainContext.default().iteration(False):
                    pass
                if predicate():
                    return
                time.sleep(.05)
            raise AssertionError((explanation, messages))

        def buttons(name):
            return [obj for obj in descendants(Atspi.get_desktop(0)) if obj.get_name() == name
                    and obj.get_role() == Atspi.Role.PUSH_BUTTON
                    and obj.get_state_set().contains(Atspi.StateType.SHOWING)]
        try:
            lookup("Change session model, currently Birch")
            fixture("permissions-add")
            details = buffer_with("readme.txt", contains=True)
            lookup("Message OpenCode", actionable=False)
            capture("pending-permissions")
            text = Atspi.Text.get_text(details, 0, -1)
            assert "Restore cursor" in text and "read" in text and "Working directory" in text and "/project" in text, text
            wait_for(lambda: sum("readme.txt" in s for s in messages) == 1, "Missing permission announcement")
            wait_for(lambda: len(buttons("Allow once")) == 2, "Expected two visible permission cards")
            count = fixture("permission-reads")
            fixture("permissions-repeat")
            wait_for(lambda: fixture("permission-reads") > count, "The refresh was not observed")
            click("Review watcher")
            buffer_with("other-session.txt", contains=True)
            wait_for(lambda: any("other-session.txt" in s for s in messages), "Second session announcement missing")
            click("Restore cursor")
            buffer_with("readme.txt", contains=True)
            click("Allow once")
            wait_for(lambda: fixture("permission-replies") == [["ses_first", "per_read", "once"]], "Allow routed to the wrong request")
            wait_for(lambda: sum(obj.get_state_set().contains(Atspi.StateType.SENSITIVE) for obj in buttons("Deny")) == 1, "The other card must stay actionable")
            deny = next(obj for obj in buttons("Deny") if obj.get_state_set().contains(Atspi.StateType.SENSITIVE))
            assert deny.do_action(0)
            wait_for(lambda: ["ses_first", "per_shell", "reject"] in fixture("permission-replies"), "Deny routed to the wrong request")
            fixture("permissions-release")
            wait_for(lambda: not buttons("Allow once"), "Answered permissions stayed visible")
            click("Review watcher")
            buffer_with("other-session.txt", contains=True)
            fixture("permissions-external")
            wait_for(lambda: not buttons("Allow once"), "Externally answered permission stayed visible")
            for resource in ("readme.txt", "zig build test", "other-session.txt"):
                assert sum(resource in s for s in messages) == 1, (resource, messages)
            print("Verified per-request screen-reader announcements, simultaneous decisions, routing, refresh and external resolution.")
        finally:
            listener.deregister("object:announcement")
        return

    if diagnostics:
        click("Approve and start")
        deadline = time.monotonic() + 5
        while any(obj.get_name() == "Approve and start" and obj.get_state_set().contains(Atspi.StateType.SHOWING)
                  for obj in descendants(Atspi.get_desktop(0))):
            assert time.monotonic() < deadline, "The language-start dialog did not close"
            time.sleep(.05)
        key("p", "ctrl", "shift")
        lookup("Command Palette…", actionable=False)
        subprocess.run(["wtype", "Next diagnostic"], check=True)
        lookup("Next diagnostic", actionable=False)
        lookup("F8", actionable=False)
        key("Escape")
        # Both open Zig documents publish their own UTF-16 range. F8 must
        # switch buffers, select the complete Unicode token, and wrap around.
        def selected_word():
            for obj in descendants(Atspi.get_desktop(0)):
                if not obj.get_state_set().contains(Atspi.StateType.SHOWING) or "Text" not in obj.get_interfaces():
                    continue
                if Atspi.Text.get_n_selections(obj):
                    selection = Atspi.Text.get_selection(obj, 0)
                    word = Atspi.Text.get_text(obj, selection.start_offset, selection.end_offset)
                    if word in ("café😀", "naïve🌱"):
                        return word
            return None

        end = time.monotonic() + 8
        while not (first := selected_word()):
            assert time.monotonic() < end, "F8 did not select a diagnostic"
            key("F8")
            time.sleep(.12)
        key("F8")
        end = time.monotonic() + 5
        while (second := selected_word()) == first or second is None:
            assert time.monotonic() < end, "F8 did not advance to the other document"
            time.sleep(.05)
        key("F8")
        end = time.monotonic() + 3
        while selected_word() != first:
            assert time.monotonic() < end, "F8 did not wrap to the first diagnostic"
            time.sleep(.05)
        print("Verified the command palette, F8 cross-document diagnostic navigation, Unicode selection and wraparound.")
        return

    if adaptive:
        def visible(name):
            return any(obj.get_name() == name and obj.get_state_set().contains(Atspi.StateType.SHOWING)
                       for obj in descendants(Atspi.get_desktop(0)))

        def bounds(name):
            obj = lookup(name, actionable=False)
            return Atspi.Component.get_extents(obj, Atspi.CoordType.WINDOW)

        def escape():
            subprocess.run(["wtype", "-s", "60", "-k", "Escape"], check=True)

        if os.environ.get("WORKSPACE_TEST_LARGE_TEXT"):
            # The same 1440px window now needs a drawer for its agent as well.
            lookup("Toggle Explorer drawer")
            lookup("Toggle OpenCode drawer")
            click("Toggle OpenCode drawer")
            click("Change session model, currently Birch")
            lookup("Cedar")
            lookup("Task output", actionable=False)
            capture("large-text-model")
            print("Verified large-text drawer layout retains both the model picker and dock at desktop width.")
            return
        lookup("Change session model, currently Birch")
        composer = lookup("Message OpenCode", actionable=False)
        assert composer.set_text_contents("Drawer draft")
        fixture("resize", width=920)
        lookup("Toggle Explorer drawer")
        assert not visible("Toggle OpenCode drawer")
        lookup("Change session model, currently Birch")
        assert not visible("Restore cursor") or not visible("Review watcher")
        click("Toggle Explorer drawer")
        lookup("Review watcher")
        escape()
        lookup("Toggle Explorer drawer")
        fixture("resize", width=680)
        lookup("Toggle OpenCode drawer")
        assert not visible("Message OpenCode")
        lookup("Task output", actionable=False)
        click("Toggle OpenCode drawer")
        lookup("Change session model, currently Birch")
        assert bounds("Message OpenCode").y < bounds("Task output").y
        assert Atspi.Text.get_text(lookup("Message OpenCode", False), 0, -1) == "Drawer draft"
        click("Change session model, currently Birch")
        lookup("Cedar")
        if directory := os.environ.get("WORKSPACE_TEST_CAPTURES"):
            frame = fixture("geometry")
            geometry = "{x},{y} {width}x{height}".format(**frame)
            subprocess.run(["grim", "-g", geometry, str(Path(directory) / "narrow-model.png")], check=True)
        click("Cedar")
        until = time.monotonic() + 3
        while fixture("current-model") != "cedar":
            assert time.monotonic() < until, "The service did not receive the model change"
            time.sleep(.05)
        lookup("Change session model, currently Cedar")
        escape()
        fixture("resize", width=1440)
        lookup("Review watcher")
        lookup("Change session model, currently Cedar")
        assert not visible("Toggle Explorer drawer") and not visible("Toggle OpenCode drawer")
        assert Atspi.Text.get_text(lookup("Message OpenCode", False), 0, -1) == "Drawer draft"
        # A temporarily opened drawer must not overwrite an explicitly hidden pin.
        subprocess.run(["wtype", "-M", "ctrl", "-k", "b", "-m", "ctrl"], check=True)
        deadline = time.monotonic() + 3
        while visible("Review watcher"):
            assert time.monotonic() < deadline, "Explorer pin did not close"
            time.sleep(.05)
        lookup("Change session model, currently Cedar")
        fixture("resize", width=680)
        click("Toggle Explorer drawer")
        lookup("Review watcher")
        fixture("resize", width=1440)
        lookup("Change session model, currently Cedar")
        assert not visible("Review watcher")
        print("Verified adaptive drawers, session model and draft, bottom dock access and manually hidden pin restoration.")
        return

    if offline:
        click("Restore")
        lookup("Recovery copied safely", actionable=False)
        click("Keep for later")
        lookup("Start OpenCode with opencode service start, then reconnect.", actionable=False)
        composer = lookup("Message OpenCode", actionable=False)
        assert Atspi.Text.get_text(composer, 0, -1) == "Draft saved before restart"
        assert composer.set_text_contents("Offline edit")
        click("Review changes")
        lookup("Previously applied to the editor", actionable=False)
        key("F7", "ctrl")
        lookup("renamed-image.bin   ·   1/1   ·   +0 −0", actionable=False)
        key("F7", "ctrl", "shift")
        lookup("Previously applied to the editor", actionable=False)
        key("F7", "ctrl")
        lookup("renamed-image.bin   ·   1/1   ·   +0 −0", actionable=False)
        click("Mark file reviewed")
        lookup("File reviewed", actionable=False)
        click("Next change")
        lookup("test-binary.bin   ·   1/1   ·   +0 −0", actionable=False)
        click("Mark file reviewed")
        lookup("File reviewed", actionable=False)
        return

    source = buffer_with("staged and edited locally\n")
    assert Atspi.Text.add_selection(source, 0, 6)
    click("Earlier messages")
    buffer_with("An older message from this thread.", contains=True)
    key("a", "ctrl", "shift")
    lookup("hello.txt · L1–1")
    composer = lookup("Message OpenCode", actionable=False)
    assert composer.set_text_contents("Keep this draft across model switches")
    click("Change session model, currently Birch")
    lookup("Retired")
    key("Escape")
    key("space")
    selected = lookup("Birch")
    assert selected.get_state_set().contains(Atspi.StateType.CHECKED)
    assert not lookup("Cedar").get_state_set().contains(Atspi.StateType.CHECKED)
    lookup("Retired")
    lookup("Juniper · local")
    lookup("Juniper · remote")
    capture("model-selection")
    click("Retired")
    lookup("This model has been retired", actionable=False)
    assert Atspi.Text.get_text(composer, 0, -1) == "Keep this draft across model switches"
    click("Change session model, currently Birch")
    lookup("Cedar")
    key("Down")
    if any(obj.get_role() == Atspi.Role.RADIO_BUTTON and obj.get_name() == "Cedar" and
           obj.get_state_set().contains(Atspi.StateType.FOCUSED) for obj in descendants(Atspi.get_desktop(0))):
        key("space")
    click("Change session model, currently Cedar")
    click("Juniper · remote")
    lookup("Change session model, currently Juniper · remote")
    click("Review watcher")
    lookup("Change session model, currently Birch")
    click("Restore cursor")
    click("Change session model, currently Juniper · remote")
    assert lookup("Juniper · remote").get_state_set().contains(Atspi.StateType.CHECKED)
    assert not lookup("Juniper · local").get_state_set().contains(Atspi.StateType.CHECKED)
    click("Cedar")
    lookup("Change session model, currently Cedar")
    fixture("external-change")
    lookup("Change session model, currently Birch")
    fixture("missed-event")
    lookup("Change session model, currently Cedar")
    assert Atspi.Text.get_text(composer, 0, -1) == "Keep this draft across model switches"
    click("hello.txt · L1–1")
    buffer_with("staged")
    click("Remove selection")
    click("Send to this session")
    click("Delivery unknown · Retry this prompt")
    lookup("Keep this draft across model switches", actionable=False)
    click("Cancel queued prompt")
    click("New OpenCode session")
    lookup("Worktree test", actionable=False)
    lookup("Review changes")
    key("1", "ctrl")
    key("F6")
    subprocess.run(["wtype", "-s", "100", "FocusProbe"], check=True)
    buffer_with("FocusProbe")
    assert Atspi.Text.get_text(composer, 0, -1) == "FocusProbe", Atspi.Text.get_text(composer, 0, -1)
    key("r", "ctrl", "shift")
    lookup("Apply hunk")
    key("Escape")
    subprocess.run(["wtype", "-s", "100", "Restored"], check=True)
    buffer_with("FocusProbeRestored")
    key("r", "ctrl", "shift")
    click("Side by side")
    lookup("Shared base", actionable=False)
    lookup("Agent worktree", actionable=False)
    capture("split-review")
    click("Apply hunk")
    lookup("Applied to unsaved buffer", actionable=False)
    click("Return to editor")

    editor = buffer_with("agent edit\n")
    assert editor.set_text_contents("my unsaved edit\n")
    click("Review changes")
    lookup("Previously applied to the editor", actionable=False)
    click("Apply hunk")
    lookup("Resolve overlapping edits", actionable=False)
    capture("conflict")
    click("Keep my edit")
    click("Return to editor")
    buffer_with("my unsaved edit\n")
    click("Review changes")
    lookup("Previously skipped", actionable=False)
    click("Apply hunk")
    click("Use agent change")
    lookup("Applied to unsaved buffer", actionable=False)
    click("Return to editor")
    editor = buffer_with("agent edit\n")
    subprocess.run(["wtype", "-s", "100", "-M", "ctrl", "-k", "z", "-m", "ctrl"], check=True)
    buffer_with("my unsaved edit\n")
    assert composer.set_text_contents("Draft saved before restart")


class Service(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, project, handler=None):
        super().__init__(("127.0.0.1", 0), handler or API)
        self.project = project
        self.password = secrets.token_urlsafe(20)
        self.authorization = "Basic " + base64.b64encode(("opencode:" + self.password).encode()).decode()
        self.sessions = {}
        self.calls = []
        self.closed = threading.Event()
        self.events = queue.Queue()
        self.models = [dict(id=name.lower(), name=name, providerID="local", enabled=True)
                       for name in ("Birch", "Cedar", "Retired", "Juniper")]
        self.models.append(dict(id="juniper", name="Juniper", providerID="remote", enabled=True))
        self.history = None
        self.stream_step = 0
        self.inbox = {}
        self.attempts = []
        self.cancelled = []
        self.permissions = {"ses_first": {}, "ses_second": {}}
        self.permission_reads = 0
        self.permission_replies = []
        self.release_permission = threading.Event()
        self.add("ses_first", "Restore cursor", project, "birch")
        self.add("ses_second", "Review watcher", project, "cedar")
        self.sessions["ses_second"].pop("model")

    def add(self, sid, title, location, model, metadata=None):
        self.sessions[sid] = dict(id=sid, title=title, projectID="fixture",
                                  location={"directory": str(location)}, model={"id": model, "providerID": "local"},
                                  metadata=metadata or {})


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj, status=200):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.route(False)

    def do_POST(self):
        self.route(True)

    def do_DELETE(self):
        self.route(False)

    def route(self, post):
        service = self.server
        if self.headers.get("Authorization") != service.authorization:
            self.send_error(401)
            return
        path = urlsplit(self.path).path
        service.calls.append(path)
        if path == "/api/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"type":"server.connected"}\n\n')
            self.wfile.flush()
            while not service.closed.is_set():
                try:
                    event = service.events.get(timeout=.25)
                except queue.Empty:
                    continue
                if event is None:
                    break
                self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
                self.wfile.flush()
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"]))) if post else None
        if path == "/test" and post:
            if body["action"] == "checkout-test-branch":
                return self.reply(service.checkout_test_branch(body["detached"]))
            if body["action"] == "widget-click":
                service.widget_click(body)
                return self.reply({})
            if body["action"] == "two-streams":
                service.stream_step = body["step"]
                if body.get("disconnect"):
                    service.events.put(None)
                else:
                    for sid in ("ses_other", "ses_first"):
                        service.events.put({"type": "session.text.updated", "data": {"sessionID": sid}})
                return self.reply({})
            if body["action"].startswith("permission"):
                action = body["action"]
                if action == "permission-reads":
                    return self.reply(service.permission_reads)
                if action == "permission-replies":
                    return self.reply(service.permission_replies)
                sid = "ses_first"
                if action == "permissions-add":
                    for sid, rid, kind, resource in [("ses_second", "per_other", "read", "other-session.txt"),
                                                     ("ses_first", "per_read", "read", "readme.txt"),
                                                     ("ses_first", "per_shell", "bash", "zig build test")]:
                        service.permissions[sid][rid] = {"sessionID": sid, "id": rid, "action": kind, "resources": [resource]}
                elif action == "permissions-release":
                    service.release_permission.set()
                elif action == "permissions-external":
                    sid = "ses_second"
                    service.permissions[sid].clear()
                service.events.put({"type": "permission.updated", "data": {"sessionID": sid}})
                return self.reply({})
            if body["action"] == "current-model":
                return self.reply(service.sessions["ses_first"]["model"]["id"])
            if body["action"] in ("resize", "geometry"):
                return self.reply(service.window_geometry(body.get("width")))
            model = "birch" if body["action"] == "external-change" else "cedar"
            service.sessions["ses_first"]["model"] = {"id": model, "providerID": "local"}
            service.events.put({"type": "session.model.selected", "data": {"sessionID": "ses_first"}}
                               if model == "birch" else None)
            return self.reply({})
        if path == "/api/model/default":
            return self.reply({"data": {"id": "birch", "providerID": "local"}})
        if path == "/api/location":
            return self.reply({"project": {"id": "fixture"}, "directory": str(service.project)})
        if path == "/api/model":
            return self.reply({"data": service.models})
        if path == "/api/session":
            if post:
                tree = Path(body["location"]["directory"])
                assert tree.resolve() != service.project.resolve()
                assert (tree / "hello.txt").read_text() == "staged and edited locally\n"
                assert (tree / "untracked.txt").read_text() == "untracked baseline\n"
                if (tree / "review.txt").exists():
                    (tree / "review.txt").write_text(review_text(first=2, last=2))
                else:
                    (tree / "hello.txt").write_text("agent edit\n")
                    (tree / "old-image.bin").rename(tree / "renamed-image.bin")
                    (tree / "test-binary.bin").write_bytes(b"\x00\xf0agent")
                service.add("ses_created", "Worktree test", tree, "birch", body["metadata"])
                return self.reply({"data": service.sessions["ses_created"]})
            return self.reply({"data": list(service.sessions.values()), "cursor": {}})
        fields = path.strip("/").split("/")
        if len(fields) >= 3 and fields[1] == "session" and fields[2] in service.sessions:
            session = service.sessions[fields[2]]
            if len(fields) == 3:
                return self.reply({"data": session})
            if fields[3] == "model" and post:
                if body["model"]["id"] == "retired":
                    return self.reply({"_tag": "InvalidRequestError", "message": "This model has been retired"}, 400)
                session["model"] = body["model"]
                self.send_response(204)
                self.end_headers()
                return
            if fields[3] == "prompt" and post:
                item = dict(id=body["id"], sessionID=fields[2], type="user", payload={"text": body["text"]})
                service.attempts.append(item)
                if len(service.attempts) == 1:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                service.inbox[item["id"]] = item
                return self.reply({"data": item})
            if fields[3] == "inbox":
                if self.command == "DELETE":
                    service.cancelled.append(service.inbox.pop(fields[4]))
                    return self.reply({})
                return self.reply({"data": list(service.inbox.values())})
            if fields[3] == "message":
                if service.history:
                    return self.reply({"data": service.history, "cursor": {}})
                if service.stream_step:
                    side = "Right" if fields[2] == "ses_other" else "Left"
                    return self.reply({"cursor": {}, "data": [{"type": "assistant", "id": "streamed",
                        "content": [{"type": "text", "text": f"{side} response {service.stream_step}"}]}]})
                if parse_qs(urlsplit(self.path).query).get("cursor") == ["older"]:
                    return self.reply({"data": [{"type":"user", "id":"msg_older", "text":"An older message from this thread."}], "cursor":{}})
                return self.reply({"cursor":{"next":"older"}, "data": [
                    {"type": "assistant", "id": "msg_answer", "content": [{"type": "text", "text": "The saved cursor is restored before the thread opens. I can add a bounds check in the isolated worktree."}]},
                    {"type": "user", "id": "msg_request", "text": "Keep my reading position when I reopen this session."}]})
            if fields[3] == "permission":
                sid = fields[2]
                permissions = service.permissions.get(sid, {})
                if post:
                    rid = fields[4]
                    assert fields[5] == "reply" and rid in permissions
                    service.permission_replies.append([sid, rid, body["decision"]])
                    if rid == "per_read":
                        service.release_permission.wait(8)
                    del permissions[rid]
                    return self.reply({})
                service.permission_reads += 1
                return self.reply({"data": list(permissions.values())})
        self.send_error(404)


def main(args):
    from pearl_session import PrivateSession, fixture_prefix
    from test_surfaces import IPC
    with PrivateSession(args.output / "session", tool_prefix=args.aqueous_prefix or fixture_prefix()) as session:
        project = session.base / ("Pearl" if args.showcase else "project")
        project.mkdir()
        def git(*argv):
            return subprocess.check_output(["git", "-C", str(project), *argv], env=session.env)
        git("init", "-q")
        if args.showcase:
            source_dir = project / "src" / "workspace"
            source_dir.mkdir(parents=True)
            file = source_dir / "session.zig"
            file.write_text('''const Store = @import("store.zig").Store;

pub const Session = struct {
    id: []const u8,
    store: *Store,

    /// Restore the last visible message.
    pub fn restore(self: *Session) !usize {
        const saved = try self.store.load(self.id);
        return saved.cursor;
    }

    pub fn title(self: *Session) []const u8 {
        return self.store.title(self.id);
    }
};
''')
            (source_dir / "store.zig").write_text('''pub const Store = struct {
    cursor: usize,
    name: []const u8,

    pub fn load(self: *Store, _: []const u8) !*Store {
        return self;
    }

    pub fn title(self: *Store, _: []const u8) []const u8 {
        return self.name;
    }
};
''')
            git("add", ".")
            git("-c", "user.email=test@localhost", "-c", "user.name=Fixture", "commit", "-qm", "Session restoration")
            git("branch", "-m", "workspace-review")
        else:
            file = project / "hello.txt"
            file.write_text("original\n")
            (project / "old-image.bin").write_bytes(b"\x00rename")
            (project / "test-binary.bin").write_bytes(b"\x00base")
            if args.crash_review:
                (project / "review.txt").write_text(review_text())
            git("add", ".")
            git("-c", "user.email=test@localhost", "-c", "user.name=Fixture", "commit", "-qm", "Base")
            file.write_text("staged\n")
            git("add", "hello.txt")
            file.write_text("staged and edited locally\n")
            (project / "untracked.txt").write_text("untracked baseline\n")
        service = Service(project)
        if args.showcase:
            service.sessions.clear()
            for sid, title, outcome in [("ses_first", "Restore session cursor", ""), ("ses_watch", "Review file watcher", "failed"),
                                        ("ses_tidy", "Tidy status labels", "succeeded")]:
                service.add(sid, title, project, "claude-sonnet-4")
                service.sessions[sid]["model"]["providerID"] = "anthropic"
                service.sessions[sid]["outcome"] = outcome
            service.sessions["ses_first"]["time"] = {"busy": 2, "idle": 1}
            service.models = [dict(id=id, name=name, providerID=provider, enabled=True) for id, name, provider in [
                ("claude-sonnet-4", "Claude Sonnet 4", "anthropic"), ("gpt-4.1", "GPT-4.1", "openai"), ("gpt-4.1-mini", "GPT-4.1 mini", "openai")]]
            service.history = [
                {"id": "msg_answer", "type": "assistant", "content": [{"type": "text", "text":
                    "I found the restore path. A saved cursor can point past the final message after history is trimmed."}]},
                {"id": "msg_request", "type": "user", "text": "Keep the reading position when I reopen a session."},
            ]
        if args.two_windows:
            other = project.parent / "second-project"
            git("branch", "-m", "workspace-review")
            git("worktree", "add", "-q", "-b", "topic/right", str(other))
            def checkout_test_branch(detached):
                subprocess.run(["git", "-C", str(other), "switch", *(["--detach", "HEAD"] if detached else ["topic/right"])],
                               check=True, capture_output=True, env=session.env)
                return subprocess.check_output(["git", "-C", str(other), "rev-parse", "--short", "HEAD"], env=session.env, text=True).strip()
            service.checkout_test_branch = checkout_test_branch
            service.add("ses_other", "Second project thread", other, "cedar")
            session.env["WORKSPACE_TEST_PROJECT"] = str(project)
        threading.Thread(target=service.serve_forever, daemon=True).start()
        try:
            state = Path(session.env["XDG_STATE_HOME"]) / "opencode"
            state.mkdir()
            (state / "service.json").write_text(json.dumps({"url": f"http://127.0.0.1:{service.server_port}",
                                                            "password": service.password}))
            session.env["WORKSPACE_FIXTURE_URL"] = f"http://127.0.0.1:{service.server_port}"
            session.env["WORKSPACE_FIXTURE_AUTH"] = service.authorization
            if args.large_text:
                gtk_settings = Path(session.env["XDG_CONFIG_HOME"]) / "gtk-4.0/settings.ini"
                gtk_settings.parent.mkdir(exist_ok=True)
                gtk_settings.write_text("[Settings]\ngtk-xft-dpi=196608\n")
                session.env["WORKSPACE_TEST_LARGE_TEXT"] = "1"
            if args.light:
                prefs = Path(session.env["XDG_CONFIG_HOME"]) / "coral-workspace/preferences.ini"
                prefs.parent.mkdir(exist_ok=True)
                prefs.write_text("[Coral]\ntheme=1\n")
            session.env.pop("GTK_A11Y", None)
            session.child("access-bus", ["/usr/lib/at-spi-bus-launcher", "--launch-immediately"])
            session.run(["gdbus", "wait", "--session", "--timeout=5", "org.a11y.Bus"])
            registry = session.child("access-registry", ["/usr/lib/at-spi2-registryd"])
            registry.expect("well-known name")
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(["wlr-randr", "--output", display["name"], "--custom-mode", "1800x1100@60Hz"])
            rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
            rules.write_text(f'[[window]]\napp_id="org.aqueous.Coral.Workspace"\nfloating=true\nwidth={args.width}\nheight={args.height}\n')
            ipc.call("command", action="session.reload", fields={})
            def window_geometry(width=None):
                def rect():
                    return next((w["geometry"] for w in ipc.state() if w["kind"] == "window"
                                 and w.get("app_id") == "org.aqueous.Coral.Workspace"), {})
                if width:
                    rules.write_text(f'[[window]]\napp_id="org.aqueous.Coral.Workspace"\nfloating=true\nwidth={width}\nheight=800\n')
                    ipc.call("command",action="session.reload",fields={})
                    wait_for(lambda: abs(rect().get("width",0)-width) < 8)
                return rect()
            service.window_geometry = window_geometry
            if args.two_windows or args.showcase:
                from test_surfaces import click as pointer_click
                def widget_click(point):
                    windows = [w for w in ipc.state() if w["kind"] == "window"]
                    window = next(w for w in windows if w.get("title") == point["title"])
                    rect = window["geometry"]
                    pointer_click(session, rect["x"] + point["x"], rect["y"] + point["y"], ipc.outputs())
                    if target := point.get("target"):
                        wait_for(lambda: any(w.get("title") == target and w.get("focused") for w in ipc.state()))
                service.widget_click = widget_click
            documents = [project / "review.txt"] if args.crash_review else [file]
            if args.showcase:
                # This capture exercises the OpenCode picker. An independent
                # language-server approval dialog would cover the code selection.
                config = Path(session.env["HOME"]) / ".config/coral/languages.json"
                config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                config.write_text(json.dumps({"version": 1, "servers": []}))
                config.chmod(0o600)
                session.env.update(SHELL="/bin/sh", PS1="❯ ")
                documents = [file.with_name("store.zig"), file]
            if args.diagnostics:
                # Earlier Coral versions could create this path with the default
                # mode. Workspace owns its approval records in its own directory.
                legacy = Path(session.env["XDG_STATE_HOME"]) / "coral"
                legacy.mkdir(mode=0o755)
                config = Path(session.env["HOME"]) / ".config/coral/languages.json"
                config.parent.parent.mkdir(mode=0o700, exist_ok=True)
                config.parent.mkdir(mode=0o700, exist_ok=True)
                config.write_text(json.dumps({"version": 1, "servers": [{
                    "language": "zig", "cwd": "root", "env": {"PATH": "/usr/bin:/bin"},
                    "argv": [sys.executable, "-B", str(CORAL / "tests/fixtures/fake_lsp.py"), "--encoding", "utf-16"],
                }]}))
                config.chmod(0o600)
                documents = [project / "first.zig", project / "second.zig"]
                for doc, data in zip(documents, ["   café😀 first\n", "  naïve🌱 second\n"]):
                    doc.write_text(data)
            if args.terminal:
                session.env.update(SHELL="/bin/sh", WORKSPACE_TEST_PROJECT=str(project))
            if args.desktop:
                from pearl_session import wait_for
                prefix = args.binary.resolve().parents[1]
                desktop_id = "org.aqueous.Coral.Workspace"
                entry = prefix / "share/applications" / (desktop_id + ".desktop")
                session.run(["desktop-file-validate", entry])
                (state / "service.json").rename(state / "offline.json")
                session.env.update(
                    PATH=str(prefix / "bin") + ":" + session.env["PATH"],
                    XDG_DATA_DIRS=str(prefix / "share") + ":" + session.env.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share"),
                    WORKSPACE_TEST_PROJECT=str(project), G_DEBUG="fatal-criticals",
                )
                launcher = session.child("desktop-launch", ["gtk-launch", desktop_id, project.as_uri(), file.as_uri()])
                assert launcher.wait(timeout=10) == 0
                wait_for(window_geometry, 10)
                subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--desktop"],
                               env=session.env, check=True, timeout=30)
                wait_for(lambda: not window_geometry(), 5)
                print("Verified the installed desktop entry opened the project and file, saved an offline edit and quit.")
                return
            application = session.child("workspace", [args.binary.resolve(), *(["--log-level", "debug", "--log-scopes", "services"] if args.terminal else []), project, *documents], G_DEBUG="fatal-criticals")
            from pearl_session import wait_for
            wait_for(lambda: "/api/model" in service.calls)
            if args.two_windows:
                subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--two-windows"],
                               env=session.env, check=True, timeout=65)
                assert service.calls.count("/api/event") == 2, service.calls.count("/api/event")
                assert service.sessions["ses_first"]["model"] == {"providerID": "local", "id": "birch"}
                assert service.sessions["ses_other"]["model"] == {"providerID": "remote", "id": "juniper"}
                print("Verified independent drafts, models and streamed replies in two GTK windows, a shared reconnect, and closing one window.")
                return
            if args.crash_review:
                driver = [sys.executable, str(Path(__file__).resolve()), "--drive", "--crash-review"]
                session.env["WORKSPACE_REVIEW_PHASE"] = "before"
                subprocess.run(driver, env=session.env, check=True, timeout=30)
                receipts = Path(session.env["XDG_STATE_HOME"]) / "coral-workspace/sessions"
                def applied_receipts():
                    return {path for path in receipts.glob("*.json")
                            if json.loads(path.read_text()).get("decision") == "applied"}
                wait_for(lambda: len(applied_receipts()) == 1, 5)
                first_receipts = applied_receipts()
                application.signal(signal.SIGKILL)
                assert application.wait(timeout=5) == -signal.SIGKILL
                wait_for(lambda: not window_geometry(), 5)
                assert (project / "review.txt").read_text() == review_text()
                session.env["WORKSPACE_REVIEW_PHASE"] = "after"
                session.child("review-recovery", [args.binary.resolve(), project], G_DEBUG="fatal-criticals")
                subprocess.run(driver, env=session.env, check=True, timeout=35)
                assert (project / "review.txt").read_text() == review_text()
                assert git("show", ":review.txt").decode() == review_text()
                assert len(applied_receipts()) == 2 and first_receipts < applied_receipts()
                print("Verified both unsaved hunk results and separate review decisions across SIGKILL.")
                return
            if args.capture_dir:
                args.capture_dir.mkdir(parents=True, exist_ok=True)
                geometry = next(node["geometry"] for node in ipc.state() if node["kind"] == "window" and node.get("app_id") == "org.aqueous.Coral.Workspace")
                session.env["WORKSPACE_TEST_CAPTURES"] = str(args.capture_dir.resolve())
                session.env["WORKSPACE_TEST_GEOMETRY"] = "{x},{y} {width}x{height}".format(**geometry)
            if args.showcase:
                subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--showcase"],
                               env=session.env, check=True, timeout=35)
                return
            if args.adaptive or args.diagnostics or args.permissions or args.terminal:
                scenario = "--adaptive" if args.adaptive else ("--diagnostics" if args.diagnostics else ("--terminal" if args.terminal else "--permissions"))
                subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", scenario],
                               env=session.env, check=True, timeout=60)
                if args.diagnostics:
                    assert not (legacy / "agents").exists()
                    assert (legacy.parent / "coral-workspace/language").is_dir()
                return
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive"], env=session.env,
                           check=True, timeout=65)
            assert service.sessions["ses_first"]["model"]["id"] == "cedar"
            assert "model" not in service.sessions["ses_second"]
            assert len(service.attempts) == 2 and service.attempts[0] == service.attempts[1]
            assert service.cancelled == service.attempts[:1]
            assert not service.inbox
            def draft_saved(text):
                files = (Path(session.env["XDG_STATE_HOME"]) / "coral-workspace/sessions").glob("*.json")
                return any(json.loads(path.read_text()).get("text") == text for path in files)
            wait_for(lambda: draft_saved("Draft saved before restart"))
            application.stop()
            (state / "service.json").rename(state / "offline.json")
            session.child("offline-workspace", [args.binary.resolve(), project, file], G_DEBUG="fatal-criticals")
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--offline"],
                           env=session.env, check=True, timeout=20)
            wait_for(lambda: draft_saved("Offline edit"))
            assert file.read_text() == "staged and edited locally\n"
            assert git("show", ":hello.txt") == b"staged\n"
            print("Passed native selection, model sync, history paging, idempotent retry, queue cancellation, split review, conflict, undo, and offline draft recovery.")
        finally:
            service.closed.set()
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drive", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--adaptive", action="store_true")
    parser.add_argument("--diagnostics", action="store_true")
    parser.add_argument("--permissions", action="store_true")
    parser.add_argument("--terminal", action="store_true")
    parser.add_argument("--showcase", action="store_true", help="Capture the design scene with real GTK widgets and a fixture catalog")
    parser.add_argument("--two-windows", action="store_true")
    parser.add_argument("--crash-review", action="store_true")
    parser.add_argument("--desktop", action="store_true", help="Use the installed binary and desktop entry from the same prefix")
    parser.add_argument("--binary", type=Path, default=CORAL / "zig-out/bin/coral-workspace")
    parser.add_argument("--output", type=Path, default=CORAL / ".zig-cache/workspace-integration")
    parser.add_argument("--aqueous-prefix", type=Path)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--light", action="store_true")
    parser.add_argument("--large-text", action="store_true")
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    opts = parser.parse_args()
    if opts.drive:
        drive(opts.offline, opts.adaptive, opts.diagnostics, opts.permissions, opts.terminal, opts.desktop, opts.crash_review, opts.two_windows, opts.showcase)
    else:
        main(opts)
