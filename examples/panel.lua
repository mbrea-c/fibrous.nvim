-- A richer, ACP-client-shaped panel, to exercise the flex layout the way the
-- real target does. The layout mirrors the agentic client's shell:
--
--   row
--   ├── col (grow=1)             main conversation column
--   │   ├── col   (grow=1)         transcript        ← flexes to fill height
--   │   ├── label (1 row)          status line
--   │   └── text_input (3 rows)    prompt            ← a real editable float
--   └── col (width=26)           metadata sidebar (fixed width)
--       ├── col  (6 rows)          session info
--       └── Plan (grow=1)          a to-do list of checkboxes
--
-- It is mounted over a docked split (`mount_split`). It also demonstrates:
--   * a user-defined hook (`use_plan`) composed from use_state, and
--   * cursor-driven interaction replacing the old scoped keymaps: navigation
--     IS cursor motion — park on the prompt and press i (or <CR>) to type,
--     move onto a plan item and <Space> toggles it.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

-- A user-defined hook: a toggleable to-do list. Nothing special — just a
-- function taking `ctx` and composing the built-in hooks. This is exactly how
-- a consumer factors reusable stateful logic out of a component.
local function use_plan(ctx, initial)
  local items = ctx.use_state(initial)
  return {
    items = items.get(),
    toggle = function(i)
      local next_items = vim.deepcopy(items.get())
      if next_items[i] then
        next_items[i].done = not next_items[i].done
        items.set(next_items)
      end
    end,
  }
end

-- A themed border captioned via the border-embedded title slot ("Style
-- rework" S3): the title paints over the top edge, no content row spent on
-- it. Chars come from the theme's default preset, the title hl from
-- FibrousTitle — nothing to specify but the text.
local function titled_border(title)
  return { nr.theme.border_preset, title = title }
end

-- The plan list: one checkbox per item. j/k are native cursor motions and
-- <Space> toggles the checkbox under the cursor — the hit-map scopes the
-- interaction, no component keymaps needed.
local function Plan(_, props)
  local children = {}
  for i, item in ipairs(props.items) do
    children[#children + 1] = {
      comp = ui.checkbox,
      props = {
        label = item.text,
        checked = item.done,
        on_toggle = function() props.on_toggle(i) end,
      },
    }
  end
  return {
    comp = ui.col,
    props = { grow = 1, style = { padding = { x = 1 }, border = titled_border("Plan (<Space> toggles)") } },
    children = children,
  }
end

local function Panel(ctx, props)
  local transcript = ctx.use_state({ "Welcome. Type a message below, press <CR> to send." })
  local draft = ctx.use_state(0)
  local plan = use_plan(ctx, props.initial_plan)

  local function submit(text)
    if text == "" then
      return
    end
    local lines = vim.deepcopy(transcript.get())
    lines[#lines + 1] = "› " .. text
    transcript.set(lines)
    draft.set(0)
    -- on_submit fires from the prompt float's <CR> map, so the prompt buffer
    -- is the current one: clear it for the next message.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
  end

  local status = (" draft: %d chars   ·   cursor moves focus   ·   q quits"):format(draft.get())

  return {
    comp = ui.row,
    props = {},
    children = {
      {
        comp = ui.col,
        props = { grow = 1 },
        children = {
          {
            comp = ui.col,
            props = { grow = 1, style = { padding = { x = 1 }, border = titled_border("Conversation") } },
            children = {
              { comp = ui.label, props = { text = table.concat(transcript.get(), "\n") } },
            },
          },
          { comp = ui.label, props = { text = status, style = { text_hl = "FibrousDim" } } },
          {
            comp = ui.text_input,
            props = {
              height = 3,
              style = { border = true },
              on_change = function(v) draft.set(#v) end,
              on_submit = submit,
            },
          },
        },
      },
      {
        comp = ui.col,
        props = { width = 26 },
        children = {
          {
            comp = ui.col,
            props = { height = 5, style = { padding = { x = 1 }, border = titled_border("Session") } },
            children = {
              { comp = ui.label, props = { text = "model   claude-opus-4-8" } },
              { comp = ui.label, props = { text = "cwd     ~/src/fibrous" } },
              { comp = ui.label, props = { text = "status  ● ready" } },
            },
          },
          {
            comp = Plan,
            props = {
              items = plan.items,
              on_toggle = plan.toggle,
            },
          },
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount_split(Panel, {
    initial_plan = {
      { text = "Spec the flex layout", done = true },
      { text = "Wire the prompt input", done = true },
      { text = "Port to the inline host", done = false },
      { text = "Polish the borders", done = false },
    },
  }, {
    split = { direction = "vertical", position = "right", size = 74 },
  })

  handle.focus()

  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "quit panel" } },
  })
end

return M
