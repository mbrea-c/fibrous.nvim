# Markdown feature benchmarks

Neovim correctness checks and headless timings on 40-section documents. Each latency is the median of 8 within-run nearest-rank percentiles. Every timing process warms up once and repeats the measured sequence four times. Successful pairs alternate execution order. Lua uses coalesced wrapping.

| Workload | Rust outcome | First difference |
| --- | --- | --- |
| Settled edits | Passed | All checked frames matched |
| Streaming and settling | Passed | All checked frames matched |
| Aligned tables | Passed | All checked frames matched |
| Inline math | Passed | All checked frames matched |
| Display fractions | Passed | All checked frames matched |
| Link hits after resize | Passed | All checked frames matched |

A second link check delivered mouse presses and releases at screen coordinates through Neovim's input queue in a real PTY. All clicks matched.

| Workload | Operation | Lua p50 / p95 (ms) | Rust p50 / p95 (ms) |
| --- | --- | ---: | ---: |
| Settled edits | edit | 1.682 / 3.116 | 2.108 / 3.534 |
| Settled edits | resize | 0.835 / 2.049 | 0.873 / 1.583 |
| Streaming and settling | edit | 1.112 / 3.048 | 1.568 / 3.683 |
| Streaming and settling | resize | 0.713 / 2.216 | 0.792 / 1.785 |
| Aligned tables | resize | 3.351 / 9.432 | 0.789 / 0.974 |
| Inline math | resize | 1.547 / 2.989 | 0.410 / 0.564 |
| Display fractions | resize | 0.944 / 2.338 | 0.377 / 0.510 |
| Link hits after resize | resize | 0.765 / 2.017 | 0.251 / 0.425 |
| Link hits after resize | click | 0.015 / 0.051 | 0.015 / 0.052 |

An absent Rust timing means the case failed its behavior check or the renderer rejected its layout. Edit timings cover the public property update. Resize timings cover reflow and Neovim buffer updates. Click timings cover hit-testing and callback dispatch using a supplied pointer position. Frame validation and coordinate lookup run outside the timers.

[Reproduction instructions](README.md) · [Raw checks and samples](results-features.jsonl)
