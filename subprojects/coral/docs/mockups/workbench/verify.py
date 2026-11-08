#!/usr/bin/env python3
"""Offline Chromium UI regression suite; all generated artifacts stay beside this file.

Run from pearl with the documented PLAYWRIGHT_BROWSERS_PATH and validation venv.
Use --only SUBSTRING for focused debugging; the report identifies partial runs.
Actions use real UI events. JavaScript evaluation is read-only except Playwright's
virtual clock, which makes cancellation and in-flight editing tests deterministic.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import sys
import time
import traceback

from playwright.sync_api import expect, sync_playwright

HERE = Path(__file__).resolve().parent
URL = (HERE / "index.html").as_uri()
MAIN = "coral/src/main.zig"
PALETTE = "shared-ui/src/palette.zig"
TESTS = []
SCREENSHOTS = []
LAYOUTS = []
expect.set_options(timeout=5000)


def test(name):
    def register(function):
        TESTS.append((name, function))
        return function
    return register


def click(page, name):
    page.get_by_role("button", name=name, exact=True).click()


def snapshot(page, file_id=MAIN):
    return page.evaluate("""id => {
        const f = workspace.files.find(file => file.id === id);
        return {head: f.head, index: f.index, text: f.text, saved: f.saved, revision: f.revision};
    }""", file_id)


def task_status(page, status):
    page.wait_for_function("status => activeThread().task?.status === status", arg=status)


def selected_text(page):
    return page.locator("#editor").evaluate("e => e.value.slice(e.selectionStart, e.selectionEnd)")


def append_text(page, text):
    editor = page.locator("#editor")
    editor.focus()
    editor.press("Control+End")
    editor.press_sequentially(text, delay=5)
    expect(editor).to_be_focused()
    assert editor.input_value().endswith(text)


def pick(page, query):
    field = page.locator("#picker-input")
    expect(field).to_be_visible()
    field.fill(query)
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(1)
    field.press("Enter")


def quick_open(page, file_id):
    page.keyboard.press("Control+p")
    pick(page, file_id)
    expect(page.locator("#editor")).to_have_attribute("aria-label", f"Edit {file_id}")


def switch_workspace(page, name):
    page.locator("#workspace-button").click()
    pick(page, name)
    expect(page.locator("#workspace-name")).to_have_text(name)


def submit_agent(page, prompt="Fix the diagnostic carefully"):
    if not page.locator("#agent-dock").is_visible():
        page.locator("#agent-toggle").click()
    page.locator("#agent-prompt").fill(prompt)
    click(page, "Send agent prompt")
    expect(page.get_by_role("button", name="Allow read", exact=True)).to_be_visible()
    task_status(page, "approval")


def propose(page, prompt="Fix the diagnostic carefully"):
    submit_agent(page, prompt)
    click(page, "Allow read")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_be_visible()
    task_status(page, "proposed")


def freeze_clock(page):
    now = datetime(2030, 1, 1, tzinfo=timezone.utc)
    page.clock.install(time=now)
    page.clock.pause_at(now)


def screenshot(page, name):
    page.screenshot(path=str(HERE / name), full_page=True, animations="disabled")
    SCREENSHOTS.append(name)


def bounds(page, label):
    """Check the viewport and visible panes/dialogs, not intentionally scrollable code."""
    result = page.evaluate("""() => {
        const selectors = ['.titlebar', '.activity-rail', '#sidebar', '#main-area',
            '#agent-dock', '.statusbar', '#editor', '#bottom-panel', 'dialog[open]'];
        const boxes = selectors.flatMap(selector => Array.from(document.querySelectorAll(selector))
            .filter(e => e.checkVisibility()).map(e => {
                const r = e.getBoundingClientRect();
                return {selector, x:r.x, y:r.y, right:r.right, bottom:r.bottom,
                    width:r.width, height:r.height};
            }));
        return {width: innerWidth, height: innerHeight,
            documentWidth: document.documentElement.scrollWidth,
            documentHeight: document.documentElement.scrollHeight, boxes};
    }""")
    LAYOUTS.append({"label": label, **result})
    assert result["documentWidth"] <= result["width"] + 1, result
    assert result["documentHeight"] <= result["height"] + 1, result
    for box in result["boxes"]:
        assert box["x"] >= -1 and box["y"] >= -1, box
        assert box["right"] <= result["width"] + 1, box
        assert box["bottom"] <= result["height"] + 1, box
        assert box["width"] > 0 and box["height"] > 0, box


@test("initial offline render and local assets")
def initial(page):
    expect(page).to_have_title("Coral — Workbench prototype")
    expect(page.locator("#file-tree details")).to_have_count(2)
    expect(page.locator("#editor-tabs .editor-tab")).to_have_count(3)
    expect(page.locator("#problem-count")).to_have_text("1")
    expect(page.locator("#agent-dock")).to_be_visible()
    expect(page.locator(".simulation-badge")).to_have_text("SIMULATED")
    assert page.locator("#editor").input_value() == snapshot(page)["text"]
    # file:// CSSOM rule access is restricted; verify applied styles instead.
    assert page.locator("#workbench").evaluate("e => getComputedStyle(e).display") == "grid"
    assert page.locator("#main-area").evaluate("e => getComputedStyle(e).backgroundColor") == "rgb(27, 29, 33)"
    assert page.locator("#editor").evaluate("e => getComputedStyle(e).fontFamily.includes('monospace')")
    bounds(page, "initial desktop")


@test("typed edits survive tab switching, closing and preview save")
def tabs(page):
    before = snapshot(page)
    append_text(page, "// typed buffer marker")
    edited = page.locator("#editor").input_value()
    expect(page.locator("#buffer-status")).to_contain_text("Unsaved")
    click(page, "Open tab coral/src/workspace.zig")
    click(page, f"Open tab {MAIN}")
    expect(page.locator("#editor")).to_have_value(edited)
    click(page, "Close src/main.zig (unsaved buffer retained)")
    expect(page.get_by_role("button", name=f"Open tab {MAIN}", exact=True)).to_have_count(0)
    quick_open(page, MAIN)
    expect(page.locator("#editor")).to_have_value(edited)
    page.keyboard.press("Control+s")
    expect(page.locator("#buffer-status")).to_have_text("Saved in preview")
    after = snapshot(page)
    assert after["saved"] == edited
    assert after["head"] == before["head"] and after["index"] == before["index"]


@test("quick open keyboard navigation, empty results and focus restoration")
def quick_open_keyboard(page):
    page.locator("#quick-open").focus()
    page.keyboard.press("Enter")
    field = page.locator("#picker-input")
    expect(field).to_be_focused()
    field.press("ArrowDown")
    expect(field).to_have_attribute("aria-activedescendant", "picker-option-1")
    field.press("ArrowUp")
    expect(field).to_have_attribute("aria-activedescendant", "picker-option-0")
    field.fill("no-such-file")
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(0)
    field.press("Enter")
    expect(page.locator("#picker-dialog")).to_be_visible()
    page.keyboard.press("Escape")
    expect(page.locator("#quick-open")).to_be_focused()
    page.keyboard.press("Control+p")
    pick(page, "coral/src/workspace.zig")
    expect(page.locator("#editor")).to_be_focused()
    expect(page.locator("#breadcrumb")).to_contain_text("workspace.zig")


@test("command palette nested picker, modal focus and Escape")
def command_palette(page):
    page.keyboard.press("Control+Shift+p")
    pick(page, "Go to file")
    expect(page.locator("#picker-title")).to_have_text("Quick open")
    expect(page.locator("#picker-input")).to_be_focused()
    pick(page, PALETTE)
    expect(page.locator("#editor")).to_be_focused()
    page.locator("#help-button").click()
    expect(page.locator("#notice-dialog")).to_be_visible()
    for _ in range(5):
        page.keyboard.press("Tab")
        # Native dialogs may Tab to browser chrome, but not background controls.
        assert page.evaluate("document.querySelector('#notice-dialog').contains(document.activeElement) || (!document.hasFocus() && document.activeElement === document.body)")
    page.keyboard.press("Escape")
    expect(page.locator("#help-button")).to_be_focused()


@test("live workspace search and selected result")
def search(page):
    append_text(page, "// UniqueSearchNeedle")
    page.keyboard.press("Control+Shift+f")
    expect(page.locator("#search-input")).to_be_focused()
    page.locator("#search-input").fill("uniquesearchneedle")
    expect(page.locator("#search-results button")).to_have_count(1)
    page.locator("#search-results button").click()
    assert selected_text(page) == "UniqueSearchNeedle"
    expect(page.locator("#editor")).to_be_focused()
    page.locator("#search-input").fill("definitely absent")
    expect(page.locator("#search-summary")).to_have_text("No matches in this workspace.")


@test("workspace isolation, root addition, search and index retention")
def workspaces(page):
    append_text(page, "// Coral-only marker")
    coral = snapshot(page)
    click(page, "Source control")
    click(page, f"Stage file {MAIN}")
    click(page, "Explorer")
    click(page, "Add sample workspace root")
    expect(page.locator("#root-count")).to_have_text("3 roots")
    expect(page.locator("#add-root")).to_be_disabled()
    quick_open(page, "notes-kit/README.md")
    append_text(page, "Notes root marker")
    switch_workspace(page, "Pearl")
    expect(page.locator("#root-count")).to_have_text("2 roots")
    assert "Coral-only marker" not in page.locator("#editor").input_value()
    pearl = snapshot(page, "pearl/src/main.zig")
    assert pearl["head"] == pearl["index"]
    expect(page.locator("#add-root")).to_be_enabled()
    append_text(page, "// Pearl-only marker")
    switch_workspace(page, "Coral")
    expect(page.locator("#root-count")).to_have_text("3 roots")
    expect(page.locator("#editor")).to_have_value(re.compile("Notes root marker$"))
    quick_open(page, MAIN)
    expect(page.locator("#editor")).to_have_value(coral["text"])
    assert snapshot(page)["index"] == coral["text"]
    page.keyboard.press("Control+Shift+f")
    page.locator("#search-input").fill("Notes root marker")
    expect(page.locator("#search-results button")).to_have_count(1)


@test("diagnostic navigation and quickfix update buffer only")
def diagnostic(page):
    before = snapshot(page)
    page.locator("#problems-list button").click()
    assert selected_text(page) == "prnit"
    page.keyboard.press("Control+.")
    expect(page.locator("#picker-title")).to_have_text("Code actions · LSP fixture")
    page.locator("#picker-input").press("Enter")
    expect(page.locator("#problem-count")).to_have_text("0")
    expect(page.locator("#code-action")).to_be_disabled()
    expect(page.locator("#editor")).to_be_focused()
    after = snapshot(page)
    assert after["text"] == before["text"].replace("std.debug.prnit", "std.debug.print", 1)
    assert after["head"] == before["head"] and after["index"] == before["index"]
    assert after["saved"] == before["saved"]
    append_text(page, "\n// std.debug.prnit")
    expect(page.locator("#problem-count")).to_have_text("1")


@test("Git whole-file stage and unstage preserve buffer")
def git_file(page):
    before = snapshot(page, PALETTE)
    click(page, "Source control")
    expect(page.locator("#commit-button")).to_be_disabled()
    click(page, f"Stage file {PALETTE}")
    staged = snapshot(page, PALETTE)
    assert staged["index"] == before["text"] and staged["head"] == before["head"]
    click(page, f"Review staged diff for {PALETTE}")
    expect(page.locator("#diff-subtitle")).to_contain_text("HEAD → index")
    expect(page.locator("#breadcrumb")).to_contain_text("palette.zig")
    click(page, f"Unstage file {PALETTE}")
    after = snapshot(page, PALETTE)
    assert after == before
    expect(page.locator("#diff-content")).to_contain_text("No staged hunks")


@test("Git hunk stage, unstage and partial-stage commit")
def git_hunk(page):
    before = snapshot(page)
    click(page, "Source control")
    click(page, f"Review working diff for {MAIN}")
    expect(page.locator("#diff-content .diff-hunk")).to_have_count(2)
    click(page, f"Stage hunk 1 in {MAIN}")
    partial = snapshot(page)
    assert partial["head"] == before["head"] and partial["text"] == before["text"]
    assert partial["index"] != partial["head"] and partial["index"] != partial["text"]
    assert "roots.len > 0" in partial["index"] and "roots.len >= 2" in partial["text"]
    click(page, f"Review staged diff for {MAIN}")
    click(page, f"Unstage hunk 1 in {MAIN}")
    assert snapshot(page) == before
    click(page, f"Review working diff for {MAIN}")
    click(page, f"Stage hunk 1 in {MAIN}")
    click(page, f"Review staged diff for {MAIN}")
    screenshot(page, "git-partial-stage.png")
    page.locator("#commit-message").fill("Commit just the reviewed hunk")
    expect(page.locator("#commit-button")).to_be_enabled()
    page.locator("#commit-button").click()
    expect(page.locator("#commit-history")).to_contain_text("sim-001")
    after = snapshot(page)
    assert after["head"] == partial["index"] == after["index"]
    assert after["text"] == before["text"] and after["saved"] == before["saved"]
    assert after["head"] != after["text"]
    assert page.evaluate("workspace.commits[0].files[0].after") == partial["index"]
    expect(page.locator("#commit-button")).to_be_disabled()
    click(page, f"Review working diff for {MAIN}")
    expect(page.locator("#diff-content .diff-hunk")).to_have_count(1)


@test("branch picker is explicitly label-only")
def branch(page):
    before = snapshot(page)
    page.locator("#branch-button").click()
    expect(page.locator("#picker-results")).to_contain_text("Label only")
    pick(page, "review/agent-dock")
    expect(page.locator("#branch-name")).to_have_text("review/agent-dock")
    assert snapshot(page) == before


@test("agent denial captures no buffer and changes nothing")
def agent_deny(page):
    before = snapshot(page)
    submit_agent(page)
    assert page.evaluate("!Object.hasOwn(activeThread().task, 'before')")
    click(page, "Deny")
    task_status(page, "denied")
    expect(page.locator("#agent-messages")).to_contain_text("Read denied")
    assert page.evaluate("!Object.hasOwn(activeThread().task, 'before')")
    assert snapshot(page) == before
    expect(page.locator("#agent-prompt")).to_be_focused()


@test("agent cancellation before approval")
def agent_cancel_approval(page):
    before = snapshot(page)
    submit_agent(page)
    click(page, "Cancel request")
    task_status(page, "cancelled")
    assert snapshot(page) == before
    assert page.evaluate("!Object.hasOwn(activeThread().task, 'before')")


@test("agent cancellation during approved read survives timer")
def agent_cancel_read(page):
    freeze_clock(page)
    before = snapshot(page)
    submit_agent(page)
    click(page, "Allow read")
    task_status(page, "working")
    click(page, "Cancel request")
    page.clock.run_for(1200)
    task_status(page, "cancelled")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)
    assert snapshot(page) == before


@test("agent patch acceptance updates buffer but not HEAD, index or save")
def agent_accept(page):
    before = snapshot(page)
    propose(page)
    expect(page.locator(".patch-preview .removed")).to_contain_text("prnit")
    expect(page.locator(".patch-preview .added")).to_contain_text("print")
    screenshot(page, "agent-review.png")
    click(page, "Accept patch")
    task_status(page, "applied")
    after = snapshot(page)
    assert after["text"] == before["text"].replace("std.debug.prnit", "std.debug.print", 1)
    for key in ("head", "index", "saved"):
        assert after[key] == before[key]
    expect(page.locator("#problem-count")).to_have_text("0")
    expect(page.locator("#buffer-status")).to_contain_text("Unsaved")


@test("agent patch rejection changes no snapshots")
def agent_reject(page):
    before = snapshot(page)
    propose(page)
    click(page, "Reject")
    task_status(page, "rejected")
    assert snapshot(page) == before
    expect(page.locator("#agent-messages")).to_contain_text("Patch rejected")


@test("agent stale patch blocks acceptance and preserves real typing")
def agent_stale(page):
    before = snapshot(page)
    propose(page)
    append_text(page, "// user typing must win")
    task_status(page, "stale")
    expect(page.locator("#agent-messages")).to_contain_text("Patch blocked · buffer changed")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)
    after = snapshot(page)
    assert after["text"] == before["text"] + "// user typing must win"
    assert after["index"] == before["index"] and after["head"] == before["head"]
    screenshot(page, "agent-stale.png")
    click(page, "Prepare new request")
    expect(page.locator("#agent-prompt")).to_have_value("Fix the diagnostic carefully")
    click(page, "Send agent prompt")
    click(page, "Allow read")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_be_visible()
    click(page, "Accept patch")
    assert snapshot(page)["text"].endswith("// user typing must win")


@test("typing during approved read produces stale result without focus loss")
def agent_typing_during_read(page):
    freeze_clock(page)
    submit_agent(page)
    click(page, "Allow read")
    append_text(page, "// edit during read")
    edited = snapshot(page)
    page.clock.run_for(850)
    task_status(page, "stale")
    expect(page.locator("#editor")).to_be_focused()
    assert snapshot(page) == edited
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)


@test("thread history, drafts, model/profile selection and Ask report")
def agent_threads(page):
    page.locator("#agent-model").select_option(label="Reasoning · fixture")
    page.locator("#agent-profile").select_option("ask")
    before = snapshot(page)
    submit_agent(page, "Inspect the workspace")
    click(page, "Allow read")
    task_status(page, "answered")
    expect(page.locator("#agent-prompt")).to_be_focused()
    expect(page.locator("#agent-messages")).to_contain_text("canned report")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)
    assert snapshot(page) == before
    page.locator("#agent-prompt").fill("Retain this draft")
    click(page, "New agent thread")
    expect(page.locator("#agent-prompt")).to_have_value("")
    propose(page, "A second thread")
    click(page, "Thread history")
    pick(page, "Inspect the workspace")
    expect(page.locator("#agent-prompt")).to_have_value("Retain this draft")
    expect(page.locator("#agent-model")).to_have_value("Reasoning · fixture")
    expect(page.locator("#agent-profile")).to_have_value("ask")
    click(page, "Thread history")
    pick(page, "A second thread")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_be_visible()


@test("background thread patch invalidates after buffer typing")
def agent_background_stale(page):
    propose(page, "Original review thread")
    click(page, "New agent thread")
    append_text(page, "// background target changed")
    click(page, "Thread history")
    pick(page, "Original review thread")
    task_status(page, "stale")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)


@test("agent approval snapshot follows original workspace and file")
def agent_workspace_target(page):
    freeze_clock(page)
    before = snapshot(page)
    submit_agent(page, "Coral target, even when I switch")
    click(page, "Allow read")
    switch_workspace(page, "Pearl")
    pearl = snapshot(page, "pearl/src/main.zig")
    expect(page.locator("#thread-title")).to_have_text("A careful first pass")
    page.clock.run_for(850)
    assert snapshot(page, "pearl/src/main.zig") == pearl
    switch_workspace(page, "Coral")
    task_status(page, "proposed")
    quick_open(page, PALETTE)
    palette = snapshot(page, PALETTE)
    click(page, "Accept patch")
    assert snapshot(page, PALETTE) == palette
    assert snapshot(page)["text"] == before["text"].replace("std.debug.prnit", "std.debug.print", 1)


@test("HTML-like user input renders as text, never elements")
def safe_text(page):
    payload = '<img src="https://invalid.example/probe" onerror="window.injected=true">'
    page.locator("#editor").fill(payload)
    expect(page.locator("#highlight")).to_have_text(payload + "\n")
    expect(page.locator("#highlight img")).to_have_count(0)
    submit_agent(page, payload)
    expect(page.locator(".user-message .message-body")).to_have_text(payload)
    expect(page.locator("#agent-messages img")).to_have_count(0)
    click(page, "Deny")
    click(page, "Source control")
    click(page, f"Stage file {MAIN}")
    page.locator("#commit-message").fill(payload)
    page.locator("#commit-button").click()
    expect(page.locator("#commit-history")).to_contain_text(payload)
    expect(page.locator("#commit-history img")).to_have_count(0)
    assert page.evaluate("window.injected === undefined")


@test("terminal fixtures, unsupported command notice and panel keyboard")
def terminal(page):
    page.locator("#problems-tab").focus()
    page.keyboard.press("ArrowRight")
    expect(page.locator("#terminal-tab")).to_be_focused()
    expect(page.locator("#terminal-content")).to_be_visible()
    field = page.locator("#terminal-input")
    for command, response in [("help", "SIMULATION ONLY"), ("zig build", "No compiler was run"),
                              ("git status", MAIN), ("rm -rf not-executed", "Unsupported command")]:
        field.fill(command)
        field.press("Enter")
        expect(page.locator("#terminal-output")).to_contain_text(response)
    field.fill("clear")
    field.press("Enter")
    expect(page.locator("#terminal-output")).to_have_text("")
    page.keyboard.press("Control+j")
    expect(page.locator("#bottom-panel")).to_be_hidden()
    page.keyboard.press("Control+j")
    expect(page.locator("#bottom-panel")).to_be_visible()
    page.locator("#terminal-tab").focus()
    page.keyboard.press("Home")
    expect(page.locator("#problems-tab")).to_be_focused()


@test("theme and desktop panel toggles retain buffer")
def toggles(page):
    append_text(page, "// layout retains buffer")
    before = snapshot(page)
    background = page.locator("#main-area").evaluate("e => getComputedStyle(e).backgroundColor")
    click(page, "Switch to light theme")
    expect(page.locator("body")).to_have_class("light")
    assert page.locator("#main-area").evaluate("e => getComputedStyle(e).backgroundColor") != background
    for name, target in [("Toggle sidebar", "#sidebar"), ("Toggle agent dock", "#agent-dock"), ("Toggle bottom panel", "#bottom-panel")]:
        click(page, name)
        expect(page.locator(target)).to_be_hidden()
        bounds(page, name + " hidden")
        click(page, name)
        expect(page.locator(target)).to_be_visible()
    assert snapshot(page) == before
    click(page, "Switch to dark theme")
    expect(page.locator("body")).not_to_have_class("light")


def responsive(page, width, height, theme):
    page.set_viewport_size({"width": width, "height": height})
    page.reload()
    expect(page.locator("#editor")).to_be_visible()
    if theme == "light":
        click(page, "Switch to light theme")
    bounds(page, f"{width} {theme} initial")
    screenshot(page, f"workbench-{width}-{theme}.png")
    page.locator("#command-button").click()
    bounds(page, f"{width} {theme} command dialog")
    expect(page.locator("#picker-input")).to_be_focused()
    page.keyboard.press("Escape")
    expect(page.locator("#command-button")).to_be_focused()
    page.locator("#help-button").click()
    bounds(page, f"{width} {theme} notice dialog")
    page.keyboard.press("Escape")
    if width <= 1100:
        expect(page.locator("#agent-dock")).to_be_hidden()
        click(page, "Toggle agent dock")
        expect(page.locator("#agent-prompt")).to_be_focused()
        bounds(page, f"{width} {theme} agent drawer")
        submit_agent(page, f"Review at {width}")
        click(page, "Allow read")
        expect(page.get_by_role("button", name="Accept patch", exact=True)).to_be_visible()
        if width == 390 and theme == "dark":
            screenshot(page, "agent-review-narrow.png")
        click(page, "Reject")
        page.keyboard.press("Escape")
        expect(page.locator("#agent-dock")).to_be_hidden()
        expect(page.locator("#agent-toggle")).to_be_focused()
    if width <= 700:
        expect(page.locator("#sidebar")).to_be_hidden()
        click(page, "Explorer")
        expect(page.locator("#sidebar")).to_be_visible()
        bounds(page, f"{width} {theme} sidebar drawer")
        click(page, "Open coral/src/workspace.zig")
        expect(page.locator("#sidebar")).to_be_hidden()
        expect(page.locator("#editor")).to_be_focused()
        click(page, "Search workspace")
        page.locator("#search-input").fill("defaultRoots")
        page.locator("#search-results button").first.click()
        expect(page.locator("#sidebar")).to_be_hidden()
        click(page, "Source control")
        click(page, f"Review working diff for {MAIN}")
        expect(page.locator("#sidebar")).to_be_hidden()
        bounds(page, f"{width} {theme} diff")
        click(page, f"Stage hunk 1 in {MAIN}")
        page.locator("#return-editor").click()
        click(page, "Explorer")
        click(page, "Toggle agent dock")
        expect(page.locator("#sidebar")).to_be_hidden()
        expect(page.locator("#agent-dock")).to_be_visible()
        click(page, "Explorer")
        expect(page.locator("#agent-dock")).to_be_hidden()
        click(page, "Close sidebar")
        expect(page.locator("#sidebar-toggle")).to_be_focused()
    bounds(page, f"{width} {theme} final")


for width, height in [(1440, 900), (1024, 768), (700, 800), (390, 844)]:
    for theme in ("dark", "light"):
        test(f"responsive {width}x{height} {theme} dialogs and drawers")(
            lambda page, w=width, h=height, t=theme: responsive(page, w, h, t))


@test("resize breakpoints close drawers without losing edits")
def resize(page):
    append_text(page, "// resize marker")
    before = snapshot(page)
    page.set_viewport_size({"width": 1024, "height": 768})
    expect(page.locator("#agent-dock")).to_be_hidden()
    page.set_viewport_size({"width": 390, "height": 844})
    expect(page.locator("#sidebar")).to_be_hidden()
    bounds(page, "resized to mobile")
    page.set_viewport_size({"width": 1440, "height": 900})
    expect(page.locator("#sidebar")).to_be_hidden()
    expect(page.locator("#agent-dock")).to_be_hidden()
    bounds(page, "resized to desktop with panes closed")
    assert snapshot(page) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", default="", help="Run cases whose name contains this text")
    args = parser.parse_args()
    selected = [(name, fn) for name, fn in TESTS if args.only.lower() in name.lower()]
    if not selected:
        parser.error("No matching tests")
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "entrypoint": URL, "platform": platform.platform(),
        "browser": "Chromium", "browser_version": None,
        "browser_note": "Supplied Playwright Ubuntu fallback build on an unsupported host; launch tested here.",
        "offline": True, "partial_run": bool(args.only), "filter": args.only,
        "test_count": len(selected), "passed": 0, "failed": 0,
        "tests": [], "screenshots": SCREENSHOTS, "layout_measurements": LAYOUTS,
        "network_requests": [], "console_errors": [], "page_errors": [],
        "source_sha256": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                          for name in ("index.html", "style.css", "mockup.js", "verify.py")},
        "limits": ["Chromium only; no screen-reader, IME, native GTK or real-touch validation.",
                   "UI actions are real events; internal snapshots are inspected read-only.",
                   "No real Git, compiler, filesystem operations or provider integration is tested."],
    }
    started = time.monotonic()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            report["browser_version"] = browser.version
            for name, function in selected:
                case = {"name": name, "status": "passed", "requests": [], "console_errors": [], "page_errors": []}
                context = browser.new_context(viewport={"width": 1440, "height": 900},
                                              device_scale_factor=1, reduced_motion="reduce", offline=True)
                # Defense in depth: abort and record any attempted non-local request.
                context.route("**/*", lambda route: route.continue_() if route.request.url.startswith("file:") else route.abort())
                page = context.new_page()
                page.set_default_timeout(5000)
                page.on("request", lambda request: case["requests"].append(request.url))
                page.on("pageerror", lambda error: case["page_errors"].append(str(error)))
                page.on("console", lambda message: case["console_errors"].append(message.text) if message.type == "error" else None)
                case_start = time.monotonic()
                try:
                    page.goto(URL, wait_until="load")
                    expect(page.locator("#editor")).to_have_value(re.compile("Coral Workbench"))
                    function(page)

                    assert not case["page_errors"], case["page_errors"]
                    assert not case["console_errors"], case["console_errors"]
                    external = [url for url in case["requests"] if not url.startswith("file:")]
                    assert not external, external
                    expected_assets = {URL, (HERE / "style.css").as_uri(), (HERE / "mockup.js").as_uri()}
                    assert set(case["requests"]) == expected_assets, case["requests"]
                except Exception:
                    case["status"] = "failed"
                    case["error"] = traceback.format_exc()
                    filename = "failure-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") + ".png"
                    try:
                        page.screenshot(path=str(HERE / filename), animations="disabled", timeout=3000)
                        case["failure_screenshot"] = filename
                    except Exception as error:
                        case["screenshot_error"] = str(error)
                finally:
                    case["seconds"] = round(time.monotonic() - case_start, 3)
                    report["tests"].append(case)
                    report["passed" if case["status"] == "passed" else "failed"] += 1
                    report["network_requests"].extend(url for url in case["requests"] if not url.startswith("file:"))
                    report["console_errors"].extend(case["console_errors"])
                    report["page_errors"].extend(case["page_errors"])
                    print(f"{case['status'].upper()}: {name}", flush=True)
                    if case["status"] == "failed":
                        print(case["error"], flush=True)
                    context.close()
            browser.close()
    except Exception:
        report["fatal_error"] = traceback.format_exc()
        print(report["fatal_error"], flush=True)
    finally:
        report["seconds"] = round(time.monotonic() - started, 3)
        report["success"] = not report.get("fatal_error") and report["failed"] == 0 and report["passed"] == len(selected)
        (HERE / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{report['passed']}/{len(selected)} passed; {report['failed']} failed. Report: {HERE / 'verification.json'}")
    return 0 if report["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
