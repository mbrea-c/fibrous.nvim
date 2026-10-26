# Reflow optimization experiments

This records the original combined candidate, including its word-token cache.
A later marginal-benefit review rejected that cache and removed it while keeping
flattened-text caching, effective-width reuse and sparse canvas widths. See
[word_cache_removal.md](word_cache_removal.md) for the final implementation and
its fresh acceptance measurements; the numbers below remain historical evidence.

## Method

The control includes the five earlier Markdown/source-query optimizations, not
just HEAD. Its immutable source is
`/nix/store/na5zkd69j2fswfs84xqi1jswvr03sqs8-source`.

Resize bursts use that snapshot's fixed harness. The first-resize workload was
added before the lazy-cache experiment and frozen separately at
`/nix/store/m5hp6nbch4djn0wni0gmg3bpjlk8xffg-source`. Only the library varies
within comparisons. The pinned runtime is Neovim 0.12.3.

The automated workloads were added and measured before implementation:
200 mapped Markdown sections, mixed components with a fixed sidebar and
scrollable containers, clamped text, height-only changes, and later the first
width change after a fresh mount.

An initial eight-repeat baseline ran under game load. The first paired run
crossed the transition when the game stopped, so it was stopped and excluded.
All decisions below use game-off, randomized eight-batch comparisons with
baseline/candidate processes running sequentially. No other suite or benchmark
runs concurrently. Compare spread as well as medians.

Each implementation starts with a failing deterministic work-bound or
correctness spec. CPU and PTY output are checked before the next experiment.
Per-step PTY checks use one paired repeat against eight stable initial samples;
the final comparison repeats every PTY scenario eight times.

## Trials, including rejected versions

| Trial | Relevant result | Decision |
| --- | --- | --- |
| Eager word preparation | Mixed burst 12.178 to 11.063 ms; clamped burst 6.332 to 5.588 ms | Refine |
| Reuse wrapped text at unchanged effective width | Clamped burst 5.793 to 3.781 ms | Refine |
| Sparse cell-width metadata | Mapped alternating resize 37.463 to 28.431 ms | Refine |
| ASCII-row width bypass | Removes per-cell width accesses for ordinary painting/blanking | Retain in final painter |
| Packed word data | 904 preparation tables become 4 for one 900-word line | Retain, but not eagerly |
| Lazy word preparation | Avoids resize-preparation cost on ordinary fresh-text commits | Retain |

The initial combined candidate increased height-only time from 0.877 to
0.962 ms, clearing that run's noise threshold. It was rejected. Two new failing
specs exposed remaining per-cell width accesses; ordinary rows now bypass them,
while wide rows retain the existing repair path.

Policy-change tests also caught correctness edges. Reusing wrapped lines is
limited to ASCII-only text, so fixed-width non-ASCII text can reflow after an
ambiwidth change. Non-ASCII nowrap text retains its lines and source runs, but
has its display size remeasured. Mutable raw trees never opt into preparation.

The first full 12-commit gate collected 416 valid samples but rejected the eager
cache version: transcript mount rose from 54.037 to 57.405 ms, full recommit from
6.729 to 6.983 ms, and mid-entry replacement from 0.766 to 0.839 ms. A small
math-row flag did not reproduce in the following four-way comparison.

Packing removed the per-word table overhead but did not remove all eager
preparation cost. The next red-green change defers preparation until immutable
text actually needs another wrap. Fixed-width ASCII text that can keep its
wrapped lines does not need token preparation at all.

The eight-batch four-way follow-up compared HEAD, the pre-batch control, eager
packed data, and lazy packed data. Transcript mount was 54.767 ms in the
pre-batch control and 47.918 ms with lazy preparation. Full recommit was
6.671 versus 6.556 ms, with no established regression. The first-resize workload
checked that the ordinary-commit saving was not simply moved into a slower
first resize relative to the pre-batch control.

These superseded trials are retained as evidence, not presented as accepted
final performance. Their raw data includes
`/tmp/fibrous-resize-final-history.jsonl`,
`/tmp/fibrous-resize-packed.jsonl`, and
`/tmp/fibrous-resize-lazy.jsonl`.

## Original candidate implementation

- Immutable host text keeps flattened spans. Word data is built lazily when
  unchanged text needs rewrapping, with packed offset/text/width triples rather
  than a table per word. Only printable ASCII word widths are cached.
- ASCII wrapped lines/runs can survive a parent resize when their effective
  text width is unchanged. Measurement still recomputes their size, respecting
  the distinction between measured and final flex widths.
- The canvas stores widths only for wide heads and continuations. Ordinary
  widths are implicit, and ASCII painting/blanking bypass width access on rows
  without wide cells.

These are per-node/internal changes, not a new public cache API. They do not
virtualize offscreen content or change native scrolling.

## Final paired comparison

The retained source is
`/nix/store/7fgh8pbn1mpz3i6a4a33zsxx92cdbadk-source`.
The final comparison collected 96 valid samples: eight per library/workload
pair, including the new first-resize case.

| Operation | Control | Retained | Interpretation |
| --- | ---: | ---: | --- |
| Warm alternating resize, unmapped | 31.812 ms | 25.138 ms | -21.0%, clears noise threshold |
| Warm alternating resize, mapped | 35.975 ms | 30.070 ms | Lower median, inconclusive spread |
| Mapped Markdown width burst | 38.169 ms | 34.171 ms | -10.5%, clears threshold |
| Mixed-component width burst | 10.853 ms | 10.239 ms | Within measured noise |
| Clamped width burst | 6.288 ms | 3.439 ms | -45.3%, clears threshold |
| Height-only burst | 0.969 ms | 0.872 ms | Within measured noise |
| First Markdown resize | 27.265 ms | 26.760 ms | Within measured noise |
| First mixed resize | 8.660 ms | 8.430 ms | Within measured noise |
| First clamped resize | 4.096 ms | 2.804 ms | -31.5%, clears threshold |

A shift must clear both a 3% floor and 1.5 times the sum of the two MADs to be
flagged, matching the project's trend-table rule. For example, mapped
alternating resize has a 5.904 ms median reduction but a 6.457 ms noise
threshold; it is not treated as an established improvement.

The large Markdown burst's median batch p95 is 66.942 ms before and 66.107 ms
after, an inconclusive change. These changes do not establish smooth 60 Hz
resizing for that case.

TUI timings include geometry synchronization and synchronous Neovim
`:redraw`, not input delivery, terminal-emulator rendering, or the harness's
quiescence wait. Clamped TUI p50 falls from 6.014 to 3.453 ms. Mixed TUI p50
is within noise; its coarse batch p95 falls from 19.499 to 16.843 ms.
With 12 PTY frames, nearest-rank p95 is the batch maximum; first-resize p95
over eight fresh roots is similarly coarse.

All 32 final PTY samples completed every frame and matched terminal bytes and
their captured fingerprints: content/highlights in resize_term, and
content/comment positions in markdown_term. CPU resize scenes also matched
their buffer-write counts and content/highlight fingerprints.

| TUI scenario | Bytes/frame, unchanged |
| --- | ---: |
| Markdown width burst | 4190.750 |
| Mixed-component width burst | 6986.500 |
| Clamped width burst | 2922.833 |
| Alternating Markdown, unmapped/mapped | 5364.917 |
| Alternating Markdown with comments | 5368.917 |

The final full suites pass: 807 Fibrous tests, 1403 Weave tests against this
Fibrous, and 22 docs tests. Logs are
`/tmp/fibrous-resize-807-{fibrous,weave,docs}-tests.log`.
Paired data is `/tmp/fibrous-resize-final-807.jsonl`.

## Final history regression gate

The final canonical sweep collected 416 valid samples across 13 library points
(the working tree and 12 historical commits), four general workloads, and eight
randomized repeats. There were no load errors or missing cohorts. No working-tree
row is flagged as a regression against the immediately preceding HEAD under the
project's median/MAD rule.

Selected trend rows, comparing HEAD with the retained working tree:

| General workload | HEAD | Retained |
| --- | ---: | ---: |
| Transcript full layout and paint | 23.251 ms | 20.363 ms |
| Transcript mount | 54.139 ms | 47.242 ms |
| Transcript append | 0.945 ms | 0.948 ms |
| Transcript stream tick | 0.793 ms | 0.835 ms |
| Transcript mid-entry replacement | 0.712 ms | 0.745 ms |
| Full recommit | 6.745 ms | 6.695 ms |

The small append, stream and replacement increases remain below their measured
noise thresholds. For example, streaming shifts by 0.041 ms against a 0.161 ms
threshold, and replacement by 0.032 ms against a 0.122 ms threshold. The initial
cold-mount and recommit regressions no longer appear.

All six general PTY scenarios have identical bytes/frame across all 13
revisions. Deterministic buffer-write counts match as well. The wall-clock
animation probe produces 29 to 31 ticks in some historical samples, always
60 cells per commit; HEAD and the retained tree both produce 30 ticks in every
repeat. That timer variation is not treated as a draw-volume regression.

The raw history is `/tmp/fibrous-resize-history-807.jsonl`. The updated Layout
and Commit pipeline pages were also inspected in a real TUI against the final
working tree. The production Lua tree matches the source used for validation.

## Correctness and work guards

- Changed text, styles, handlers and source descriptors replace immutable host
  nodes. Mutable raw trees and width-generated fill content recompute normally.
- Word offsets, styles, interactions, whitespace, long words, Unicode text,
  source bytes and flex redistribution match uncached layouts or fresh mounts.
- Preparation is deferred on fresh text, bounded by logical lines rather than
  word count, and skipped when existing wrapped lines suffice.
- Ordinary cells allocate no width entries, including grown rows. Ordinary-row
  painting/blanking performs no per-cell width access. Wide heads,
  continuations, clipping and either-half overwrites retain explicit specs.
- PTY completion receipts reject partial frame loops.

## Reproduce

Standalone entry points are `nix run .#bench-resize`,
`.#bench-resize-first`, and `.#bench-resize-term`. `BENCH_N` sizes scenes;
`BENCH_FRAMES` sizes PTY loops (default 12). First resize uses eight fresh
mounts per scene and a full GC before each timed width change.

Stage new files before invoking wrappers:

```sh
nix run .#bench-history -- --last 12 --reps 8 \
  --benches run,transcript,markdown,term --out /tmp/resize-history.jsonl
nix run .#bench-history -- --last 1 --reps 8 \
  --benches resize,resize_first,resize_term --out /tmp/resize-comparison.jsonl
```

The experiments compare immutable intermediate snapshots because earlier work
was already staged, not committed. Freeze the control with
`nix flake metadata --json` before edits, then alternate that snapshot and the
candidate as working directories while invoking the same frozen bench scripts
and Neovim. Keep raw JSONL, including p50/p95, CPU and fingerprint fields, not
only the trend table.
