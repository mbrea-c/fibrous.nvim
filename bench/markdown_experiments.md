# Markdown optimization experiments

## Method

The benchmark was added and measured before implementation changes. Each
candidate then had a deterministic failing work-bound spec, an implementation,
and a fresh CPU/PTY comparison before starting the next candidate.

The fixture is 200 mixed Markdown sections (53,367 source bytes). Measurements
use the pinned Nix Neovim 0.12.3. CPU tables are medians of eight batches, with
the unchanged `cd5daad` library and the working candidate shuffled within each
batch. The harness and runtime are held fixed. Compare medians and spread, not
an individual fast run; these are local measurements, not portable guarantees.

The initial PTY baseline has eight repeats. Every candidate was compared with
that baseline, checking bytes/frame and the full-buffer/content-plus-comment
position fingerprints, not only timing. Completion receipts reject partial
frame loops. The final gates repeat terminal measurements and run the older
general workloads across history.

## Isolated decisions

"Before" is the preceding accepted candidate, except experiment 1, which compares
against its interleaved unchanged control. Values below come from that step's
eight-repeat CPU run, before any subsequent implementation change.

| Experiment | Relevant operation | Before | After | Decision |
| --- | --- | ---: | ---: | --- |
| 1. Prune source queries | Project one comment | 77.308 ms | 5.328 ms | Keep |
| 1. Prune source queries | Capture small selection | 78.546 ms | 0.585 ms | Keep |
| 1. Geometry-only entry lookup | Locate entry | 82.564 ms | 0.375 ms | Keep |
| 2. Span-boundary traversal | Attribute 48 dense spans | 0.193 ms | 0.007 ms | Keep |
| 2. Span-boundary traversal | Mapped warm resize | 46.517 ms | 43.715 ms | Keep |
| 3. Reuse text preparation | Mapped warm resize | 43.715 ms | 37.184 ms | Keep |
| 3. Reuse text preparation | Unmapped warm resize | 35.562 ms | 33.617 ms | Keep |
| 4. Scan plain runs | Mixed unmapped parse | 6.574 ms | 6.020 ms | Keep |
| 4. Scan plain runs | Plain prose parse | 2.971 ms | 2.511 ms | Keep |
| 5. Private identity ranges | Mixed mapped parse | 11.368 ms | 9.374 ms | Keep |
| 5. Private identity ranges | Mapped parse allocation | 6588.876 KiB | 5097.919 KiB | Keep |

All five smaller changes show useful gains for their size. No persistent source
index, global cache, word-token cache, or new public representation was needed.
The larger variants were not implemented or claimed as rejected experiments.

## Final paired gate

The final eight-repeat comparison against the unchanged control confirmed:

| Operation | Control | Accepted candidate |
| --- | ---: | ---: |
| Mixed parse, unmapped | 6.327 ms | 5.852 ms |
| Mixed parse, mapped | 11.576 ms | 9.311 ms |
| Warm resize, unmapped | 36.805 ms | 32.073 ms |
| Warm resize, mapped | 45.513 ms | 35.972 ms |
| Project one comment | 75.542 ms | 5.045 ms |
| Project ten comments | 806.340 ms | 40.404 ms |
| Capture small selection | 77.258 ms | 0.787 ms |
| Locate whole entry | 81.767 ms | 0.397 ms |
| Transient mapped parse allocation | 6830.664 KiB | 5097.987 KiB |

The broader 12-commit gate collected 312 valid CPU samples. Relative to the
immediate unchanged control, the original Markdown bench's parse row improved
from 6.661 to 5.991 ms, and mount from 72.910 to 69.166 ms. Buffer-write
counts were unchanged throughout. Transcript append, stream, and mid-replacement
medians rose by 0.024, 0.042, and 0.049 ms, respectively, but each shift was below
the trend table's combined-MAD threshold (0.106, 0.223, and 0.184 ms). Those
samples do not establish a regression.

The final paired gate collected 64 valid samples, with eight repeats per
library/workload combination. All six general terminal scenarios and all three
Markdown terminal scenarios matched their controls; Markdown fingerprints also
matched the initial baseline.

The full pinned suites passed: 791 Fibrous tests, 1403 Weave tests against the
working Fibrous, and 22 docs tests. The source documentation was also inspected
in the native terminal preview.

## Unchanged output

Each candidate produced these same real-terminal results at 12 frames:

| Workload | Bytes/frame |
| --- | ---: |
| Resize without maps | 5364.917 |
| Resize with maps | 5364.917 |
| Resize with comment overlays | 5368.917 |

Buffer-write cells for a warm resize also remain 259900 in both mapping modes.
The PTY fingerprints match the baseline for each workload. They cover the full
buffer, including offscreen text, and the projected comment locations.

## Compatibility and guards

- Queries still validate fully visible text clusters against actual buffer
  content. Nonmonotonic maps and composed characters remain addressable.
- Boundary traversal preserves gaps, empty spans, reordered pieces, interaction
  identity, source maps, and false unmapped positions. A bytewise oracle checks
  equivalence.
- Only immutable host-built text nodes retain preparation. Changed text, styles,
  handlers, and source descriptors rebuild it. Mutable raw trees and generated
  fill content retain their normal recomputation behavior.
- Plain-run scanning preserves malformed delimiters, backslash escapes, hard
  breaks, and original UTF-8 byte positions.
- Compact identity ranges are parser-private. Public document AST maps remain
  ordinary dense arrays. CRLF, stripped prefixes, table cells, empty bounds,
  sparse fallback maps, and shorter joined lines have regression coverage.

## Reproduce

Stage new benchmark files before invoking Nix wrappers. With a dirty candidate
and a source-mapping-capable HEAD:

```sh
nix run .#bench-history -- --last 1 --reps 8 \
  --benches markdown_workload,markdown_maps,markdown_term \
  --out /tmp/markdown-experiment.jsonl
```

After committing the candidate, use `--last 2` when its parent has the same
source-mapping API. The new cases cannot run against revisions predating that
API; use the original `run,transcript,markdown,term` cases for the broader
history gate.

Standalone entry points are `.#bench-markdown-workload`,
`.#bench-markdown-maps`, and `.#bench-markdown-term`. The allocation case stops
GC only during its measured loop and reports transient KiB per operation,
including intermediate allocations. It is not a retained-heap measurement.
