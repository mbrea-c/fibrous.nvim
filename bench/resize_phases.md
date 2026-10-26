# Resize phase measurements

These measurements describe the pre-removal candidate with the word-token cache.
That cache was subsequently rejected and removed; see
[word_cache_removal.md](word_cache_removal.md). The profiling commands still work
against the current library, but the historical breakdown below is not a fresh
profile of the simplified implementation.

## Scope and method

This is diagnostic instrumentation, not another rendering optimization. The
production `lua/` tree at that stage was byte-identical to the pre-instrumentation snapshot
`/nix/store/apfkrmrh56k0y6vvxqkiq6h7hs0ahz52-source`. No normal UI timers, public
profiling API, compositor rewrite or viewport virtualization were added.

The fixed benchmark harness/library source is
`/nix/store/zmplwz6ivhddj039g125d9w3mzips59f-source`, running Neovim 0.12.3.
Scenes use 200 sections/entries, with the same widths as the resize experiment.
Eight sequential repetitions alternate plain-first and profiled-first order.
Each CPU case warms up 12 frames, then measures 24 frames on a fresh root per
mode. PTY cases use 12 frames with and without profiling, alternating run order.
No other tests or benchmarks ran concurrently with these measurements.

Timers are installed only during each profiled frame and are restored even
after errors. Hook installation/restoration is outside the timed interval.
Nested timings are exclusive, including nested same-phase calls; no cell or
word functions are individually instrumented. Wrapped row extraction and
buffer API calls still add clock/wrapper overhead and can affect GC.

Phase means below are arithmetic means of the eight batch means, in ms/frame.
They add to the instrumented total, subject to rounding. They are not estimates
of what every phase would cost without instrumentation, and phase p95s must
not be added. Every report also records the slowest frame's actual breakdown.

## Headless phase breakdown

| Phase | Mapped Markdown | Mixed columns/containers | Clamped text |
| --- | ---: | ---: | ---: |
| Layout, wrapping and source attribution | 19.351 | 3.481 | 0.995 |
| Canvas allocation/growth | 3.552 | 1.040 | 0.690 |
| Painting | 5.715 | 1.898 | 0.897 |
| Text extraction | 0.988 | 0.290 | 0.239 |
| Highlight extraction | 1.536 | 0.850 | 0.259 |
| Buffer text APIs | 0.396 | 0.167 | 0.105 |
| Buffer highlight APIs | 2.569 | 1.876 | 0.283 |
| Source updates/listeners | 0.001 | 0.002 | 0.000 |
| Other/uninstrumented | 2.256 | 0.937 | 0.219 |
| Instrumented total | 36.364 | 10.540 | 3.688 |

For the large mapped Markdown scene, layout/wrapping/source attribution is
53.2% of instrumented wall time. Canvas allocation plus painting is
25.5%. Text buffer writes alone are about 0.4 ms.

`layout` includes wrapped-run provenance work. `sources` measures
`sources.update` and listeners, not all source mapping; these scenes have no
annotation listeners requesting lazy source queries. `other` includes unwrapped
build, grouping, splice comparison, bookkeeping and timer overhead. GC pauses
are charged where they happen, not necessarily where the collected objects
were allocated. The slowest frames do not all have the same dominant phase.

## Instrumentation disturbance

| CPU scene | Unprofiled mean | Instrumented mean | Signed difference |
| --- | ---: | ---: | ---: |
| markdown | 34.226 | 36.364 | +2.138 |
| mixed | 10.206 | 10.540 | +0.334 |
| clamped | 3.462 | 3.688 | +0.225 |

For Markdown, the mean paired difference is +2.138 ms; the median paired
difference is +1.305 ms, with MAD 1.238 ms.
The difference includes sampling variation, not just timer costs. The small
height-only scene measures 0.857 ms unprofiled and
0.967 ms instrumented, so relative disturbance matters more there.
Use the ordinary, unprofiled benchmarks to accept or reject future optimizations.

## Real terminal check

| PTY scene | Synchronous Neovim redraw, ms/frame | Bytes/frame, identical |
| --- | ---: | ---: |
| markdown | 0.186 | 4190.750 |
| mixed | 0.287 | 6986.500 |
| clamped | 0.135 | 2922.833 |

These redraw timings exclude terminal-emulator painting, input delivery and
the harness's quiescence wait. They do not measure GPU/display latency. All 16
PTY runs completed all 12 frames and matched text/highlight fingerprints and
terminal byte counts within each scene, across both profiling modes.

All eight CPU comparisons also matched full target-tree fingerprints and
buffer-write counts, including nested container buffers. Raw results, with
per-phase statistics and slowest-frame attribution, are in
`/tmp/fibrous-phase-samples-818.jsonl` (24 process samples).

## Validation and reproduction

The 11 new accounting/integration tests were observed red before implementation
and then green. They cover nested accounting, error-safe restoration, nil/multiple
returns, summary statistics, bordered multi-column rendering, nested buffers,
and optional real-TUI profiling. The canonical full Fibrous suite passes
818 tests; its log is `/tmp/fibrous-phase-tests-818.log`. The docs suite passes
22 tests against the working Fibrous tree, and the updated page was inspected
in a real Neovim TUI.

The required 12-commit/eight-repeat history sweep completed 416 valid samples
in 52 complete cohorts, with no flagged working-tree regressions under the
3% floor / 1.5-times-summed-MAD rule. All six general PTY workloads retain
identical bytes/frame across every revision and repetition. Deterministic CPU
draw counts also match; wall-clock animation tick variation is normalized to
the same cells/commit. Raw history is `/tmp/fibrous-phase-history-818.jsonl`.

| Selected history row, ms/op | HEAD | Working tree |
| --- | ---: | ---: |
| full re-commit (set_props, every component) | 6.679 | 6.545 |
| pure layout+paint at transcript size | 24.100 | 20.923 |
| mount (create_root + first commit + teardown) | 53.412 | 47.299 |
| append one entry | 0.992 | 0.943 |
| stream tick (grow the last entry) | 0.799 | 0.837 |
| replace one mid-transcript entry (same size) | 0.752 | 0.794 |

This history comparison still includes the earlier uncommitted optimizations.
It is not a performance improvement caused by adding the profiler; the
production Lua tree is unchanged by this instrumentation task.

Run from the Fibrous source checkout:

```sh
nix run .#bench-resize-profile
BENCH_PROFILE_ORDER=profiled-first nix run .#bench-resize-profile
BENCH_PROFILE=1 nix run .#bench-resize-term
```

Add `BENCH_JSON=1` for structured results. `resize_profile` is also accepted by
the history driver. See `DEVELOPMENT.md` for timing boundaries and caveats.
