# AGENTS.md

Working agreement for changes to **fibrous.nvim**. Every change, whether a fix, a
feature, or a refactor, must complete the checklist below before it is considered
done. All of it is mandatory, not "when it seems worth it."

## Read DEVELOPMENT.md first

Before writing any code, read [DEVELOPMENT.md](DEVELOPMENT.md). It is the source
of truth for how this project is built and tested, and the checklist here assumes
you know it.

## Use red-green TDD, always

All development in this project uses **red-green TDD**, with no exceptions:

1. Write the spec that describes the new behavior.
2. Run it and watch it fail, for the reason you expect.
3. Implement the smallest change that makes it pass.
4. Refactor with the test as your safety net.

A spec that passes before you touch the implementation is not testing your
change. See DEVELOPMENT.md for the harness, the assertion table, and the reason
redraw-dependent behavior (scroll, cursor, flicker) cannot be trusted to a
headless spec and needs a PTY reproduction.

> **Snapshot caveat (read first).** The `nix run` wrappers run against the
> flake's own snapshot of the source, which is what is **committed or staged**,
> not your dirty working tree. Run `git add` on your changes before any wrapper
> below, or the run will silently test the old code. During iteration you may use
> the `make ...` targets against the working tree, but the sign-off runs must be
> the `nix run` wrappers, so they match CI and `nix flake check`.

## 1. Run the full test suite (via the `nix run` wrapper)

```sh
nix run .#test                                  # the whole suite
nix run .#test -- tests/inline/host_spec.lua    # a single spec, while narrowing
```

The suite must be green before sign-off.

## 2. Check for regressions (bench history, via the `nix run` wrapper)

```sh
nix run .#bench-history -- --last 12 --reps 8
# scope to one bench while iterating, e.g.:
nix run .#bench-history -- --last 12 --reps 8 --benches transcript
```

This runs the pinned bench harness across git history and prints a trend table.
Only `lua/fibrous/` varies between columns (the harness and the runtime neovim
are held constant), so a jump in the newest column is a real regression in your
change. It reads the repo at `$PWD` and never writes it. Compare the newest
column against the prior commits. Any regression must be understood and either
justified or fixed before sign-off, not hand-waved. Include the trend table (or
the relevant rows) when reporting.

DEVELOPMENT.md explains the bench types and harnesses (the inline-host
micro-benchmarks, the transcript workload, and the real-PTY terminal-draw
harness) if you need to pick a more specific bench.

## 3. Update the docs

Docs live in the sibling repo `../fibrous-docs` (the site is itself built in
fibrous). Every behavioral or API-visible change must be mirrored there: the
component reference (`site/lua/webapp/components_ref.lua`), the API reference
(`api_ref.lua`), and the architecture pages as relevant. The docs suite must
pass:

```sh
cd ../fibrous-docs && nvim --headless -u NONE -i NONE -l tests/run.lua
```

**While you are in the docs, you are the docs reviewer.** If you notice anything
wrong (incorrect, outdated, inconsistent with the current code, poorly worded,
bad style, a stale example, a broken cross-reference), **even if it is entirely
unrelated to your current change**, you must at minimum **raise it with the
user**. Fix it if it is in scope and low-risk; otherwise flag it explicitly and
let the user decide. Never silently walk past a docs problem you saw.

---

### Notes

- Indentation: `lua/` uses tabs, `tests/` uses 2 spaces. There is no stylua
  config, so a bare `stylua` run will retab the specs. Don't.
- `../fibrous-docs` pins fibrous in its `flake.lock`. A docs *build* (as opposed
  to its local test run, which uses the sibling working tree) only sees your
  fibrous changes after you commit, push, and update its lock.
