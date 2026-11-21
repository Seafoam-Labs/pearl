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


def completion_requests(path):
    """Check real prompt accounting and return only inference requests."""
    requests = [json.loads(line) for line in path.read_text().splitlines()]
    completions, template, tokenized = [], None, False
    for request in requests:
        payload = request["payload"]
        if request["path"] == "/apply-template":
            template, tokenized = payload, False
        elif request["path"] == "/tokenize":
            if payload["content"] == "Pearl local compatibility check":
                assert template is None, request
                continue
            assert template is not None, request
            assert json.loads(payload["content"]) == {"messages": template["messages"], "tools": template.get("tools")}
            tokenized = True
        else:
            assert request["path"] == "/v1/chat/completions", request
            if len(completions) >= 3:
                assert template is not None, ("inference skipped prompt accounting", request)
            if template is not None:
                assert tokenized, request
                assert payload["messages"] == template["messages"], request
                assert payload.get("tools") == template.get("tools"), request
                template, tokenized = None, False
            completions.append(payload)
    return completions


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

        for scenario in ["benchmark_ok", "benchmark_direct", "benchmark_repair"]:
            report, _ = run(scenario)
            result = report["results"][0]
            assert result["complete"] and not result["error_code"], result
            assert len(result["samples"]) == 16
            assert all(s["outcome"] == "answer" for s in result["samples"]), result
            assert sum(not s["warmup"] for s in result["samples"]) == 12
            assert all(s["tokens"]["reasoning"] > 0 and "Internal test" not in s["answer"] for s in result["samples"])
            assert result["peak_rss_kib"] > 0 and result["verification_ms"] > 0
            assert all(s["first_visible_ms"] is not None and s["first_visible_ms"] <= s["complete_ms"] for s in result["samples"])
            requests = completion_requests(root / (scenario + ".requests.jsonl"))
            # Qualification itself never dispatches a host search.
            assert not requests[0].get("tools") and requests[1].get("tools")
            assert not requests[2].get("tools") and requests[2]["messages"][-1]["role"] == "tool"
            measured = requests[3:]
            expected = 16 if scenario == "benchmark_direct" else 32 if scenario == "benchmark_repair" else 24
            assert len(measured) == expected, (scenario, measured)
            assert all(r["messages"][0]["role"] == "system" and r["messages"][0]["content"].startswith("You are Pearl, a helpful conversational assistant.") for r in measured)
            assert all(sum(m["role"] == "system" for m in r["messages"]) == 1 for r in measured)
            assert all(m["role"] == "user" for r in measured for m in r["messages"] if m.get("content", "").startswith("Previous search evidence"))
            if scenario == "benchmark_direct":
                assert all(s["searches"] == 0 and s["reads"] == 0 and "[1]" not in s["answer"] for s in result["samples"]), result
                checks["direct_answers_do_not_force_search_or_citations"] = True
            else:
                assert all(s["searches"] == (0 if s["followup"] else 1) for s in result["samples"]), result
                assert all("[1]" not in s["answer"] for s in result["samples"] if s["followup"]), result
                assert all("[1]" in s["answer"] for s in result["samples"] if not s["followup"]), result
                if scenario == "benchmark_repair":
                    assert sum(not r.get("tools") for r in measured) == 8, measured
                checks["prior_evidence_does_not_force_followup_search_or_citations"] = True
            checks["template_and_completion_messages_and_tools_match"] = True
            checks[scenario] = True
        for scenario, outcome in [("benchmark_invalid", "results_only"), ("benchmark_truncated", "truncated")]:
            report, _ = run(scenario)
            result = report["results"][0]
            assert result["samples"] and all(s["outcome"] == outcome for s in result["samples"]), report
            requests = completion_requests(root / (scenario + ".requests.jsonl"))[3:]
            if scenario == "benchmark_invalid":
                assert len(result["samples"]) == 8 and len(requests) == 24, report
                assert sum(not r.get("tools") for r in requests) == 8, requests
                assert all("[99]" not in s["answer"] for s in result["samples"]), report
            else:
                assert all(s["error_code"] == "GenerationTruncated" for s in result["samples"]), report
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
