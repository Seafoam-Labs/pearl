#!/usr/bin/env python3
"""M0 browser review: reuse the offline harness, add safety/identity regressions.

Run from pearl with the same Playwright environment as docs/mockups/workbench/verify.py.
Only artifacts under docs/mockups/workbench are written. No native gate is executed.
--only is forwarded to the existing harness and explicitly marks a partial report.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path

from playwright.sync_api import expect

CORAL = Path(__file__).resolve().parents[1]
HERE = CORAL / "docs/mockups/workbench"
spec = importlib.util.spec_from_file_location("workbench_verify", HERE / "verify.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
RECEIPTS = {}


def state(page):
    """Read-only receipt of all fixture documents, not just the visible target."""
    return page.evaluate("""() => workspaces.map(w => ({
        id: w.id, roots: w.roots, active: w.active, tabs: w.tabs,
        files: w.files.map(f => ({id:f.id, head:f.head, index:f.index,
            text:f.text, saved:f.saved, revision:f.revision})), commits:w.commits
    }))""")


def receipt(page, name):
    value = state(page)
    RECEIPTS[name] = {"snapshots": value, "sha256": hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()}
    return value


def documents(value):
    return [{"id": w["id"], "files": w["files"], "commits": w["commits"]} for w in value]


@v.test("M0 W01 palette editor/search Escape and single keyboard dispatch")
def m0_palette_contexts(page):
    before = state(page)
    for field in (page.locator("#editor"), page.locator("#search-input")):

        if field.get_attribute("id") == "search-input":
            page.keyboard.press("Control+Shift+f")
            field.fill("defaultRoots")
        field.focus()
        text = field.input_value()
        page.keyboard.press("Control+Shift+p")
        page.locator("#picker-input").fill("New document")
        expect(page.locator("#picker-results").get_by_role("option")).to_have_count(0)
        page.locator("#picker-input").press("Enter")
        expect(page.locator("#picker-dialog")).to_be_visible()
        page.keyboard.press("Escape")
        expect(field).to_be_focused()
        assert field.input_value() == text
        assert state(page) == before
        was_light = page.locator("body").evaluate("e => e.classList.contains('light')")
        page.keyboard.press("Control+Shift+p")
        v.pick(page, "Appearance: toggle theme")
        expect(page.locator("#picker-dialog")).to_be_hidden()
        assert page.locator("body").evaluate("e => e.classList.contains('light')") != was_light
        expect(field).to_be_focused()
    v.screenshot(page, "m0-palette-search-focus.png")


@v.test("M0 W01 unavailable fixture commands are not offered as working")
def m0_command_availability(page):
    v.click(page, "Add sample workspace root")
    page.keyboard.press("Control+Shift+p")
    page.locator("#picker-input").fill("Workspace: add sample root")
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(0)
    page.keyboard.press("Escape")
    page.locator("#workspace-button").click()
    page.locator("#picker-input").fill("Add sample root")
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(0)
    page.keyboard.press("Escape")
    v.quick_open(page, "coral/README.md")
    expect(page.locator("#code-action")).to_be_disabled()
    page.keyboard.press("Control+Shift+p")
    page.locator("#picker-input").fill("LSP: code actions")
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(0)
    page.keyboard.press("Escape")
    v.quick_open(page, v.MAIN)
    page.keyboard.press("Control+Shift+p")
    v.pick(page, "LSP: code actions")
    expect(page.locator("#picker-title")).to_have_text("Code actions · LSP fixture")


@v.test("M0 W07 colliding basenames Unicode search and workspace return")
def m0_root_identity(page):
    marker = "M0 café Ω 🪸"
    for file_id in ("coral/README.md", "shared-ui/README.md"):
        v.quick_open(page, file_id)
        page.locator("#editor").press("Control+End")
        page.keyboard.insert_text(marker + " " + file_id)
    before = receipt(page, "W07-two-root-unicode")
    page.keyboard.press("Control+p")
    page.locator("#picker-input").fill("README.md")
    expect(page.locator("#picker-results").get_by_role("option")).to_have_count(2)
    for path in ("coral/README.md", "shared-ui/README.md"):
        expect(page.locator("#picker-results")).to_contain_text(path)
    v.screenshot(page, "m0-root-identity.png")
    page.keyboard.press("Escape")
    page.keyboard.press("Control+Shift+f")
    page.locator("#search-input").fill(marker)
    expect(page.locator("#search-results button")).to_have_count(2)
    for path in ("coral/README.md", "shared-ui/README.md"):
        page.locator("#search-results button").filter(has_text=path).click()
        expect(page.locator("#editor")).to_have_attribute("aria-label", "Edit " + path)
        assert v.selected_text(page) == marker
    v.switch_workspace(page, "Pearl")
    assert marker not in page.locator("#editor").input_value()
    v.switch_workspace(page, "Coral")
    assert documents(state(page)) == documents(before)
    expect(page.locator("#search-input")).to_have_value(marker)
    expect(page.locator("#editor")).to_have_attribute("aria-label", "Edit shared-ui/README.md")
    assert state(page)[0]["tabs"] == before[0]["tabs"]


@v.test("M0 W08 D1 empty index with message never stages or commits")
def m0_empty_index(page):
    before = receipt(page, "D1-empty-index-before")
    v.click(page, "Source control")
    page.locator("#commit-message").fill("This is not authorization to stage")
    expect(page.locator("#commit-button")).to_be_disabled()
    page.locator("#commit-message").press("Enter")
    assert state(page) == before
    v.click(page, f"Stage file {v.MAIN}")
    expect(page.locator("#commit-button")).to_be_enabled()
    v.click(page, f"Unstage file {v.MAIN}")
    expect(page.locator("#commit-button")).to_be_disabled()
    page.locator("#commit-message").press("Enter")
    assert receipt(page, "D1-empty-index-after") == before
    v.screenshot(page, "m0-empty-index.png")


@v.test("M0 W09 D2 proposal is inert through permission review and reject")
def m0_proposal_receipts(page):
    v.freeze_clock(page)
    before = receipt(page, "D2-before-request")
    page.locator("#agent-prompt").fill("Fix only the fixture typo")
    page.locator("#agent-prompt").press("Control+Enter")
    v.task_status(page, "approval")
    assert not page.evaluate("Object.hasOwn(activeThread().task, 'before')")
    assert receipt(page, "D2-permission-pending") == before
    v.screenshot(page, "m0-permission.png")
    v.click(page, "Allow read")
    assert receipt(page, "D2-approved-read") == before
    page.clock.run_for(850)
    v.task_status(page, "proposed")
    assert receipt(page, "D2-proposed-inert") == before
    v.click(page, "Reject")
    v.task_status(page, "rejected")
    assert receipt(page, "D2-rejected") == before
    v.screenshot(page, "m0-rejected.png")
    v.submit_agent(page, "Try the same proposal again")
    v.click(page, "Allow read")
    page.clock.run_for(850)
    v.task_status(page, "proposed")
    assert state(page) == before
    v.click(page, "Accept patch")
    after = receipt(page, "D2-accepted-buffer-only")
    expected = json.loads(json.dumps(before))
    target = expected[0]["files"][0]
    target["text"] = target["text"].replace("std.debug.prnit", "std.debug.print", 1)
    target["revision"] += 1
    assert after == expected


@v.test("M0 W10 stale proposal remains blocked after real browser undo")
def m0_stale_undo(page):
    before = receipt(page, "W10-before-undo")
    v.propose(page)
    editor = page.locator("#editor")
    editor.focus()
    editor.press("Control+End")
    page.keyboard.insert_text("// temporary Ω edit")
    v.task_status(page, "stale")
    editor.press("Control+z")
    expect(editor).to_have_value(before[0]["files"][0]["text"])
    after = receipt(page, "W10-identical-bytes-new-revision")
    assert after[0]["files"][0]["revision"] > before[0]["files"][0]["revision"]
    for old_workspace, new_workspace in zip(before, after):
        for old, new in zip(old_workspace["files"], new_workspace["files"]):
            for key in ("id", "head", "index", "text", "saved"):
                assert old[key] == new[key]
        assert new_workspace["commits"] == old_workspace["commits"]
    v.task_status(page, "stale")
    expect(page.get_by_role("button", name="Accept patch", exact=True)).to_have_count(0)
    expect(page.get_by_role("button", name="Prepare new request", exact=True)).to_be_visible()
    v.screenshot(page, "m0-stale-after-undo.png")


@v.test("M0 W06 D3 reload resets preview and is not crash recovery")
def m0_reload_boundary(page):
    before = receipt(page, "D3-initial-fixtures")
    page.locator("#editor").press("Control+End")
    page.keyboard.insert_text("// unsaved session only")
    page.keyboard.press("Control+s")
    v.click(page, "Source control")
    v.click(page, f"Stage file {v.MAIN}")
    page.locator("#commit-message").fill("Simulated history only")
    page.locator("#commit-button").click()
    assert state(page) != before
    receipt(page, "D3-memory-only-saved-committed")
    page.reload()
    expect(page.locator("#editor")).to_be_visible()
    assert receipt(page, "D3-reload-reset") == before


@v.test("M0 W10 D4 narrow light permission deny cancel review artifacts")
def m0_narrow_review(page):
    page.set_viewport_size({"width": 390, "height": 844})
    page.reload()
    v.click(page, "Switch to light theme")
    before = state(page)
    v.submit_agent(page, "Review permission without applying")
    v.bounds(page, "M0 light narrow permission")
    v.screenshot(page, "m0-narrow-light-permission.png")
    v.click(page, "Deny")
    v.task_status(page, "denied")
    expect(page.locator("#agent-prompt")).to_be_focused()
    v.screenshot(page, "m0-narrow-light-denied.png")
    v.submit_agent(page, "Cancel before reading")
    v.click(page, "Cancel request")
    v.task_status(page, "cancelled")
    expect(page.locator("#agent-prompt")).to_be_focused()
    v.screenshot(page, "m0-narrow-light-cancelled.png")
    assert state(page) == before
    v.propose(page, "Inspect the patch in light mode")
    assert state(page) == before
    v.bounds(page, "M0 light narrow patch")
    v.screenshot(page, "m0-narrow-light-proposal.png")
    v.click(page, "Reject")
    assert state(page) == before
    page.keyboard.press("Escape")
    expect(page.locator("#agent-toggle")).to_be_focused()
    v.click(page, "Explorer")
    v.bounds(page, "M0 light narrow Explorer")
    v.screenshot(page, "m0-narrow-light-explorer.png")
    page.keyboard.press("Escape")
    expect(page.locator("#sidebar-toggle")).to_be_focused()


# Function names resolve to the exact executable case names in the JSON report.
# A related browser check NEVER upgrades a partial/native boundary to full coverage.
WORKFLOWS = {
    "W01": {"browser": ["quick_open_keyboard", "command_palette", "m0_palette_contexts", "m0_command_availability"],
            "native": ["tests/native.py"], "boundary": "Partial: no New document or native Find input in this prototype; native palette fixtures not run here."},
    "W02": {"browser": [], "native": ["tests/app_groups.py", "src/editor/view_test.zig"],
            "boundary": "Not implemented in prototype: simultaneous native panes, independent selection/scroll and undo require native evidence."},
    "W03": {"browser": [], "native": ["src/editor/excerpt_tests.zig", "src/editor/excerpt_editor_tests.zig", "tests/app_groups.py"],
            "boundary": "Not implemented in prototype: editable mapped excerpts and historical read-only source require native evidence."},
    "W04": {"browser": ["tabs"], "native": ["tests/native.py"],
            "boundary": "Partial analogy only: preview save is memory-only. No Save As, canonical paths, FIFO or filesystem race tests here."},
    "W05": {"browser": ["m0_stale_undo"], "native": ["src/editor/history_tests.zig"],
            "boundary": "Partial analogy only: one-buffer stale proposal; no multi-document atomic transaction or grouped undo in prototype."},
    "W06": {"browser": ["m0_reload_boundary"], "native": ["tests/app_recovery.py"],
            "boundary": "Negative boundary only: reload discards state. No crash recovery, journal, chooser or disk conflict implementation in prototype."},
    "W07": {"browser": ["workspaces", "m0_root_identity", "agent_workspace_target"], "native": [],
            "boundary": "Partial M0 simulation: root identity, buffers/tabs/search and request targets. Layout is global, not restored per workspace. Full native M2 not implemented here."},
    "W08": {"browser": ["git_file", "git_hunk", "m0_empty_index"], "native": [],
            "boundary": "Partial M0 simulation: HEAD/index/buffer invariants. No real repository or external-index invalidation; native M4 not implemented here."},
    "W09": {"browser": ["agent_accept", "agent_reject", "m0_proposal_receipts"], "native": [],
            "boundary": "Partial M0 simulation: explicit read of active buffer, whole canned patch accept/reject. No selection attachment, context picker or per-hunk acceptance; native M6 not implemented here."},
    "W10": {"browser": ["agent_deny", "agent_cancel_approval", "agent_cancel_read", "agent_stale", "agent_typing_during_read", "agent_background_stale", "agent_workspace_target", "m0_stale_undo", "m0_narrow_review"], "native": [],
             "boundary": "Partial M0 simulation: permission, local timer cancellation, revisions and original target. No streamed partial responses, provider execution or ACP; native M6/M7 not implemented here."},
    "W11": {"browser": ["terminal"], "native": ["src/terminal/pty_test.zig"],
             "boundary": "Negative boundary only: terminal is canned. M0 native PTY/widget spike needs separate evidence; full native M5 not implemented here."},
    "W12": {"browser": [], "native": [],
             "boundary": "Not implemented: no ACP fake peer, negotiation, stream, disconnect or adapter fixture in this browser suite. Native M7 remains separate."},
    "D1": {"browser": ["git_hunk", "m0_empty_index"], "native": [],
           "boundary": "Staged-only design exercised in memory; product approval not recorded."},
    "D2": {"browser": ["m0_proposal_receipts", "m0_stale_undo", "agent_deny", "agent_cancel_read"], "native": [],
           "boundary": "Inert-until-accept policy exercised in memory; not process containment. Product approval not recorded."},
    "D3": {"browser": ["m0_reload_boundary"], "native": ["tests/app_recovery.py", "src/editor/history_tests.zig"],
           "boundary": "Prototype deliberately has no recovery/checkpoint promise; native recovery tests linked, not executed. Product approval not recorded."},
    "D4": {"browser": ["initial", "branch", "terminal", "m0_palette_contexts", "m0_narrow_review", "toggles"], "native": [],
           "boundary": "Offline/native-scope disclosures reviewed; appearance is a browser concept, not GTK parity or provider ownership implementation. Product approval not recorded."},
}


def main():
    names = {function.__name__: name for name, function in v.TESTS}
    assert set(WORKFLOWS) == {f"W{i:02}" for i in range(1, 13)} | {f"D{i}" for i in range(1, 5)}
    native_sources = {}
    for entry in WORKFLOWS.values():
        entry["browser_cases"] = [names[name] for name in entry["browser"]]
        entry["native_execution"] = "not run by this suite"
        for path in entry["native"]:
            native_sources[path] = hashlib.sha256((CORAL / path).read_bytes()).hexdigest()
    reference = CORAL / "docs/WORKBENCH_M0_REFERENCES.md"
    code = Path(__file__).resolve()
    return v.main(report_name="m0-review-verification.json", extra_report={
        "review_scope": "M0 browser fixture evidence only; not native acceptance or user approval",
        "user_approval": "not recorded",
        "workflow_mapping": WORKFLOWS,
        "fixture_receipts": RECEIPTS,
        "additional_source_sha256": {
            str(code.relative_to(CORAL)): hashlib.sha256(code.read_bytes()).hexdigest(),
            str(reference.relative_to(CORAL)): hashlib.sha256(reference.read_bytes()).hexdigest(),
        },
        "linked_native_sources_not_executed_sha256": native_sources,
    })


if __name__ == "__main__":
    raise SystemExit(main())
