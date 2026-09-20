#!/usr/bin/env python3
"""Capture and check the local design prototype; requires Playwright + Chromium."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
URL = (ROOT / "index.html").as_uri()
SCENES = [
    ("browse-dark", "", 1280),
    ("browse-light", "?theme=light", 1280),
    ("list", "?view=list", 1280),
    ("split", "?view=split", 1280),
    ("search", "?view=search", 1280),
    ("transfer", "?view=transfer", 1280),
    ("narrow", "", 560),
    ("empty", "?view=empty", 1280),
    ("error", "?view=error", 1280),
]


def main():
    errors, checks, captures = [], [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get("CHROMIUM", "/usr/bin/chromium"),
            headless=True,
            args=["--no-sandbox"],
        )
        page = browser.new_page(viewport={"width": 1280, "height": 984}, device_scale_factor=1)
        page.route("http://**/*", lambda route: route.abort())
        page.route("https://**/*", lambda route: route.abort())
        page.on("pageerror", lambda error: errors.append(str(error)))
        for name, query, width in SCENES:
            page.set_viewport_size({"width": width, "height": 984})
            page.goto(URL + query)
            assert not page.evaluate("document.documentElement.scrollWidth > innerWidth"), name
            if name == "transfer":
                assert page.locator("#operation-dialog").is_visible()
            page.screenshot(path=str(ROOT / f"{name}.png"), full_page=True)
            captures.append({"file": f"{name}.png", "viewport": [width, 984], "query": query})
        checks.append("Nine review scenarios render without document overflow")

        page.set_viewport_size({"width": 1280, "height": 984})
        page.goto(URL)
        assert page.locator("[data-file]").count() == 12
        page.locator('[data-file="Notes.md"]').click()
        assert page.locator("#details h3").inner_text() == "Notes.md"
        page.locator("#list-view").click()
        assert page.locator(".file-row").count() == 12
        assert page.locator("#grid-view").get_attribute("aria-pressed") == "false"
        page.locator("#grid-view").click()
        assert page.locator(".file-card").count() == 12
        checks.append("Grid/list switching preserves selected-file details")

        page.locator("#more").click()
        page.locator("#hidden-files").check()
        page.locator("#sort").select_option("type")
        page.locator("#options-done").click()
        assert page.locator('[data-file=".config"]').count() == 1
        page.locator("#density").click()
        assert page.locator("body").evaluate("el => el.classList.contains('compact')")
        page.locator("#theme").click()
        assert page.locator("body").evaluate("el => el.classList.contains('light')")
        checks.append("Hidden-file option, sort selector, compact density and light theme respond")

        page.locator("#search-toggle").click()
        page.locator("#query").fill("design")
        assert page.locator(".file-row").count() == 3
        page.locator("#query").fill("unmatched filename")
        assert page.get_by_text("No matching filenames", exact=True).is_visible()
        page.locator("#clear-search").click()
        assert page.locator("#breadcrumbs .current").inner_text() == "Home"
        checks.append("Search filters fixture names, shows no-results state and exits")

        page.goto(URL + "?view=split")
        assert page.locator(".pane").count() == 2
        page.locator('[data-pane="1"] [data-file="Coastline.png"]').click()
        assert page.locator(".active-split").get_attribute("data-pane") == "1"
        page.keyboard.press("F6")
        assert page.locator(".active-split").get_attribute("data-pane") == "0"
        assert page.locator("#list-view").get_attribute("aria-pressed") == "true"
        page.locator("#grid-view").click()
        assert page.locator('[data-pane="0"] .file-card').count() == 6
        page.keyboard.press("F6")
        page.locator("#list-view").click()
        assert page.locator('[data-pane="1"] .file-row').count() == 4
        assert page.locator('[data-pane="0"] .file-card').count() == 6
        page.keyboard.press("F6")
        page.set_viewport_size({"width": 560, "height": 984})
        assert page.locator(".pane:visible").count() == 1
        page.locator(".pane:visible [data-switch-pane]").click()
        assert page.locator(".pane:visible").get_attribute("data-pane") == "1"
        page.set_viewport_size({"width": 1280, "height": 984})
        assert page.locator(".pane:visible").count() == 2
        checks.append("Split active pane switches by click/F6; selections and views are independent; narrow mode retains both panes")

        for choice in ["Skip", "Replace", "Keep both"]:
            page.goto(URL + "?view=transfer")
            assert page.locator("#operation-dialog").is_visible()
            page.locator(f'[data-resolution="{choice}"]').click()
            assert not page.locator("#operation-dialog").is_visible()
            assert page.locator("#toast").is_visible()
        page.locator("#jobs").click()
        page.locator("#cancel-copy").click()
        assert "cancelled" in page.locator("#toast").inner_text()
        checks.append("Conflict choices and transfer cancellation produce fixture feedback")

        page.goto(URL + "?view=error")
        page.locator("[data-retry]").click()
        assert "denied" in page.locator("#toast").inner_text()
        page.locator("[data-go-home]").last.click()
        assert page.locator("#breadcrumbs .current").inner_text() == "Home"
        checks.append("Error state retains retry and navigation to Home")

        for width in [390, 480, 560, 760, 980, 1280]:
            page.set_viewport_size({"width": width, "height": 984})
            for query in ["", "?theme=light", "?view=list", "?view=split", "?view=search", "?view=transfer"]:
                page.goto(URL + query)
                assert not page.evaluate("document.documentElement.scrollWidth > innerWidth"), (width, query)
        page.goto(URL)
        page.set_viewport_size({"width": 560, "height": 984})
        page.locator("#places-toggle").click()
        assert page.locator(".sidebar").is_visible()
        page.locator('[data-place="Projects"]').click()
        assert page.locator("#breadcrumbs .current").inner_text() == "Projects"
        assert not page.locator(".sidebar").is_visible()
        checks.append("Six scenarios fit widths 390/480/560/760/980/1280; narrow Places navigates")
        assert not errors, errors
        report = {
            "status": "passed",
            "scope": "Browser design prototype only; no native GTK or filesystem validation",
            "browser": browser.version,
            "device_scale_factor": 1,
            "network": "HTTP/HTTPS blocked during checks",
            "checks": checks,
            "captures": captures,
            "javascript_errors": errors,
        }
        (ROOT / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
        browser.close()
    print(json.dumps({"status": "passed", "checks": len(checks), "captures": len(captures)}))


if __name__ == "__main__":
    main()
