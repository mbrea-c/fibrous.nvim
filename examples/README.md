# nui-reactive examples

Small, self-contained sample UIs you can run in a clean Neovim — no user config
or other plugins involved, just this library and its vendored copy of `nui`.

## Running

From the repo root:

```sh
make example              # opens an isolated Neovim; then :Examples / :Example <name>
make example EX=counter   # opens and runs the counter example straight away
```

Or launch it yourself (the `--clean -u` pair is what makes it isolated):

```sh
nvim --clean -u examples/init.lua
```

Then, inside Neovim:

- `:Examples` — list the available examples
- `:Example <name>` — run one (Tab-completes the name)

Each example maps **`q`** (normal mode) to close it. Running another example
closes the current one first.

## The examples

| Name      | Mount target            | Demonstrates                                                            |
| --------- | ----------------------- | ----------------------------------------------------------------------- |
| `hello`   | floating (§3A)          | a function component → `col` + bordered `text` leaf; static render      |
| `counter` | floating (§3A)          | `use_state` + `use_effect`; external keymaps drive state (`+`/`-`/`r`)  |
| `form`    | floating (§3A)          | uncontrolled `text_input` (§5.3): live `on_change` mirror, `<CR>` submit |
| `sidebar` | native split (§3B)      | `mount_as_window_host`: pane-anchored overlays, geometry sync, `j`/`k`  |

`util.lua` is just glue shared by the examples (binds global keymaps to an app
handle and clears them on unmount) — it is not part of the library.
