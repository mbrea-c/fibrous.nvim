# Removing the word-token cache

## Decision and pre-change measurement

The marginal-benefit review used eight order-balanced repetitions of the same
frozen Neovim 0.12.3 harness, with only the token-preparation branch disabled in
memory for the control. No project files changed during that diagnostic.
All other text preparation, width reuse and canvas optimizations stayed enabled.

| Diagnostic operation, ms/op or ms/frame | Cache enabled | Cache disabled | Result |
| --- | ---: | ---: | --- |
| reflow markdown | 34.820 | 35.717 | Inconclusive |
| reflow mixed | 9.941 | 10.683 | Inconclusive |
| reflow clamped | 3.447 | 3.607 | Inconclusive |
| reflow height | 0.865 | 1.004 | Inconclusive |
| first resize markdown | 26.509 | 25.427 | Cache slower |
| first resize mixed | 8.521 | 8.533 | Inconclusive |
| first resize clamped | 2.759 | 2.743 | Inconclusive |

Flags require a 3% floor and 1.5 times the sum of the two MADs. None of the
warm-loop median improvements clears that threshold. First Markdown resize is
about 1.1 ms slower with the cache, narrowly clearing it. Retained Lua heap in the
200-section Markdown case is approximately 0.5 MiB higher with caching; GC-based
heap measurements are noisy and are not exact allocation accounting.

The ablation is effective: the Markdown scene has 1200 cached nodes and 6200
word records when enabled, and no cached-token nodes when disabled. Output
fingerprints and buffer-write counts match. Raw diagnostic results are
`/tmp/fibrous-word-cache-review-818.jsonl` (48 process samples).

The initial diagnostic's small/uncertain warm gains did not justify the retained
representation, first-use cost and maintenance burden, and the user requested
removal. Fresh acceptance below finds a clearer warm Markdown cost than that
initial diagnostic. The simplification therefore has an explicit timing tradeoff;
it is not described as a pure performance improvement.

## Simplified implementation

Removed `prepare_words`, the packed token triples, the alternate word iterator,
cached word widths and token plumbing through wrapping. Reflow scans words
directly. No `_words` state is created or consumed by the layout engine.

Retained immutable flattened text/span metadata, nowrap output reuse,
same-effective-width ASCII wrapping reuse, conservative non-ASCII remeasurement,
span-boundary attribution, source-query pruning and sparse canvas width metadata.
The benchmark-only phase profiler is unchanged.

Three obsolete token-cache tests were replaced by one no-retention regression
test. It was observed red with the cache present and green after removal.
Wrapping/provenance/Unicode correctness tests remain, under
`tests/inline/rewrap_spec.lua`; fixed-width and flex reuse checks remain separate.

## Acceptance validation

The pre-removal library is frozen at
`/nix/store/hrqwpfr665mf3g2gm94h4i48ssf9bsv3-source`.
Fresh comparisons use that fixed benchmark harness and Neovim runtime, with
library variants run sequentially and order reversed between repetitions.
The simplified library used for validation is
`/nix/store/j9jdaa2jp83ha2q2aikxvfi5p3rd3z9a-source`. The comparison collected
56 valid process samples in seven complete eight-repeat cohorts.

| Operation, ms/op or ms/frame | Before removal | Simplified | Interpretation |
| --- | ---: | ---: | --- |
| reflow markdown | 33.933 | 36.172 | Slower |
| reflow mixed | 9.985 | 10.502 | Inconclusive |
| reflow clamped | 3.427 | 3.620 | Inconclusive |
| reflow height | 0.907 | 0.908 | Inconclusive |
| first resize markdown | 26.966 | 25.613 | Faster |
| first resize mixed | 8.665 | 8.408 | Inconclusive |
| first resize clamped | 2.828 | 2.791 | Inconclusive |

The warm Markdown CPU mean increases by 2.239 ms (6.6%), clearing its 1.123 ms
noise threshold. First Markdown resize improves by 1.353 ms (5.0%), clearing its
0.809 ms threshold. Other CPU changes remain inconclusive, as do the native TUI
p50/p95 changes. This is a documented complexity/retained-memory tradeoff, not
a claim that removal improves every timing.

Fresh comparisons with the original pre-reflow control (which already includes
the five earlier source/Markdown optimizations) confirm that useful gains remain:

| Width-burst workload, ms/frame | Pre-reflow control | Simplified | Change |
| --- | ---: | ---: | ---: |
| reflow markdown | 38.818 | 36.172 | -6.8% |
| reflow mixed | 11.433 | 10.502 | -8.1% |
| reflow clamped | 6.233 | 3.620 | -41.9% |
| reflow height | 1.067 | 0.908 | -14.9% |

The Markdown, mixed and clamped width-burst gains clear the same noise rule;
height-only changes do not. All CPU fingerprints and deterministic buffer-write
counts match across all variants. Every one of the 16 PTY runs completed its
12 frames and matched text/highlight fingerprints and terminal bytes/frame:
4190.750 for Markdown, 6986.500 for mixed, and 2922.833 for clamped.

Raw paired results are `/tmp/fibrous-word-removal-final-816.jsonl`. The canonical
suites pass 816 Fibrous tests, 1403 Weave integration tests against this Fibrous,
and 22 docs tests. The updated layout/profiling docs were inspected in a real
Neovim TUI against the simplified library.

## Historical regression gate

The canonical 12-commit/eight-repeat sweep completed 416 valid samples in 52
complete cohorts. No working-tree timing row is flagged as a regression against
HEAD under the median/MAD rule. All six general PTY rows have identical
bytes/frame across all revisions and repetitions. Eleven deterministic CPU
draw-count rows match; variable animation tick counts normalize to the same
cells/commit.

| Selected history row, ms/op | HEAD | Simplified working tree |
| --- | ---: | ---: |
| full re-commit (set_props, every component) | 6.737 | 6.684 |
| pure layout+paint at transcript size | 24.292 | 20.685 |
| mount (create_root + first commit + teardown) | 54.536 | 47.721 |
| append one entry | 0.948 | 0.952 |
| stream tick (grow the last entry) | 0.810 | 0.833 |
| replace one mid-transcript entry (same size) | 0.736 | 0.758 |

This comparison includes all earlier staged optimizations and does not erase
the measured warm Markdown slowdown versus the immediately preceding cached
candidate. Raw history is `/tmp/fibrous-word-removal-history-816.jsonl`.
Suite logs are `/tmp/fibrous-word-removal-816-tests.log`,
`/tmp/weave-word-removal-1403-tests.log` and
`/tmp/docs-word-removal-22-tests.log`.
