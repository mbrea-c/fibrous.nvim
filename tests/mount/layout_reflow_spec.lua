local nr = require("nui-reactive")
local el = require("nui-reactive.components")

local function buf_with_line(text)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
        if line == text then
          return b
        end
      end
    end
  end
  return nil
end

local function win_with_line(text)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if line == text then
        return w
      end
    end
  end
  return nil
end

describe("layout reflow", function()
  it("renders nested containers (a row inside a column)", function()
    local function App()
      return {
        comp = el.col,
        props = {},
        children = {
          {
            comp = el.row,
            props = {},
            children = {
              { comp = el.text, props = { lines = { "a" } } },
              { comp = el.text, props = { lines = { "b" } } },
            },
          },
          { comp = el.text, props = { lines = { "c" } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 40, height = 10 } })

    -- a and b are in a row → same row, different columns.
    local aw, bw, cw = win_with_line("a"), win_with_line("b"), win_with_line("c")
    assert.is_not_nil(aw)
    assert.is_not_nil(bw)
    assert.is_not_nil(cw)
    local ac = vim.api.nvim_win_get_config(aw)
    local bc = vim.api.nvim_win_get_config(bw)
    local cc = vim.api.nvim_win_get_config(cw)
    assert.is_true(bc.col > ac.col, "b should sit right of a inside the row")
    assert.equal(ac.row, bc.row, "a and b share the row's top")
    assert.is_true(cc.row > ac.row, "c should sit below the row")

    handle.unmount()
  end)

  it("mounts a new window when a child is added, with no leaks when removed", function()
    local toggle
    local function App(ctx)
      local two = ctx.use_state(false)
      toggle = two
      local children = { { comp = el.text, props = { lines = { "first" } } } }
      if two.get() then
        children[2] = { comp = el.text, props = { lines = { "second" } } }
      end
      return { comp = el.col, props = {}, children = children }
    end

    local handle = nr.mount(App, {}, { size = { width = 30, height = 10 } })
    local one_child_wins = #vim.api.nvim_list_wins()
    assert.is_not_nil(buf_with_line("first"))
    assert.is_nil(buf_with_line("second"))

    toggle.set(true)
    assert.is_not_nil(buf_with_line("second"))
    assert.equal(one_child_wins + 1, #vim.api.nvim_list_wins(), "adding a child adds one window")

    toggle.set(false)
    assert.is_nil(buf_with_line("second"), "removed child's buffer is gone")
    assert.equal(one_child_wins, #vim.api.nvim_list_wins(), "removing a child closes its window (no leak)")

    handle.unmount()
  end)
end)
