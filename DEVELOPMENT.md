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

### Writing tests

Specs use the familiar `describe` / `it` / `before_each` / `after_each` globals
and a small `assert` table:

```lua
describe("use_state", function()
  it("exposes the initial value through get()", function()
    -- ... arrange / act ...
    assert.equal(5, value)        -- strict ==
    assert.same({ a = 1 }, tbl)   -- deep equality
    assert.is_true(flag)
    assert.has_error(function() ... end, "optional substring")
  end)
end)
```

### Types

Source is annotated with [LuaCATS](https://luals.github.io/wiki/annotations/)
(`---@param`, `---@return`, `---@class`, ...) so a Lua language server can
type-check the codebase and provide completion to consumers.

### Benchmarks

Every commit is a full measure and repaint of the whole tree, so performance is
a standing concern, not an afterthought. The benches answer two separate
questions, and both matter:

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

All benches accept `BENCH_N` to size the workload and emit a structured
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
