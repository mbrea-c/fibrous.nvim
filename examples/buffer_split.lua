-- Buffer-mount demo: a split pane that renders into ITSELF.
--
-- Every other pane-based mount (mount_split, mount_window) covers the pane with
-- a relative="win" float and draws there, so the layout holds two windows per
-- app: the inert pane and the float over it. `render = "buffer"` drops the
-- float and puts the host buffer straight in the pane.
--
-- What you can actually observe here, versus running :Example sidebar:
--   * `:echo winnr('$')` counts one window for this app, not two.
--   * `<C-w>w` cycles onto the app itself rather than onto a blank pane that
--     silently forwards focus.
--   * `<C-w>>` / `<C-w><` resizes and rewraps with no float geometry to
--     resync (measurably cheaper in redraw bytes; see design-buffer-mount.md).
--
-- Subwindow leaves (the text_input below) still are floats, and still track
-- the pane as it resizes. That part is unchanged: what went away is the ROOT
-- float, not the widget floats.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local function Panel(ctx)
  local notes = ctx.use_state({ "resize me with <C-w>> and <C-w><" })
  local draft = ctx.use_state("")
  local typing = draft.get()

  local children = {
    { comp = ui.label, props = { text = "Buffer mount", style = { text_hl = "Title" } } },
    { comp = ui.label, props = { text = "renders INTO the pane, no float", style = { text_hl = "Comment" } } },
    { comp = ui.label, props = { text = "" } },
  }

  for i, note in ipairs(notes.get()) do
    children[#children + 1] = {
      comp = ui.label,
      props = {
        text = ("%d. %s"):format(i, note),
        role = "button",
        -- clicking a note drops it, so the canvas reflows in place
        on_press = function()
          local rest = {}
          for j, n in ipairs(notes.get()) do
            if j ~= i then
              rest[#rest + 1] = n
            end
          end
          notes.set(rest)
        end,
        style = { _hover = { hl = "Visual" } },
        align_self = "start",
      },
    }
  end

  vim.list_extend(children, {
    { comp = ui.label, props = { text = "" } },
    -- a real editable float, anchored over an ordinary window rather than
    -- over a root float: the case the mount type had to get right
    {
      comp = ui.label,
      -- <CR> submits in NORMAL mode only, by design: in insert it stays a
      -- plain newline so a prompt can compose multi-line. Hence <Esc> first.
      props = { text = "note: i types, <Esc><CR> commits", style = { text_hl = "Comment" } },
    },
    {
      comp = ui.text_input,
      props = {
        -- height 3, not 1: a bordered single-line input needs the two border
        -- rows on top of its one text row
        height = 3,
        style = { border = "rounded" },
        clear_on_submit = true,
        on_change = function(v)
          draft.set(v)
        end,
        on_submit = function(value)
          if value == "" then
            return
          end
          local next_notes = vim.deepcopy(notes.get())
          next_notes[#next_notes + 1] = value
          notes.set(next_notes)
          draft.set("")
        end,
      },
    },
    {
      comp = ui.label,
      props = { text = ("draft: %d chars"):format(#typing), style = { text_hl = "FibrousDim" } },
    },
    { comp = ui.label, props = { text = "" } },
    { comp = ui.label, props = { text = "<CR> on a note deletes it", style = { text_hl = "Comment" } } },
    { comp = ui.label, props = { text = "<C-w>w cycles ONTO this app", style = { text_hl = "Comment" } } },
    { comp = ui.label, props = { text = "q closes", style = { text_hl = "Comment" } } },
  })

  return { comp = ui.col, props = { style = { padding = { x = 1, y = 1 } } }, children = children }
end

local M = {}

function M.run()
  local handle = nr.mount_split(Panel, {}, {
    render = "buffer",
    split = { direction = "vertical", position = "left", size = 40 },
  })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
