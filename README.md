# fibrous.nvim

A declarative, component-based, React-like UI framework for Neovim plugins,
built on top of [`nui.nvim`](https://github.com/MunifTanjim/nui.nvim). It brings
a VDOM, hooks, and subtree reconciliation to Neovim UI development. See
[`design.md`](design.md) for the architecture.

## Examples

Runnable sample UIs live in [`examples/`](examples/). They open in a clean,
isolated Neovim (no user config or other plugins):

```sh
make example              # opens Neovim; then :Examples / :Example <name>
make example EX=counter   # opens and runs one example directly
```

See [`examples/README.md`](examples/README.md) for the full list.

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
