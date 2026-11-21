# Retained Markdown resize experiment

The experiment under `bench/` attaches a native renderer to a scroll-mode Markdown view. Lua parses each document revision, runs the components and syntax highlighter, and supplies styled text, source maps and Neovim display widths. Rust retains the layout input, reflows the document at the requested width, and compares the painted result with the previous frame. One native call returns changed lines and highlights, source ranges, node rectangles and visible link fragments. Lua writes the buffer, updates the hit-test tree and publishes the source map for selection and projection.

The renderer handles Markdown paragraphs, lists, blockquotes, fixed-width aligned table cells, inline equations and centered display math. When a component commits an edit, the adapter gives the current buffer state back to the Lua host and discards the previous native document. The next width change compiles the new revision. Consecutive edits at a fixed width use the regular Lua commit path. The edit workloads include this transition cost in the next resize measurement.

## Reproduce on Linux with LuaJIT Neovim

Run these pinned entry points from the Fibrous checkout. The archived measurements
used Neovim 0.12.3 and reference revision
`7b8a71b4c4027e1b73ca3b8e3767242979378683`. Fresh runs write to the
explicit output directory, preserving the archived results.

```sh
nix run .#test-native
nix run .#bench-native-markdown -- --rounds 8 --out /tmp/fibrous-native
nix run .#bench-native-markdown-term -- --rounds 3 --out /tmp/fibrous-native
```

Nix builds `native/markdown` with its Cargo.lock and supplies the module to the
same Lua adapter used in the optional plugin package. The optimized Lua comparator
is injected into layout closures by `coalesced.lua` only inside benchmark
processes. The archive's historical wrap-hook patch is not needed and is not installed.
Neither that hook nor the benchmark environment variables enable the plugin's
runtime optimization; use the package override documented in the root README.

Each mode runs in a fresh Neovim process. Order reverses between rounds. Each headless process builds the same 200-section document, records initial mount and any extra native setup separately, measures the first resize at 64 columns, warms one 12-width cycle, and times two further cycles. A separate 12-frame pass includes a source projection for bytes 14–96 after every resize. The terminal driver uses Fibrous's PTY harness, mounts the actual floating view, resizes and forces a synchronous redraw, and checks all 12 frames. Fingerprints are calculated outside the frame timers.

The parity check compares buffer text, exact highlight coordinates and groups, every input byte's public source projection, and resolved row selections on three smaller documents. They include headings, emphasis, links, fenced code, quote borders, ordered/bulleted/task lists, duplicate spaces, long words, and multibyte text. A mixed table and fraction fixture checks widths down to one cell, including highlighting the visible half of a clipped wide glyph. The timed full-size cases also check fingerprints and draw counts.

## Feature cases

Run the pinned feature driver from the same checkout. The default run uses 40 sections per fixture and eight timing rounds.

```sh
nix run .#bench-native-markdown-features -- --out /tmp/fibrous-native
```

The driver writes `FEATURES.md` and `results-features.jsonl` in the required `--out DIR`. The [archived feature results](FEATURES.md) and [raw measurements](results-features.jsonl) remain unchanged. Exit status 1 with a completed report means at least one native case produced a mismatch or rejected the document. Unexpected worker errors interrupt the driver. Use `--sections 2 --rounds 1` for a quick check.

| Case | Operations and checks |
| --- | --- |
| Settled edits | Replace a middle paragraph, append and delete text using the public property update. Resize after each edit and verify the revised buffer, highlights and source coordinates. |
| Streaming | Append a partial bold span with live mode enabled, complete it, settle the same source, and resize between each change. |
| Tables | Narrow and widen three-column left-, center- and right-aligned tables with styled and wide characters. Check clipping and restored alignment. |
| Inline math | Reflow prose with superscripts and variables. Check rendered glyphs, math highlights and source projections. |
| Display math | Resize stacked fractions. Check the numerator, fraction bar, denominator, styling and horizontal centering. |
| Links | At five width steps, activate both ends of a wrapped link, a second URL, plain text and the vacated link cell. Check the callback count and exact destinations. |

The headless pointer benchmark supplies a position through the same seam as the repository's mouse tests and invokes the real release mapping. A separate correctness run mounts a floating view in a PTY, finds its screen coordinates, and submits Neovim mouse press and release events. A queued key acknowledges each release before the next assertion. All callback destinations stay inside the benchmark. Only the headless dispatch is timed.
