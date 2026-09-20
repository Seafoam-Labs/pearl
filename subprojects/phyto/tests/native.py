#!/usr/bin/env python3
"""Native GTK interaction checks using only temporary files/display/D-Bus."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / "scripts"), str(PEARL / "tests/integration")]
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=PROJECT / "artifacts/native")
    parser.add_argument("--aqueous-prefix", type=Path, default=PEARL / ".cache/aqueous-activity-production")
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks, captures = [], []
    report = {"status": "running", "checks": checks, "captures": captures,
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "scope": "Native design and local browsing/action slice; not full Nemo parity"}

    def passed(name):
        checks.append(name)
        print("PASS", name, flush=True)

    try:
        with PrivateSession(output / "session", tool_prefix=args.aqueous_prefix) as s:
            s.env["GSETTINGS_BACKEND"] = "memory"
            ipc = IPC(s)
            display = next(iter(ipc.outputs().values()))
            s.run(["wlr-randr", "--output", display["name"], "--custom-mode", "1600x1100@60Hz"])
            rules = Path(s.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
            home = Path(s.env["HOME"])
            for name in ["Documents", "Downloads", "Music", "Pictures", "Projects", "Videos"]:
                (home / name).mkdir()
            for name in ["Design system.fig", "Coastline.png", "Notes.md", "Release brief.pdf", "Palette.svg", "Welcome.txt"]:
                (home / name).write_text("Native Phyto test fixture\n")
            (home / ".hidden").write_text("hidden\n")
            (home / "Documents/Notes.md").write_text("Keep this document intact.\n")
            source_bytes = (home / "Documents/Notes.md").read_bytes()
            app = None

            def windows():
                return [w for w in ipc.state() if w["kind"] == "window" and w.get("app_id") == "org.aqueous.Phyto"]

            def key(name, *modifiers):
                cmd = ["wtype", "-s", "100"]
                for mod in modifiers:
                    cmd += ["-M", mod]
                cmd += ["-k", name]
                for mod in reversed(modifiers):
                    cmd += ["-m", mod]
                s.run(cmd)

            def text(value):
                s.run(["wtype", "-s", "100", "--", str(value)])

            def probe():
                assert app.proc.poll() is None, app.lines[-20:]
                start = len(app.lines)
                key("F12")
                line = wait_for(lambda: next((l for l in app.lines[start:] if l.startswith("PHYTO_PROBE ")), None))
                return json.loads(line.removeprefix("PHYTO_PROBE "))

            def settled():
                return wait_for(lambda: (v if not (v := probe())["loading"] else False))

            def navigate(path):
                key("l", "ctrl")
                text(path)
                key("Return")
                return settled()

            def capture(name):
                time.sleep(.15)
                rect = windows()[0]["geometry"]
                path = output / f"{name}.png"
                s.run(["grim", "-g", f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}", path])
                captures.append({"file": path.name, "geometry": rect, "state": probe()})

            def launch(width=1180, height=760, *flags):
                nonlocal app
                rules.write_text(f'[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = {width}\nheight = {height}\n')
                time.sleep(.3)
                ipc.call("command", action="session.reload", fields={})
                app = s.child(f"phyto-{len(captures)}", [binary, f"--width={width}", f"--height={height}", *flags], G_DEBUG="fatal-warnings")
                win = wait_for(lambda: next(iter(windows()), None))
                ipc.call("command", action="window.activate", fields={"id": win["id"]})
                return settled()

            def close():
                key("w", "ctrl")
                assert app.wait(timeout=5) == 0, app.lines[-20:]
                assert not any(word in line for line in app.lines for word in ["WARNING", "CRITICAL", "panic:"]), app.lines[-20:]
                wait_for(lambda: not windows())

            assert launch()["count"] == 12
            navigate(home)
            key("End")
            assert probe()["selected"] == 1
            capture("browse-dark")
            key("2", "ctrl")
            assert probe()["list"]
            capture("list")
            key("1", "ctrl")
            key("h", "ctrl")
            assert settled()["count"] == 13
            key("h", "ctrl")
            passed("Asynchronous real directory enumeration, selection, grid/list and hidden files")

            key("f", "ctrl")
            text("notes")
            wait_for(lambda: probe()["count"] == 1)
            assert probe()["query"] == "notes"
            capture("search")
            key("a", "ctrl")
            text("unmatched-name")
            wait_for(lambda: probe()["count"] == 0)
            key("Escape")
            assert settled()["count"] == 12
            passed("Current-folder filename filtering, no-results state and Escape recovery")

            key("t", "ctrl")
            assert probe()["tabs"] == [2, 1]
            navigate(home / "Projects")
            assert probe()["count"] == 0
            capture("empty")
            key("Tab", "ctrl")
            assert probe()["title"] == "Home"
            key("Tab", "ctrl")
            key("w", "ctrl")
            assert probe()["tabs"] == [1, 1]
            key("F3")
            key("F6")
            navigate(home / "Downloads")
            key("2", "ctrl")
            assert probe()["active"] == 1 and probe()["list"]
            key("F6")
            assert probe()["title"] == "Home" and not probe()["list"]
            capture("split")
            key("F3")
            passed("Independent tab locations and pane views; split switching and tab close")

            navigate(home / "does-not-exist")
            assert probe()["failed"]
            capture("error")
            key("Left", "alt")
            assert settled()["title"] == "Home"
            passed("Missing-location error retains history and Back recovery")

            navigate(home / "Documents")
            key("Home")
            assert probe()["selected_name"] == "Notes.md"
            key("c", "ctrl")
            navigate(home / "Downloads")
            key("v", "ctrl")
            wait_for(lambda: (home / "Downloads/Notes.md").exists())
            assert (home / "Downloads/Notes.md").read_bytes() == source_bytes
            assert (home / "Documents/Notes.md").read_bytes() == source_bytes
            key("v", "ctrl")
            # A modal conflict gets keyboard focus; default Skip is deliberately safe.
            time.sleep(.4)
            rect = windows()[-1]["geometry"]
            s.run(["grim", "-o", display["name"], output / "conflict.png"])
            key("Return")
            assert not probe()["busy"]
            assert (home / "Downloads/Notes.md").read_bytes() == source_bytes
            passed("Single-file copy preserves source bytes; name collision skips without overwrite")

            key("n", "ctrl", "shift")
            text("New fixture")
            key("Return")
            wait_for(lambda: (home / "Downloads/New fixture").is_dir())
            navigate(home / "Downloads/New fixture")
            assert settled()["count"] == 0
            navigate(home / "Documents")
            key("Home")
            key("F2")
            key("a", "ctrl")
            text("Renamed.md")
            key("Return")
            wait_for(lambda: (home / "Documents/Renamed.md").exists())
            assert (home / "Documents/Renamed.md").read_bytes() == source_bytes
            passed("Native create-folder and rename dialogs mutate only the selected fixture")

            large = home / "Large"
            large.mkdir()
            for index in range(10000):
                (large / f"entry-{index:05}.txt").touch()
            v = navigate(large)
            assert v["count"] == 10000, v
            assert v["realized_grid_children"] < 1000, v
            report["large_directory"] = {"entries": 10000, "realized_grid_children": v["realized_grid_children"]}
            for path in [home / "Documents", large, home / "Pictures", large, home]:
                key("l", "ctrl"); text(path); key("Return")
            assert settled()["count"] == 13  # includes the new Large directory
            passed("10,000-entry directory uses recycled rows; rapid navigation settles on the final location")
            close()
            passed("Window closes cleanly with G_DEBUG=fatal-warnings")

            launch(1180, 760, "--light")
            navigate(home); key("End"); capture("browse-light"); close()
            launch(1180, 760, "--compact")
            key("2", "ctrl"); capture("compact"); close()
            launch(1180, 760, "--native-theme")
            capture("native-theme"); close()
            launch(560, 760)
            v = probe()
            assert not v["sidebar"] and not v["details"], v
            capture("narrow")
            key("F3"); key("F6")
            v = probe()
            assert not v["left_visible"] and v["right_visible"]
            key("F6")
            v = probe()
            assert v["left_visible"] and not v["right_visible"]
            key("F3"); close()
            passed("Light, compact and system-theme windows; narrow layout retains both split panes")
            ipc.close()
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {len(checks)} native check groups; {len(captures)} captures", flush=True)


if __name__ == "__main__":
    main()
