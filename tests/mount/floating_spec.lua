local nr = require("nui-reactive")
local el = require("nui-reactive.components")

-- Find a valid buffer / window containing an exact line. Used to assert that
-- content actually reached a real Neovim buffer arranged by the layout.
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

describe("layout mount (floating)", function()
  it("renders a column of two text leaves into separate buffers", function()
    local function App()
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text, props = { lines = { "top" } } },
          { comp = el.text, props = { lines = { "bottom" } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 30, height = 8 } })

    assert.is_not_nil(buf_with_line("top"))
    assert.is_not_nil(buf_with_line("bottom"))

    handle.unmount()
  end)

  it("arranges a row so children sit at different columns", function()
    local function App()
      return {
        comp = el.row,
        props = {},
        children = {
          { comp = el.text, props = { lines = { "left" } } },
          { comp = el.text, props = { lines = { "right" } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 40, height = 6 } })

    local lw, rw = win_with_line("left"), win_with_line("right")
    assert.is_not_nil(lw)
    assert.is_not_nil(rw)
    local lcol = vim.api.nvim_win_get_config(lw).col
    local rcol = vim.api.nvim_win_get_config(rw).col
    assert.is_true(rcol > lcol, "right child should sit to the right of the left child")

    handle.unmount()
  end)

  it("updates a leaf buffer when state changes (no recreate)", function()
    local setter
    local function App(ctx)
      local s = ctx.use_state("hello")
      setter = s
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text, props = { lines = { s.get() } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 30, height = 5 } })
    assert.is_not_nil(buf_with_line("hello"))

    setter.set("changed")

    assert.is_not_nil(buf_with_line("changed"))
    assert.is_nil(buf_with_line("hello"))

    handle.unmount()
  end)

  it("removes all windows on unmount", function()
    local function App()
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text, props = { lines = { "x-marker" } } },
        },
      }
    end

    local before = #vim.api.nvim_list_wins()
    local handle = nr.mount(App, {}, { size = { width = 20, height = 4 } })
    assert.is_true(#vim.api.nvim_list_wins() > before)

    handle.unmount()

    assert.equal(before, #vim.api.nvim_list_wins())
    assert.is_nil(buf_with_line("x-marker"))
  end)
end)
