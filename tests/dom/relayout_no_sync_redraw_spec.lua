local nr = require("fibrous")
local el = require("fibrous.components")

-- A relayout must not force a synchronous screen redraw while it is still
-- repositioning windows. nui's float layout places regions in two passes (fixed
-- sizes first — transiently at col 0 — then the growable ones, then the fixed
-- ones shifted right). If anything calls `:redraw` mid-sweep, that half-built
-- state paints: the sidebar flashes on the left and the main column looks
-- zero-width. nui's bordered popups used to `:redraw` on every border relayout,
-- causing exactly this. The single, correct repaint happens once after the
-- sweep, on the scheduler. This pins that no synchronous redraw escapes a commit.
local function count_sync_redraws_during(fn)
  local original = vim.api.nvim_command
  local count = 0
  vim.api.nvim_command = function(cmd, ...)
    if type(cmd) == "string" and cmd:match("^%s*redraw") then
      count = count + 1
    end
    return original(cmd, ...)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_command = original
  if not ok then
    error(err)
  end
  return count
end

describe("relayout does not flicker mid-sweep", function()
  it("issues no synchronous redraw while a structural relayout runs", function()
    local toggle
    local function App(ctx)
      local show = ctx.use_state(false)
      toggle = show
      local children = {
        { comp = el.text, props = { grow = 1, border = { style = "rounded", text = { top = " titled " } }, lines = { "main" } } },
      }
      if show.get() then
        children[#children + 1] = { comp = el.text, props = { size = 8, border = { style = "rounded", text = { top = " titled " } }, lines = { "side" } } }
      end
      return { comp = el.row, props = {}, children = children }
    end

    local handle = nr.mount(App, {}, { size = { width = 40, height = 10 } })

    -- The relayout happens synchronously inside set(); no redraw may escape it.
    local redraws = count_sync_redraws_during(function()
      toggle.set(true)
    end)

    assert.equal(0, redraws, "a relayout must not synchronously redraw the screen mid-sweep")

    handle.unmount()
  end)
end)
