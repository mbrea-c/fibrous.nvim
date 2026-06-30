local nr = require("fibrous")
local el = require("fibrous.components")
local Layout = require("nui.layout")

-- Spy on nui.layout's relayout. `commit` must only call it when the Box tree's
-- geometry (structure + sizing) changes — never for content-only re-renders.
-- This pins the flicker fix: typing into an input re-renders the tree on every
-- keystroke, and an unconditional layout:update reflowed every float (collapsing
-- columns for a frame). Content commits should now skip relayout entirely.
local function with_update_spy(fn)
  local original = Layout.update
  local count = 0
  Layout.update = function(self, ...)
    count = count + 1
    return original(self, ...)
  end
  local ok, err = pcall(fn, function()
    return count
  end)
  Layout.update = original
  if not ok then
    error(err)
  end
end

describe("relayout memoization", function()
  it("does NOT relayout on a content-only re-render", function()
    with_update_spy(function(updates)
      local setter
      local function App(ctx)
        local s = ctx.use_state({ "one" })
        setter = s
        return {
          comp = el.col,
          props = {},
          children = {
            { comp = el.text, props = { grow = 1, lines = s.get() } },
          },
        }
      end

      local handle = nr.mount(App, {}, { size = { width = 30, height = 6 } })
      local baseline = updates()

      -- Change only buffer content; geometry (one grow=1 text in a col) is identical.
      setter.set({ "one", "two", "three" })

      assert.equal(baseline, updates(), "content-only change must not relayout")

      handle.unmount()
    end)
  end)

  it("DOES relayout when the structure/sizing changes", function()
    with_update_spy(function(updates)
      local setter
      local function App(ctx)
        local show = ctx.use_state(false)
        setter = show
        local children = { { comp = el.text, props = { grow = 1, lines = { "a" } } } }
        if show.get() then
          children[#children + 1] = { comp = el.text, props = { size = 2, lines = { "b" } } }
        end
        return { comp = el.col, props = {}, children = children }
      end

      local handle = nr.mount(App, {}, { size = { width = 30, height = 6 } })
      local baseline = updates()

      -- Add a second region: the Box tree changes shape, so a relayout is required.
      setter.set(true)

      assert.is_true(updates() > baseline, "structural change must relayout")

      handle.unmount()
    end)
  end)
end)
