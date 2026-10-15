#!/usr/bin/env python3
"""Exercise the Zig benchmark with local runtime fixtures and isolated state."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, default=ROOT / "zig-out/test/pearl-benchmark-check")
    parser.add_argument("--model", type=Path, required=True, help="Existing managed 350M Q4_K_M GGUF")
    parser.add_argument("--output", type=Path, default=Path("/tmp/pearl-benchmark-check"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    with tempfile.TemporaryDirectory(prefix="pearl-bench-") as temporary:
        root = Path(temporary)
        env = os.environ | {"XDG_DATA_HOME": str(root / "data"), "XDG_STATE_HOME": str(root / "state"), "XDG_RUNTIME_DIR": str(root / "runtime")}
        Path(env["XDG_RUNTIME_DIR"]).mkdir(mode=0o700)
        models = Path(env["XDG_DATA_HOME"]) / "pearl/assistant/models"
        models.mkdir(parents=True)
        model = models / "LFM2.5-350M-Q4_K_M.gguf"
        try:
            os.link(args.model.resolve(), model)
        except OSError:
            shutil.copyfile(args.model, model)

        def run(scenario, mode="cpu", cancel_ms=0, selected=None, skip_ms=0):
            runtime = root / scenario
            shutil.copyfile(ROOT / "tests/integration/fake_llama_server.py", runtime)
            runtime.chmod(0o755)
            config = {"runtime": {"source": "custom", "executable": str(runtime)}}
            options = {"selected": selected or [True, False, False, False, False], "mode": mode}
            input_path = root / "input.json"
            input_path.write_text(json.dumps(dict(config=config, options=options, cancel_after_ms=cancel_ms, skip_after_ms=skip_ms)))
            started = time.monotonic()
            process = subprocess.run([args.driver.resolve(), input_path], env=env, text=True, capture_output=True, timeout=45)
            assert process.returncode == 0, (scenario, process.stderr)
            report = json.loads(process.stdout)
            (args.output / (scenario + ".json")).write_text(json.dumps(report, indent=2))
            disk = json.loads((Path(env["XDG_STATE_HOME"]) / "pearl/assistant/benchmarks" / (report["id"] + ".json")).read_text())
            assert disk == report, (scenario, "atomic checkpoint differs")
            # Teardown must release the same lock used by ordinary chat.
            with (Path(env["XDG_RUNTIME_DIR"]) / "pearl-assistant-runtime.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert not list(Path(env["XDG_RUNTIME_DIR"]).glob("pearl-agent-key-*"))
            return report, time.monotonic() - started

        for scenario in ["benchmark_ok", "benchmark_fallback", "benchmark_repair"]:
            report, _ = run(scenario)
            result = report["results"][0]
            assert result["complete"] and not result["error_code"], result
            assert len(result["samples"]) == 16
            assert all(s["outcome"] == "answer" for s in result["samples"]), result
            assert sum(not s["warmup"] for s in result["samples"]) == 12
            assert all(s["tokens"]["reasoning"] > 0 and "Internal test" not in s["answer"] for s in result["samples"])
            assert result["peak_rss_kib"] > 0 and result["verification_ms"] > 0
            assert all(s["first_visible_ms"] <= s["complete_ms"] for s in result["samples"])
            checks[scenario] = True
        for scenario, outcome in [("benchmark_invalid", "results_only"), ("benchmark_truncated", "truncated")]:
            report, _ = run(scenario)
            assert any(s["outcome"] == outcome for s in report["results"][0]["samples"]), report
            checks[scenario] = True
        report, _ = run("benchmark_startup_fail", mode="cpu_gpu")
        assert len(report["results"]) == 3
        assert all(s["gpu"] is False for r in report["results"] for s in r["samples"])
        assert any(s["fallback"] for r in report["results"][1:] for s in r["samples"])
        checks["gpu_fallback_labeled_cpu"] = True
        report, _ = run("benchmark_mid_fail", mode="cpu_gpu")
        assert any(s["fallback"] for r in report["results"] for s in r["samples"])
        checks["mid_answer_gpu_recovery"] = True
        report, elapsed = run("benchmark_delayed_answer", cancel_ms=1500)
        assert report["state"] == "cancelled" and elapsed < 5, (report, elapsed)
        checks["cancel_releases_runtime_and_saves"] = True
        report, elapsed = run("benchmark_slow_probe", cancel_ms=300)
        assert report["state"] == "cancelled" and elapsed < 3
        checks["probe_cancellation_saved"] = True
        report, elapsed = run("benchmark_delayed_answer_skip", skip_ms=1500)
        assert report["state"] == "complete" and report["results"][0]["error_code"] == "BenchmarkSkipped" and elapsed < 5, report
        checks["skip_releases_current_runtime"] = True
        report, _ = run("benchmark_missing", selected=[True, False, True, False, False])
        assert report["results"][0]["error_code"] == "RuntimeCapabilityMissing"
        assert report["results"][1]["error_code"] == "ModelNotInstalled"
        checks["failures_continue_and_persist"] = True
        report, _ = run("benchmark_continues", selected=[True, False, True, False, False])
        assert len(report["results"][0]["samples"]) == 16 and report["results"][1]["error_code"] == "ModelNotInstalled"
        checks["completed_result_survives_later_failure"] = True
        # Replace only the private hardlink, never modify the caller's model.
        model.unlink()
        model.write_bytes(b"GGUF" + bytes(12))
        report, _ = run("benchmark_checksum")
        assert report["results"][0]["error_code"] == "ModelChecksumMismatch"
        checks["checksum_failure_recorded"] = True
        checks["history_retained"] = len(list((Path(env["XDG_STATE_HOME"]) / "pearl/assistant/benchmarks").glob("*.json"))) >= 10
    (args.output / "report.json").write_text(json.dumps({"status": "passed", "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
