-- Inline host spike demo (tracker "NEW UI HOST" tasks 4–6). A website-style
-- scroll-mode UI mounted over a split pane: wrapped paragraphs, buttons and
-- checkboxes render inline into the ONE root-float buffer, while the text
-- inputs are real editable floats clipped against the viewport as you scroll.
--
-- What to evaluate:
--   * j/k/<C-d>/<C-u>/gg/G — do the input floats "swim" noticeably? WinScrolled
--     fires post-redraw, so they trail the scroll by one frame by design
--     (task 4b verdict decides whether float-on-focus gets promoted).
--   * Scroll an input half off the top/bottom edge: it should clip to its
--     visible rows (top clip also scrolls the input's own viewport).
--   * Scroll an input fully off: it should vanish, and return on the way back.
--   * Move the cursor over the button/checkboxes: hover bar follows the
--     cursor; <CR>/<Space> press/toggle.
--   * <C-w>> / <C-w>< resize the pane: everything rewraps and re-anchors.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local util = require("examples.util")

local LOREM = "The quick brown fox jumps over the lazy dog while the five boxing "
  .. "wizards jump quickly, and pack my box with five dozen liquor jugs."

local function section(i)
  return {
    comp = ui.paragraph,
    props = { text = ("Section %d\n\n%s"):format(i, LOREM), border = "single", padding = { x = 1 } },
  }
end

local function App(ctx)
  local clicks = ctx.use_state(0)
  local opts = ctx.use_state({ a = false, b = true })

  local function toggle(key)
    return function(v)
      local cur = vim.tbl_extend("force", {}, opts.get())
      cur[key] = v
      opts.set(cur)
    end
  end

  local children = {
    { comp = ui.label, props = { text = "Inline host — interactive scroll spike", hl = "Title" } },
    { comp = ui.label, props = { text = "j/k <C-d>/<C-u> scroll · <CR>/<Space> activate · q closes", hl = "Comment" } },
    section(1),
    {
      comp = ui.button,
      props = {
        label = ("clicked %d times"):format(clicks.get()),
        on_press = function()
          clicks.set(clicks.get() + 1)
        end,
      },
    },
    { comp = ui.checkbox, props = { label = "option a", checked = opts.get().a, on_toggle = toggle("a") } },
    { comp = ui.checkbox, props = { label = "option b", checked = opts.get().b, on_toggle = toggle("b") } },
    section(2),
    {
      comp = ui.text_input,
      props = { border = "rounded", value = "single-line input — edit me" },
    },
  }
  for i = 3, 5 do
    children[#children + 1] = section(i)
  end
  children[#children + 1] = {
    comp = ui.text_input,
    props = { border = "double", height = 5, value = "multi\nline\ninput" },
  }
  for i = 6, 8 do
    children[#children + 1] = section(i)
  end
  return { comp = ui.col, props = { gap = 1, padding = 1 }, children = children }
end

local M = {}

function M.run()
  local handle = mount.split(App, {}, {
    split = { direction = "vertical", position = "left", size = 46 },
    mode = "scroll",
  })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
