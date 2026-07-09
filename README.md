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

![Demo showcasing this UI library](./demo_optimized.gif)

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
staged). Use the `make` targets against the working tree during development.

The plugin itself is also exposed as a flake output: `packages.<system>.default`
(built with `vimUtils.buildVimPlugin`).
