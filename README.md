# fibrous.nvim

A declarative, component-based, React-like UI framework for Neovim plugins. It
brings a VDOM, hooks, and subtree reconciliation to Neovim UI development, and
renders component trees inline: text + extmarks in one unmodifiable buffer, with
a CSS-like box model, cursor-driven hover/activation, and real editable floats
only where a native buffer is needed (text inputs, raw buffers).

## Docs and live demo

As a showcase of what this library can do, the documentation site is created in
fibrous itself, and runs in your browser using a WASM-compiled version of
Neovim! Access it [here](https://mbrea-c.github.io/fibrous-docs/). There are
interactive, hot-reloadable examples to play around with.

## Examples

Runnable sample UIs live in [`examples/`](examples/). They open in a clean,
isolated Neovim (no user config or other plugins):

```sh
make example              # opens Neovim; then :Examples / :Example <name>
make example EX=counter   # opens and runs one example directly
```

See [`examples/README.md`](examples/README.md) for the full list.

## Nix

The flake packages the plugin and wraps the dev entry points (no local `nvim`
needed):

```sh
nix run .                                     # examples browser (same as .#example)
nix run .#example -- counter                  # open one example directly
nix run .#test                                # the full test suite
nix run .#test -- tests/inline/host_spec.lua  # one spec file
nix run .#bench                               # inline host benchmarks (BENCH_N=… env)
nix flake check                               # suite as a sandboxed check
```

Apps run against the flake's snapshot of the source (i.e. what's committed or
staged) — use the `make` targets against the working tree during development.
The plugin itself is `packages.<system>.default` (built with
`vimUtils.buildVimPlugin`), ready for `programs.neovim.plugins` or any pack
path; the raw source tree is also a valid plugin directory (`lua/` at the
root), so flake inputs can be consumed directly.

## Development

This project is built with **red-green TDD**: write a failing test, make it pass
with the smallest change, then refactor. The reactive core is pure Lua with no
dependency on the Neovim API, so it is fully unit-testable.

### Requirements

- `nvim` (0.10+) on your `PATH`. That's it — there are no external Lua/test
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
