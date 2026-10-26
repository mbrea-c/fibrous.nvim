## Development

This project is built with **red-green TDD**, with no exceptions. Every change,
whether a fix, a feature, or a refactor, starts from a failing test:

1. **Red.** Write the spec that describes the new behavior. Run it and watch it
   fail, for the reason you expect. A spec that passes before you touch the
   implementation is not testing what you think.
1. **Green.** Make it pass with the smallest change that does the job.
1. **Refactor.** Clean up with the test as your safety net.

The reactive core is pure Lua with no dependency on the Neovim API, so it is
fully unit-testable.

One caveat that shapes how we test: **headless Neovim never redraws.** A
`--headless -l` run mutates buffers but paints nothing, so any bug that lives in
the redraw (scroll position, `leftcol`, cursor visibility, highlight flicker)
will false-pass a headless spec. Those behaviors have to be reproduced with a
real PTY child (see [Benchmarks](#benchmarks) for the harness that does this);
do not trust a green headless run for anything the terminal actually draws.

### Requirements

- `nvim` (0.10+) on your `PATH`. That's it. There are no external Lua/test
  dependencies.

### Running tests

Tests run inside a **fully isolated** headless Neovim (`-u NONE`): no user
config and no plugins are loaded, so a failure can only come from this project's
own code. The test harness (`tests/harness.lua`) is a small, zero-dependency,
busted-flavored runner; specs live in `tests/**/*_spec.lua`.

Run the whole suite:

```sh
make test
```

Run a single spec file (fast inner loop for TDD):

```sh
make test-file FILE=tests/reactive/use_state_spec.lua
```

A non-zero exit code means at least one test failed.

> **Runtimepath gotcha.** `make test` / `make test-file` and the `nix run`
> wrappers work because `tests/run.lua` sets `package.path` to this checkout. A
> bare interactive `nvim`, or an ad-hoc `nvim -l some_script.lua` that
> `require`s fibrous, does **not**: it loads whatever fibrous is already on the
> runtimepath (a home-manager / pack / `weave` install), silently running a
> different copy than the one you are editing. Use the entry points above, or
> pass `--cmd 'set rtp^=$PWD'` to any manual `nvim` invocation.

### Writing tests

Specs use the familiar `describe` / `it` / `before_each` / `after_each` globals
and a small `assert` table:

```lua
describe("use_state", function()
  it("exposes the initial value through get()", function()
    -- ... arrange / act ...
    assert.equal(5, value)        -- strict ==
    assert.same({ a = 1 }, tbl)   -- deep equality
    assert.is_true(flag)          -- also is_nil, truthy, falsy
    assert.has_error(function() ... end, "optional substring")
  end)
end)
```

The table is small and deliberately busted-flavored, but it is **not** full
busted: there is no `assert.not_equal` and no `assert.is_function`. Invert with a
tracked boolean + `assert.falsy`, or assert on the value directly (e.g.
`assert.equal("function", type(fn))`).

### Types

Source is annotated with [LuaCATS](https://luals.github.io/wiki/annotations/)
(`---@param`, `---@return`, `---@class`, ...) so a Lua language server can
type-check the codebase and provide completion to consumers.

### Benchmarks

Commits reuse unchanged subtrees and repaint damage where possible. Width changes
still reflow text and start a fresh canvas, so performance remains a standing
concern. The benches answer two separate questions, and both matter:

- **Latency (ms/op):** how long a commit's CPU work takes (build, layout, paint,
  buffer write).
- **Draw cost:** how much a commit then pushes at the display. Over ssh and tmux
  the display is the bottleneck: every changed cell is bytes down a high-latency
  link, and a big per-frame redraw is what makes the terminal and the cursor
  flicker. A change can be free on CPU and still make a remote session unusable,
  so we measure this on its own.

**One principle underlies every bench: keep two axes separate.** The *library*
under test is loaded from the current working directory (so it varies per
commit); the *harness* (the bench scenarios and helpers) is loaded from the
bench script's own directory, so the ruler stays pinned while the thing being
measured changes. This is what makes cross-history trends honest.

CPU workloads accept `BENCH_N` to size the workload. Terminal-draw workloads
use `BENCH_FRAMES` for the number of redraws. All emit a structured
`BENCH_JSON=1` object (tagged with `BENCH_LABEL`) that the history driver reads.

#### The bench scripts

Run these against the working tree with `make`, or against the flake snapshot
with the `nix run` wrapper (the wrapper only sees committed or staged code):

| bench                   | wrapper                      | what it measures                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make bench`            | `nix run .#bench`            | Inline-host micro-benchmarks. `N` counts sections (each ~6 nodes, so `N=100` is a ~600-node tree). Scenarios isolate each stage: pure layout+paint, mount, full re-commit, incremental `use_state` update, scoped leaf update (the damage-tracking target), scroll tick, and one live `animation` over a real second of event loop. Reports both ms/op and cells/op.                   |
| `make bench-transcript` | `nix run .#bench-transcript` | The chat/ACP workload: one long scroll-mode column where the ops that matter are append-at-tail and grow-the-last-entry (streaming), plus a mid-edit. Every entry renders through a `memo = true` child, so this is where memoization pays off. `N` counts entries (default 1000).                                                                                                     |
| `make bench-term`       | `nix run .#bench-term`       | Terminal-draw throughput: the bytes nvim's TUI pushes at a **real PTY** per frame. Spawns child nvim TUIs (a real terminal, not headless) and sums the pty bytes per redraw.                                                                                                                                                                                                           |
| `make bench-history`    | `nix run .#bench-history`    | Runs the benches across a span of git history and prints a trend table. Reads the repo read-only (it clones to a temp worktree, never writes your tree) and pins the harness, so only `lua/fibrous/` varies between points. Example: `nix run .#bench-history -- --last 12 --reps 8 --benches transcript`. This is the regression gate: read the newest column against the prior ones. |

#### Markdown optimization experiments

Three additional workloads cover paths the cold parse/mount bench does not:

- `nix run .#bench-markdown-workload`: plain/mixed parsing with and without
  provenance, warm width changes, dense span attribution, and small annotation
  queries. Resize rows also report buffer-write cells.
- `nix run .#bench-markdown-maps`: transient allocation in KiB/op and CPU with
  GC stopped for private identity/slice maps and a full mapped parse.
- `nix run .#bench-markdown-term`: real-PTY Markdown resizing, unmapped,
  mapped, and with comment overlays. Each case checks all frames completed and
  records content/highlight fingerprints to compare alongside bytes/frame.

Use `--benches markdown_workload,markdown_maps,markdown_term` with
`bench-history` to keep the harness and runtime fixed while varying the library.
A dirty candidate can use `--last 1 --reps 8` to compare HEAD with `working`;
after committing, use `--last 2` if the parent already has the source-mapping
API. Older revisions without that API cannot run these new scenarios.

For each experiment, establish the benchmark and baseline before changing the
implementation. Measure CPU and PTY output again before starting the next
candidate. Reject changes that do not meaningfully help, require disproportionate
complexity, change the rendered result, or increase draw cost. Keep the raw
JSONL until the comparison is reviewed. The measured trials are recorded in
[bench/markdown_experiments.md](bench/markdown_experiments.md).

#### Resize bursts

- `nix run .#bench-resize`: warm twelve-step width bursts over mapped
  Markdown, mixed rows/columns with a fixed sidebar and scrollable containers,
  and max-width-clamped text. A height-only case checks work unrelated to
  wrapping. Reports mean, median and p95 wall time, process CPU time, buffer
  writes, and content/highlight fingerprints.
- `nix run .#bench-resize-first`: first width change after a fresh mount and an
  explicit full GC, including first-use costs that warm resize loops can hide.
  Uses eight fresh roots per scene and reports mean, median and p95.
- `nix run .#bench-resize-term`: the same width bursts in a real TUI, reporting
  terminal bytes and in-child resize-through-`:redraw` median/p95. Those timings
  exclude input delivery, terminal-emulator painting, and the harness's
  quiescence wait. Completion receipts reject partial frame loops.

Use `--benches resize,resize_term` with `bench-history`; the additional timing
fields are retained in raw JSONL. Keep both the runtime and harness fixed,
shuffle baseline/candidate order within each batch, and compare spread as well
as medians. Restart a timing run if background load changes materially partway
through it. Reflow experiments are recorded in
[bench/resize_experiments.md](bench/resize_experiments.md).

#### Resize phase diagnostics

`nix run .#bench-resize-profile` repeats the warm resize scenes with and without
benchmark-only timers. It verifies identical buffer-write counts and complete
text/highlight fingerprints. Normal library execution has no timing hooks.

The exclusive phases are layout (including wrapping and wrapped-run source
attribution), canvas allocation/growth, painting, text extraction, highlight
extraction, buffer text writes, buffer highlight API calls, and source updates.
The source phase times `sources.update` and its listeners, not all provenance
work or lazy source queries that no listener requests. Nested phases subtract child time,
so phase means plus `other` add to the instrumented mean. `other` includes
unwrapped build, splice comparison, bookkeeping and instrumentation overhead.
There is no separate parser timer: these are already-mounted resize scenes.

The report includes calls/frame, each phase's mean and p95, and the slowest
frame's actual breakdown. Do not add phase p95s: they need not occur in the same
frame. Profiler installation/restoration is outside each timed frame; wrapper
and clock costs during rendering can affect both phase attribution and GC. GC
pauses are charged to the phase where they happen, not necessarily the phase
that allocated the collected objects.
The unprofiled mean and its signed difference from the instrumented mean make
that disturbance visible, but that difference also includes run-to-run noise.
Do not use profiled times as optimization acceptance timings.

Use `BENCH_PROFILE_ORDER=profiled-first` to reverse the default plain-first order.
Alternate the order across repeated runs. Raw results use `BENCH_JSON=1`, and
`resize_profile` is also accepted by `bench-history --benches`.

`BENCH_PROFILE=1 nix run .#bench-resize-term` adds the same breakdown inside a real
TUI, plus synchronous `:redraw`. Without that flag, the existing PTY benchmark
does not install profiling hooks or add profile fields. Compare its normal and
profiled output/fingerprints and bytes/frame, and continue to use the unprofiled
benchmark for performance decisions. Neither mode times terminal-emulator paint.
The first repeated breakdown is recorded in [bench/resize_phases.md](bench/resize_phases.md).

#### The harnesses

- **`bench/throughput.lua` (cells/op).** Wraps the two buffer-write APIs the
  host flush uses, `nvim_buf_set_lines` and `nvim_buf_set_text`, and sums the
  *display width* of everything written (screen cells, not bytes, because a
  multibyte glyph is one cell). This is the CPU-side draw metric, gathered in
  the same headless run as the latency numbers.

- **`lua/fibrous/bench/termdraw.lua` (bytes/frame, the PTY harness).** Spawns a
  child nvim inside a real pty, attaches a scenario, forces N redraws, and sums
  the pty bytes. It exists because a headless or `--embed` nvim emits no
  terminal output at all, so it catches exactly the costs the buffer metric
  cannot see: highlight-only repaints (`nvim_set_hl` writes zero buffer chars
  but the TUI repaints every cell using the group, which is the water-indicator
  flicker), and escape-sequence overhead (cursor moves, SGR color changes,
  scroll regions). This is also the harness to reach for when reproducing a
  redraw bug that a headless spec cannot see. It lives under `lua/` (not
  `bench/`) on purpose: downstream apps such as weave put fibrous on their
  `package.path` and can `require("fibrous.bench.termdraw")` to measure their
  own screens on the same ruler. It has its own spec at
  `tests/bench/termdraw_spec.lua`.
