"""Check six Markdown workloads against optimized Lua and time the eligible paths."""
import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
from statistics import median
import subprocess

FOLDER = Path("bench/native_markdown")
CASES = {
    "edits": "Settled edits",
    "stream": "Streaming and settling",
    "tables": "Aligned tables",
    "inline_math": "Inline math",
    "display_math": "Display fractions",
    "links": "Link hits after resize",
}

def first_difference(reference, candidate):
    if candidate["status"] != "ok":
        return candidate["reason"]
    if len(candidate["frames"]) != len(reference["frames"]):
        return "frame count differs"
    for expected, actual in zip(reference["frames"], candidate["frames"]):
        if actual["issues"]:
            return f"{actual['step']} — {actual['issues'][0]}"
        for field in ("step", "text", "highlights", "sources", "events"):
            if expected[field] != actual[field]:
                return f"{expected['step']} — {field} differs"
    return None

def run(case, mode, phase, executable, n):
    env = dict(os.environ, BENCH_CASE=case, BENCH_MODE=mode, BENCH_PHASE=phase, BENCH_N=str(n))
    for var in ("FIBROUS_NATIVE_WRAP", "FIBROUS_NATIVE_REACTIVE"):
        env.pop(var, None)
    script = "pty_links.lua" if phase == "pty" else "features.lua"
    report = subprocess.check_output(
        [executable, "--headless", "-u", "NONE", "-i", "NONE", "-l", str(FOLDER / script)],
        env=env, text=True, timeout=120,
    )
    data = json.loads(report)
    if (data["case"], data["mode"], data["n"]) != (case, mode, n):
        raise RuntimeError(f"unexpected worker result for {case}, {mode}")
    return data

def percentile(values, p):
    return sorted(values)[math.ceil(len(values) * p) - 1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--sections", type=int, default=40)
    parser.add_argument("--out", type=Path, required=True, help="Writable results directory")
    args = parser.parse_args()
    if min(args.sections, args.rounds) < 1:
        parser.error("sections and rounds must be positive")
    exe = os.getenv("NVIM_BIN", "nvim")
    problems, timings = {}, defaultdict(list)
    args.out.mkdir(exist_ok=True, parents=True)
    with (args.out / "results-features.jsonl").open("w") as log:
        def record(row):
            print(json.dumps(row, ensure_ascii=False), file=log, flush=True)
        for case, label in CASES.items():
            reference = run(case, "lua", "verify", exe, args.sections)
            record(dict(reference, phase="verify"))
            if not reference["frames"] or first_difference(reference, reference) is not None:
                raise RuntimeError(f"invalid Lua reference for {label}: {first_difference(reference, reference)}")
            native = run(case, "rust", "verify", exe, args.sections)
            problem = first_difference(reference, native)
            record(dict(native, phase="verify", difference=problem))
            if problem:
                problems[case] = (native["status"], problem)
            print(f"{label}: {problem or 'matched'}", flush=True)
        # Exercise the same click sequence through Neovim's mouse input queue in a real TUI.
        pty_lua = run("links", "lua", "pty", exe, args.sections)
        pty_rust = run("links", "rust", "pty", exe, args.sections)
        if first_difference(pty_lua, pty_lua) or len(pty_lua["frames"]) != 5:
            raise RuntimeError("invalid Lua PTY pointer reference")
        pty_issue = first_difference(pty_lua, pty_rust)
        record(dict(pty_lua, phase="pty"))
        record(dict(pty_rust, phase="pty", difference=pty_issue))
        if pty_issue:
            problems.setdefault("links", ("mismatch", pty_issue))
        print(f"PTY pointer: {pty_issue or 'matched'}", flush=True)
        for i in range(args.rounds):
            for case in CASES:
                modes = ("lua",) if case in problems else (("lua", "rust") if i % 2 == 0 else ("rust", "lua"))
                sample_counts = {}
                for mode in modes:
                    data = run(case, mode, "time", exe, args.sections)
                    if data["status"] != "ok" or not data["samples"]:
                        raise RuntimeError(f"missing timings for {case}, {mode}")
                    counts = {op: len(values) for op, values in data["samples"].items()}
                    if min(counts.values()) <= 0 or sample_counts and counts != sample_counts:
                        raise RuntimeError(f"incomplete measurements for {case}, {mode}")
                    sample_counts = counts
                    record(dict(data, phase="time", round=i + 1))
                    for op, values in data["samples"].items():
                        timings[case, mode, op].append((percentile(values, .5), percentile(values, .95)))
            print(f"Timing round {i + 1}/{args.rounds}", flush=True)
    report = ["# Markdown feature benchmarks", "",
              f"Neovim correctness checks and headless timings on {args.sections}-section documents. "
              f"Each latency is the median of {args.rounds} within-run nearest-rank percentiles. "
              "Every timing process warms up once and repeats the measured sequence four times. "
              "Successful pairs alternate execution order. Lua uses coalesced wrapping.", "",
              "| Workload | Rust outcome | First difference |", "| --- | --- | --- |"]
    for case, label in CASES.items():
        if case in problems:
            status, detail = problems[case]
            outcome = "Unsupported at setup" if status == "unsupported" else "Behavior mismatch"
        else:
            detail, outcome = "All checked frames matched", "Passed"
        report.append(f"| {label} | {outcome} | {detail} |")
    report += ["", "A second link check delivered mouse presses and releases at screen coordinates "
               "through Neovim's input queue in a real PTY. " +
               (f"The first difference was {pty_issue}." if pty_issue else "All clicks matched.")]
    report += ["", "| Workload | Operation | Lua p50 / p95 (ms) | Rust p50 / p95 (ms) |",
               "| --- | --- | ---: | ---: |"]
    for case, label in CASES.items():
        for op in ("edit", "resize", "click"):
            if (case, "lua", op) not in timings:
                continue
            cells = []
            for mode in ("lua", "rust"):
                runs = timings.get((case, mode, op))
                cells.append(" / ".join(f"{median(v):.3f}" for v in zip(*runs)) if runs else "—")
            report.append(f"| {label} | {op} | {' | '.join(cells)} |")
    report += ["", "An absent Rust timing means the case failed its behavior check or the renderer rejected its layout. "
               "Edit timings cover the public property update. Resize timings cover reflow and Neovim buffer updates. "
               "Click timings cover hit-testing and callback dispatch using a supplied pointer position. "
               "Frame validation and coordinate lookup run outside the timers.", "",
               "[Reproduction instructions](README.md) · [Raw checks and samples](results-features.jsonl)", ""]
    (args.out / "FEATURES.md").write_text("\n".join(report))
    return int(bool(problems))

if __name__ == "__main__":
    raise SystemExit(main())
