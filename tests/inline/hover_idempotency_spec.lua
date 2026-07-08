-- Hover repaint must be idempotent (requests.md: "Hovering a tool call on the
-- transcript while the transcript is unfocused causes a flurry of redraws").
--
-- The transcript is a CONTAINER: focus is on the root, whose cursor points at a
-- tool call inside the container. The root's on_flush re-runs interact.update()
-- every flush, which drives parent hover across the boundary (subwins.hover_at →
-- the container's own interact.update). When an animation elsewhere (weave's
-- water) flushes each frame, that re-drove the container's hover — tearing down
-- and re-setting its overlay every frame though nothing under the cursor moved:
-- a redraw per frame (the ssh+tmux flicker). A flush that changes nothing under
-- the pointer must leave the hover overlay (and the container cursor) alone.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local NS = vim.api.nvim_create_namespace("fibrous_inline_hover")

-- Count nvim_buf_set_extmark calls into the hover namespace while `fn` runs.
local function count_hover_marks(fn)
  local n = 0
  local orig = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(buf, ns, ...)
    if ns == NS then
      n = n + 1
    end
    return orig(buf, ns, ...)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_buf_set_extmark = orig
  assert(ok, err)
  return n
end

local function move_root_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

describe("inline hover idempotency (parent-driven, across a container boundary)", function()
  local tick = 0
  local function App()
    return {
      comp = ui.col,
      props = {},
      children = {
        -- a bystander whose text ticks — stands in for weave's water animation
        { comp = ui.label, props = { text = "tick " .. tick } },
        {
          comp = ui.container,
          props = {},
          children = {
            { comp = ui.button, props = { label = "hover me", style = { _hover = { hl = "Search" } } } },
          },
        },
      },
    }
  end

  it("re-driven parent hover does not repaint when the pointer is stationary", function()
    tick = 0
    local handle = mount.floating(App, {}, { width = 24, height = 8 })
    vim.api.nvim_set_current_win(handle.winid) -- root focused; container is NOT
    move_root_cursor(handle, 2, 1) -- the container's content row → over the button

    -- flushes that don't move the pointer (the bystander re-renders each frame)
    local marks = count_hover_marks(function()
      for i = 1, 5 do
        tick = i
        handle.set_props({})
      end
    end)

    assert.equal(0, marks, "container hover repainted on stationary flushes (" .. marks .. " repaints)")
    handle.unmount()
  end)

  it("still repaints hover when the pointer moves to a new node", function()
    tick = 0
    local function TwoButtons()
      return {
        comp = ui.container,
        props = {},
        children = {
          { comp = ui.button, props = { label = "one", style = { _hover = { hl = "Search" } } } },
          { comp = ui.button, props = { label = "two", style = { _hover = { hl = "Search" } } } },
        },
      }
    end
    local handle = mount.floating(TwoButtons, {}, { width = 24, height = 8 })
    vim.api.nvim_set_current_win(handle.winid)
    move_root_cursor(handle, 1, 1) -- over button "one"

    local marks = count_hover_marks(function()
      move_root_cursor(handle, 2, 1) -- move down to button "two"
    end)
    assert.is_true(marks > 0, "moving the pointer to a new node must repaint the hover")
    handle.unmount()
  end)
end)
