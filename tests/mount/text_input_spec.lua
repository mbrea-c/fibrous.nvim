local nr = require("nui-reactive")
local el = require("nui-reactive.components")

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Simulate the user editing the input buffer: replace its text and fire the
-- change event Neovim would emit, exercising the bridge's autocmd wiring without
-- depending on a real insert-mode key loop in headless.
local function simulate_edit(bufnr, text)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
end

describe("text_input", function()
  it("renders with its initial value", function()
    local ref = nil
    local function App(ctx)
      ref = ref or ctx.use_ref()
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text_input, props = { value = "hello", ref = ref } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 20, height = 4 } })

    assert.equal("hello", buf_text(ref.current.bufnr))

    handle.unmount()
  end)

  it("reports edits via on_change without clobbering the buffer (uncontrolled)", function()
    local changes = {}
    local ref
    local function App(ctx)
      local value = ctx.use_state("")
      ref = ref or ctx.use_ref()
      return {
        comp = el.col,
        props = {},
        children = {
          {
            comp = el.text_input,
            props = {
              value = value.get(),
              ref = ref,
              on_change = function(v)
                changes[#changes + 1] = v
                value.set(v) -- state mirrors the buffer; must NOT rewrite it
              end,
            },
          },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 30, height = 4 } })

    simulate_edit(ref.current.bufnr, "typed text")

    assert.same({ "typed text" }, changes)
    assert.equal("typed text", buf_text(ref.current.bufnr), "the re-render must not clobber what was typed")

    handle.unmount()
  end)

  it("fires on_submit with the buffer text on <CR>", function()
    local submitted
    local ref
    local function App(ctx)
      ref = ref or ctx.use_ref()
      return {
        comp = el.col,
        props = {},
        children = {
          {
            comp = el.text_input,
            props = { ref = ref, on_submit = function(v) submitted = v end },
          },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 30, height = 4 } })

    simulate_edit(ref.current.bufnr, "send me")
    -- Invoke the buffer-local <CR> mapping the bridge installed (deterministic;
    -- avoids feedkeys timing in headless).
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(ref.current.bufnr, "n")) do
      if map.lhs == "<CR>" and map.callback then
        map.callback()
      end
    end

    assert.equal("send me", submitted)

    handle.unmount()
  end)

  it("focus() moves editor focus into the input window", function()
    local ref
    local function App(ctx)
      ref = ref or ctx.use_ref()
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text_input, props = { value = "x", ref = ref } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 20, height = 4 } })

    handle.focus()

    assert.equal(ref.current.winid, vim.api.nvim_get_current_win())

    handle.unmount()
  end)
end)
