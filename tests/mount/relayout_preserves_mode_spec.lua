local nr = require("fibrous")
local el = require("fibrous.components")

-- A relayout (structural change, or a host-pane resize) must not yank the user
-- out of visual mode. nui's float relayout historically ran a workaround that
-- switched the current window and moved the cursor on every update, which exits
-- visual mode and flashes the screen. This pins that a relayout leaves the
-- editor mode untouched.
describe("relayout preserves editor mode", function()
  it("keeps the user in visual mode across a structural relayout", function()
    local ref, toggle
    local function App(ctx)
      local show = ctx.use_state(false)
      toggle = show
      local children = {
        { comp = el.text, props = { grow = 1, focusable = true, ref = ref, lines = { "alpha", "beta", "gamma" } } },
      }
      if show.get() then
        children[#children + 1] = { comp = el.text, props = { size = 2, lines = { "extra" } } }
      end
      return { comp = el.col, props = {}, children = children }
    end
    ref = nil
    local function App2(ctx)
      ref = ref or ctx.use_ref()
      return App(ctx)
    end

    local handle = nr.mount(App2, {}, { size = { width = 30, height = 8 } })

    -- Land in the focusable leaf and start a visual selection.
    vim.api.nvim_set_current_win(ref.current.winid)
    vim.cmd("normal! ggvj")
    assert.equal("v", vim.api.nvim_get_mode().mode, "precondition: should be in visual mode")

    -- Force a structural relayout (adds a region → layout:update).
    toggle.set(true)
    vim.wait(60) -- let any scheduled relayout work run

    assert.equal("v", vim.api.nvim_get_mode().mode, "relayout must not exit visual mode")

    vim.cmd("normal! \27") -- leave visual mode before teardown
    handle.unmount()
  end)
end)
