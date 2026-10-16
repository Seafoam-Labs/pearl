#!/usr/bin/env python3
"""Browser validation only; the interactive mockup is self-contained HTML."""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
checks = []


def check(name, assertion):
    assert assertion, name
    checks.append(name)


def main():
    errors = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path="/usr/bin/chromium", headless=True, args=["--no-sandbox"])
        page = browser.new_page(viewport={"width": 1280, "height": 1000}, device_scale_factor=1)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto((HERE / "index.html").as_uri())

        def go(name):
            page.locator(f'[data-page="{name}"]').click()

        def field(path):
            return page.locator(f'[data-field="{path}"]')

        def action(name):
            page.locator(f'[data-action="{name}"]').click()

        def reset():
            page.locator("#reset").click()

        def apply():
            page.locator("#apply").click()
            action("confirm-apply")

        def capture(name):
            page.locator("#toast").wait_for(state="hidden")
            page.screenshot(path=str(HERE / f"{name}.png"))

        for key, title in [("appearance", "Appearance"), ("layouts", "Layouts"), ("input", "Input"), ("keybinds", "Keybindings"), ("rules", "Rules"), ("displays", "Displays"), ("advanced", "Advanced")]:
            go(key)
            check(f"route {key}", page.locator("h1").inner_text() == title)
            capture(title)
        check("navigation does not dirty draft", page.locator("#apply").is_disabled())

        go("appearance")
        field("appearance.border").fill("4")
        go("input")
        field("input.keyboard").fill("de")
        go("appearance")
        check("draft retained across pages", field("appearance.border").input_value() == "4")
        page.locator("#apply").click()
        check("shared review includes both sections", all(s in page.locator("#dialog").inner_text() for s in ["Appearance", "Input"]))
        capture("review")
        action("cancel")
        check("cancel review retains draft", page.locator("#apply").is_enabled())
        apply()
        check("apply establishes saved baseline", page.locator("#apply").is_disabled())
        field("appearance.border").fill("7")
        page.locator("#discard").click()
        action("confirm-discard")
        check("discard restores saved baseline", field("appearance.border").input_value() == "4")
        field("appearance.border").fill("99")
        check("invalid numeric value blocks apply", page.locator("#apply").is_disabled() and page.locator("#banner").is_visible())
        reset()

        go("layouts")
        page.locator('input[name="layout"][value="monocle"]').check()
        check("layout choice updates preview", page.locator("#layout-preview").get_attribute("data-layout") == "monocle")
        reset()
        go("keybinds")
        page.locator("#shortcut-search").fill("TERMINAL")
        check("shortcut search ignores case", page.locator("#shortcut-list .shortcut-row").count() == 1)
        page.locator("#shortcut-search").fill("no-such-action")
        check("empty search feedback", "No matching" in page.locator("#shortcut-list").inner_text())
        page.locator("#shortcut-search").fill("")
        field("keybinds.close").fill("Super+Return")
        check("shortcut collision blocks apply", page.locator("#apply").is_disabled() and "same chord" in page.locator("#banner").inner_text())
        reset()
        action("add-shortcut")
        page.locator('#shortcut-form [name="chord"]').fill("Super+M")
        page.locator('#shortcut-form [name="command"]').fill("spawn:music")
        action("save-shortcut")
        check("custom shortcut stages without execution", "spawn:music" in page.locator("#content").inner_text())
        reset()

        go("rules")
        page.locator('[data-action="edit-rule"]').first.click()
        page.locator('#rule-form [name="app"]').fill("org.example.New")
        action("cancel")
        check("cancel rule preserves baseline", page.locator("#apply").is_disabled())
        action("add-rule")
        page.locator('#rule-form [name="app"]').fill("org.example.New")
        action("save-rule")
        check("add rule stages new item", page.locator(".rule").count() == 3)
        check("dirty draft blocks reordering", all(x.is_disabled() for x in page.locator('[data-action="move-rule"]').all()))
        reset()
        page.locator('[data-action="move-rule"][data-direction="1"]').first.click()
        go("appearance")
        check("rule move locks cross-page edits", field("appearance.border").is_disabled())
        page.locator("#discard").click()
        action("confirm-discard")
        check("discard move restores editability", field("appearance.border").is_enabled())

        go("displays")
        page.locator('[data-action="select-screen"][data-index="0"]').first.click()
        check("screen selection updates editor", "1 · Built-in display" in page.locator("#content").inner_text())
        field("displays.screens.0.enabled").uncheck()
        page.locator('[data-action="select-screen"][data-index="1"]').first.click()
        field("displays.screens.1.enabled").click()
        check("last-screen guard", field("displays.screens.1.enabled").is_checked())
        reset()
        field("displays.position").select_option("left")
        check("relative positioning updates diagram", page.locator("#screen-map").get_attribute("data-position") == "left")
        field("displays.screens.1.scale").select_option("125%")
        apply()
        capture("preview")
        page.keyboard.press("Escape")
        check("escape reverts and retains draft", not page.locator("#dialog").is_visible() and page.locator("#apply").is_enabled())
        apply()
        page.wait_for_timeout(15500)
        check("automatic preview timeout retains draft", not page.locator("#dialog").is_visible() and page.locator("#apply").is_enabled())
        apply()
        action("keep")
        check("keep saves sample display draft", page.locator("#apply").is_disabled())
        field("displays.screens.1.hdr").check()
        page.locator("#scenario").select_option("unavailable")
        check("unavailable display preview blocks apply", page.locator("#apply").is_disabled())
        capture("unavailable")
        for state in ["offline", "conflict", "unknown"]:
            page.locator("#scenario").select_option(state)
            check(f"{state} blocks save", page.locator("#apply").is_disabled())
        page.locator("#scenario").select_option("failure")
        apply()
        check("apply failure retains draft", page.locator("#apply").is_enabled() and "Apply failed" in page.locator("#banner").inner_text())
        reset()

        go("advanced")
        page.locator('[data-disclosure="request"] summary').click()
        field("advanced.request").fill("{")
        check("invalid JSON retained with feedback", field("advanced.request").input_value() == "{" and page.locator("#apply").is_disabled())
        reset()
        page.locator("#scenario").select_option("conflict")
        page.locator('#banner [data-action="rebase"]').click()
        action("use-external")
        go("input")
        check("explicit conflict choice", field("input.keyboard").input_value() == "de" and page.locator("#scenario").input_value() == "ready")
        reset()
        go("appearance")
        page.locator("#theme").click()
        capture("light")
        page.locator("#theme").click()
        page.set_viewport_size({"width": 390, "height": 844})
        capture("narrow")
        for key in ["appearance", "layouts", "input", "keybinds", "rules", "displays", "advanced"]:
            page.locator("#sections").click()
            page.locator(f'[data-page="{key}"]').click()
            check(f"390px no overflow {key}", page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
            check(f"390px footer reachable {key}", page.locator("#apply").bounding_box()["y"] + page.locator("#apply").bounding_box()["height"] <= 844)
        page.set_viewport_size({"width": 1280, "height": 600})
        check("short window footer reachable", page.locator("#apply").bounding_box()["y"] + page.locator("#apply").bounding_box()["height"] <= 600)
        check("no browser errors", not errors)
        browser.close()
    report = {"status": "passed", "checks": checks, "browser_errors": errors, "scope": "HTML prototype only; no production or physical display validation"}
    (HERE / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {len(checks)} browser interaction and layout checks")


if __name__ == "__main__":
    main()
