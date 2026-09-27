#!/usr/bin/env python3
"""Native GTK interaction checks using only temporary files/display/D-Bus."""
import argparse
import configparser
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
            launch_count = 0
            config = Path(s.env["XDG_CONFIG_HOME"]) / "phyto/preferences.ini"

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

            def launch(width=1180, height=760, *flags, keep_preferences=False):
                nonlocal app, launch_count
                if not keep_preferences:
                    config.unlink(missing_ok=True)
                rules.write_text(f'[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = {width}\nheight = {height}\n')
                time.sleep(.3)
                ipc.call("command", action="session.reload", fields={})
                app = s.child(f"phyto-{launch_count}", [binary, f"--width={width}", f"--height={height}", *flags], G_DEBUG="fatal-warnings")
                launch_count += 1
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

            # Persistence cases deliberately reuse one configuration across full
            # process exits; visual cases above each start with fresh defaults.
            def assert_view(list_mode, hidden):
                v = settled()
                assert (v["list"], v["hidden"]) == (list_mode, hidden), v
                assert v["view_child"] == ("list" if list_mode else "grid"), v
                return v

            def saved():
                values = configparser.ConfigParser(interpolation=None)
                values.read(config)
                return values

            def assert_saved(list_mode, hidden):
                values = saved()
                assert values["View"]["mode"] == ("list" if list_mode else "grid")
                assert values.getboolean("View", "show-hidden") == hidden

            launch()
            assert_view(False, False)
            assert not config.exists()  # reading defaults must not write
            close()
            config.parent.mkdir(parents=True, exist_ok=True)
            legacy = ("[View]\nsort=size\nreverse=true\nfolders-first=false\n"
                      "[Previews]\nthumbnails=false\ndetails=false\nmax-mib=7\n"
                      "[Menus]\nadvanced=true\npermanent-delete=true\n"
                      f"[Files]\nbookmarks={(home / 'Documents').as_uri()};\n"
                      "[Future]\nkeep=untouched\n")
            config.write_text(legacy)
            launch(keep_preferences=True)
            assert_view(False, False)
            assert config.read_text() == legacy
            close()
            for mode, hidden, expected in [("invalid", "true", (False, True)),
                                           ("list", "invalid", (True, False))]:
                contents = f"[View]\nmode={mode}\nshow-hidden={hidden}\n"
                config.write_text(contents)
                launch(keep_preferences=True)
                assert_view(*expected)
                assert config.read_text() == contents
                close()
            passed("Missing, legacy and invalid preferences restore independent defaults without writing")

            config.write_text(legacy)
            launch(keep_preferences=True)
            # This folder has exactly two entries, so filtering is verified
            # independently of desktop services creating files in HOME.
            fixture = home / "View preferences"
            fixture.mkdir()
            (fixture / "visible.txt").write_text("visible")
            (fixture / ".hidden.txt").write_text("hidden")
            for list_mode, hidden in [(True, True), (False, True), (True, False), (False, False)]:
                navigate(fixture)
                key("2" if list_mode else "1", "ctrl")
                if probe()["hidden"] != hidden:
                    key("h", "ctrl")
                assert assert_view(list_mode, hidden)["count"] == (2 if hidden else 1)
                assert_saved(list_mode, hidden)
                values = saved()
                assert values["View"]["sort"] == "size" and values.getboolean("View", "reverse")
                assert not values.getboolean("View", "folders-first")
                assert not values.getboolean("Previews", "thumbnails")
                assert not values.getboolean("Previews", "details")
                assert values["Previews"]["max-mib"] == "7"
                assert values.getboolean("Menus", "advanced") and values.getboolean("Menus", "permanent-delete")
                assert values["Files"]["bookmarks"] == (home / "Documents").as_uri() + ";"
                assert values["Future"]["keep"] == "untouched"
                close()
                launch(keep_preferences=True)
                assert_view(list_mode, hidden)
                navigate(fixture)
                assert assert_view(list_mode, hidden)["count"] == (2 if hidden else 1)
            passed("All four view/hidden combinations survive process restarts and preserve unrelated preferences")

            # The original tab and pre-created second pane retain grid/hidden-off.
            key("t", "ctrl")
            key("2", "ctrl"); key("h", "ctrl")
            key("t", "ctrl")
            assert_view(True, True)
            key("w", "ctrl"); key("w", "ctrl")
            assert_view(False, False)
            assert_saved(True, True)
            before = config.stat().st_mtime_ns
            navigate(home); key("F5")
            key("F3"); key("F6")
            assert_view(False, False)
            key("F6"); key("F3")
            assert config.stat().st_mtime_ns == before
            # Reaffirming the current view must replace another tab's default.
            key("1", "ctrl")
            assert_saved(False, True)
            before = config.stat().st_mtime_ns
            key("1", "ctrl")
            assert config.stat().st_mtime_ns == before

            original = windows()[0]["id"]
            key("n", "ctrl")
            new = wait_for(lambda: next((w for w in windows() if w["id"] != original), None))
            ipc.call("command", action="window.activate", fields={"id": new["id"]})
            assert_view(False, True)
            key("2", "ctrl")
            key("w", "ctrl")
            wait_for(lambda: len(windows()) == 1)
            ipc.call("command", action="window.activate", fields={"id": original})
            assert_view(False, False)
            assert_saved(True, True)
            close()
            launch(keep_preferences=True)
            assert_view(True, True)
            passed("New tabs/windows inherit defaults; existing tabs/panes and close order preserve the last explicit choices")

            config.unlink()
            config.mkdir()
            key("1", "ctrl")
            wait_for(lambda: any(w.get("title") == "Preferences were not saved" for w in ipc.state()))
            key("Escape")
            wait_for(lambda: not any(w.get("title") == "Preferences were not saved" for w in ipc.state()))
            assert_view(False, True)
            assert probe()["preferences_save_error"]
            config.rmdir()
            key("1", "ctrl")  # retry even though the in-memory value matches
            assert_saved(False, True)
            assert not probe()["preferences_save_error"]
            close()
            launch(keep_preferences=True)
            assert_view(False, True)
            close()
            passed("Save failure is visible, preserves usable state, and retries successfully")
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
