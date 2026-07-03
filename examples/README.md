# fibrous examples

Small, self-contained sample UIs you can run in a clean Neovim — no user config
or other plugins involved, just this library.

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

| Name                | Mount target    | Demonstrates                                                                    |
| ------------------- | --------------- | ------------------------------------------------------------------------------- |
| `hello`             | floating        | a function component → bordered `col` of labels; static render                  |
| `counter`           | floating        | `use_state` + `use_effect`; buttons (`<CR>`/`<Space>`) and external keymaps     |
| `form`              | floating        | uncontrolled `text_input`: live `on_change` mirror, `<CR>` submit, cursor focus |
| `sidebar`           | split           | `mount_split`; a cursor-driven list (hover follows `j`/`k`, `<CR>` selects)     |
| `panel`             | split           | ACP-shaped flex layout, a user-defined hook, a checkbox plan, prompt input      |
| `inline_scroll`     | split (scroll)  | website-style page: wrapped sections, clipped input floats, focus traversal     |
| `inline_fullscreen` | window (scroll) | the same page mounted fullscreen over the current window                        |

Everything renders through the inline host: the UI is text + extmarks in ONE
unmodifiable buffer, the vim cursor drives hover/activation, and only the text
inputs are real editable floats (focus follows the cursor in and out of them).

`util.lua` is just glue shared by the examples (binds global keymaps to an app
handle and clears them on unmount) — it is not part of the library.
