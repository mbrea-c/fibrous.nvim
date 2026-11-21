"""Regenerate RESULTS.md from the paired headless and PTY JSONL files."""
from collections import defaultdict
import json
import math
from pathlib import Path
from statistics import median

folder = Path(__file__).resolve().parent

def load(kind):
    by_mode = defaultdict(list)
    for line in (folder / f"results-{kind}.jsonl").read_text().splitlines():
        row = json.loads(line)
        by_mode[row["narrow"], row["mode"]].append(row)
    return by_mode

def percentile(values, p):
    return sorted(values)[math.ceil(p * len(values)) - 1]

def aggregate(rows, field="samples", p=0.5):
    return median(percentile(row[field], p) for row in rows)

headless, tui = load("run"), load("term")
assert all(len(v) == 8 for v in headless.values()) and len(headless) == 4
assert all(len(v) == 3 for v in tui.values()) and len(tui) == 4

report = [
    "# Markdown resize measurements", "",
    "Neovim 0.12.3, Linux x86-64, one immutable 200-section source-mapped document. "
    "Each latency is the median of the within-run nearest-rank percentile. "
    "Eight paired rounds ran headless and three ran in a real PTY. Each pair used fresh processes.", "",
    "| Width cycle | Operation | Optimized Lua p50 / p95 (ms) | Rust p50 / p95 (ms) |",
    "| --- | --- | ---: | ---: |",
]
for narrow in (False, True):
    label = "17–62 columns" if narrow else "64–100 columns"
    for group, field, op in [(headless, "samples", "Buffer resize"),
                             (headless, "query_samples", "Resize and source projection"),
                             (tui, "samples", "Resize through terminal redraw")]:
        columns = [f"{aggregate(group[narrow, mode],field):.2f} / "
                   f"{aggregate(group[narrow, mode],field,0.95):.2f}" for mode in ("lua", "rust")]
        report.append(f"| {label} | {op} | {' | '.join(columns)} |")
report.extend(["", "## Setup and fidelity", ""])
for narrow in (False, True):
    name = "narrow" if narrow else "standard"
    l, r = headless[narrow, "lua"], headless[narrow, "rust"]
    assert [x["round"] for x in r] == [x["round"] for x in l]
    wins = sum(percentile(a["samples"],.5) < percentile(b["samples"],.5) for a,b in zip(r,l))
    extra = median(x["setup"] for x in r)
    lt, rt = tui[narrow,"lua"], tui[narrow,"rust"]
    assert len({x["bytes"] for x in lt+rt}) == len({x["fingerprint"] for x in lt+rt}) == 1
    assert len({x["fingerprint"] for x in l+r}) == len({x["cells"] for x in l+r}) == len({x["writes"] for x in l+r}) == 1
    report.append(f"- On the {name} cycle Rust had a lower headless median in {wins}/8 pairs. "
                  f"The median extra one-time cost to prepare the retained document and its initial native frame was {extra:.1f} ms. "
                  f"Both backends emitted {lt[0]['bytes']:,} terminal bytes over 12 frames and produced the same "
                  f"text and extmark fingerprint sequence. The counted headless buffer write covered {l[0]['cells']:,} cells for both.")
report.extend(["", "The setup cost is outside the warm resize timings. The two input-width cycles use the same document and start at the same width. "
    "Variation between their setup estimates reflects process timing. The terminal timer includes synchronous Neovim redraw and excludes terminal-emulator painting. "
    "The source projection workload includes one public projection per resize. The [feature benchmarks](FEATURES.md) cover document edits, tables, math and link activation.", "",
    "The speedup compares a dedicated retained Markdown renderer against the general Fibrous host with optimized Lua word wrapping. "
    "The comparison includes the change in rendering architecture.", "",
    "[Benchmark and reproduction instructions](README.md) · [Headless samples](results-run.jsonl) · [Terminal samples](results-term.jsonl)", ""])
(folder / "RESULTS.md").write_text("\n".join(report))
