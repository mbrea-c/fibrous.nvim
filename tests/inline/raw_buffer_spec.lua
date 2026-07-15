-- raw_buffer: the escape hatch for content the inline canvas can't express
-- (tracker "NEW UI HOST" task 7). A subwindow leaf like text_input, but it
-- shows a caller-provided buffer (props.bufnr) instead of an owned scratch
-- one. The buffer is UNOWNED: unmount removes our keymaps/autocmds but leaves
-- the buffer alive. Without props.bufnr the manager creates an owned scratch
-- buffer (destroyed as usual). Default height is the buffer's line count;
-- explicit props.height wins.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function subwin_of(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid then
      -- editor-anchored floats: reconstruct row/col in ROOT coordinates,
      -- what this spec asserts against
      local cfg = vim.api.nvim_win_get_config(win)
      if not cfg.hide then
        local fp = vim.api.nvim_win_get_position(win)
        local rp = vim.api.nvim_win_get_position(handle.winid)
        cfg.row, cfg.col = fp[1] - rp[1], fp[2] - rp[2]
      end
      return win, cfg
    end
  end
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

describe("inline.raw_buffer", function()
  it("shows the given buffer in a float sized to its line count", function()
    local bufnr = make_buf({ "one", "two", "three" })
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          -- render="always": this test asserts the SHOWN float's placement
          { comp = ui.raw_buffer, props = { bufnr = bufnr, render = "always" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 4 })

    local sub, cfg = subwin_of(handle)
    assert.is_not_nil(sub)
    assert.equal(bufnr, vim.api.nvim_win_get_buf(sub))
    assert.equal(1, cfg.row) -- under the head label
    assert.equal(3, cfg.height) -- defaults to the buffer's line count

    handle.unmount()
  end)

  it("explicit height wins over the line count", function()
    local bufnr = make_buf({ "one", "two", "three" })
    local function App()
      -- inside a col — a lone root node would be stretched to the viewport
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.raw_buffer, props = { bufnr = bufnr, height = 2, render = "always" } },
          { comp = ui.label, props = { text = "tail" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 4 })

    local _, cfg = subwin_of(handle)
    assert.equal(2, cfg.height)

    handle.unmount()
  end)

  it("the buffer is unowned: unmount leaves it alive with our keymaps removed", function()
    local bufnr = make_buf({ "one", "two" })
    local function App()
      return { comp = ui.raw_buffer, props = { bufnr = bufnr } }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 2 })

    -- while mounted, the traversal maps are on the buffer
    local mapped = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      mapped[m.lhs] = true
    end
    assert.is_true(mapped["j"])

    handle.unmount()
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      assert.is_false(m.lhs == "j")
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("without props.bufnr an owned scratch buffer is created and destroyed", function()
    local function App()
      return { comp = ui.raw_buffer, props = { height = 2 } }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 2 })

    local sub = subwin_of(handle)
    assert.is_not_nil(sub)
    local bufnr = vim.api.nvim_win_get_buf(sub)

    handle.unmount()
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)
end)
