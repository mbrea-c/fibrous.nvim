# Markdown resize measurements

Neovim 0.12.3, Linux x86-64, one immutable 200-section source-mapped document. Each latency is the median of the within-run nearest-rank percentile. Eight paired rounds ran headless and three ran in a real PTY. Each pair used fresh processes.

| Width cycle | Operation | Optimized Lua p50 / p95 (ms) | Rust p50 / p95 (ms) |
| --- | --- | ---: | ---: |
| 64–100 columns | Buffer resize | 35.98 / 86.91 | 9.49 / 16.62 |
| 64–100 columns | Resize and source projection | 48.88 / 117.57 | 16.72 / 53.44 |
| 64–100 columns | Resize through terminal redraw | 51.75 / 105.27 | 12.83 / 25.77 |
| 17–62 columns | Buffer resize | 42.52 / 103.50 | 9.26 / 20.52 |
| 17–62 columns | Resize and source projection | 51.04 / 116.97 | 16.63 / 59.56 |
| 17–62 columns | Resize through terminal redraw | 55.11 / 108.30 | 14.57 / 26.48 |

## Setup and fidelity

- On the standard cycle Rust had a lower headless median in 8/8 pairs. The median extra one-time cost to prepare the retained document and its initial native frame was 65.0 ms. Both backends emitted 50,350 terminal bytes over 12 frames and produced the same text and extmark fingerprint sequence. The counted headless buffer write covered 166,336 cells for both.
- On the narrow cycle Rust had a lower headless median in 8/8 pairs. The median extra one-time cost to prepare the retained document and its initial native frame was 60.8 ms. Both backends emitted 46,726 terminal bytes over 12 frames and produced the same text and extmark fingerprint sequence. The counted headless buffer write covered 74,630 cells for both.

The setup cost is outside the warm resize timings. The two input-width cycles use the same document and start at the same width. Variation between their setup estimates reflects process timing. The terminal timer includes synchronous Neovim redraw and excludes terminal-emulator painting. The source projection workload includes one public projection per resize. The [feature benchmarks](FEATURES.md) cover document edits, tables, math and link activation.

The speedup compares a dedicated retained Markdown renderer against the general Fibrous host with optimized Lua word wrapping. The comparison includes the change in rendering architecture.

[Benchmark and reproduction instructions](README.md) · [Headless samples](results-run.jsonl) · [Terminal samples](results-term.jsonl)
