-- A richer, ACP-client-shaped panel, to exercise the flex layout the way the
-- real target does. The layout mirrors the agentic client's shell:
--
--   row
--   ├── col (grow=1)            main conversation column
--   │   ├── text  (grow=1)        transcript        ← flexes to fill height
--   │   ├── text  (size=1)        status line       ← fixed one row
--   │   └── text_input (size=3)   prompt            ← fixed three rows
--   └── col (size=26)          metadata sidebar (fixed width)
--       ├── text (size=6)         session info
--       └── Plan (grow=1)         a focusable, navigable to-do list
--
-- It is mounted as a docked split (design.md §3B). It also demonstrates:
--   * a user-defined hook (`use_list`) composed from use_state, and
--   * component-scoped keymaps (`use_keymap`) on the Plan list — j/k/<Space>
--     fire only while the plan window is focused, because the hook binds them
--     across that component's subtree (not globally).

local nr = require("fibrous")
local el = require("fibrous.components")
local use_keymap = nr.hooks.use_keymap
local util = require("examples.util")

-- A user-defined hook: a selectable, toggleable list. Nothing special — just a
-- function taking `ctx` and composing the built-in hooks. This is exactly how a
-- consumer factors reusable stateful logic out of a component.
local function use_list(ctx, initial)
  local items = ctx.use_state(initial)
  local index = ctx.use_state(1)
  return {
    items = items.get(),
    index = index.get(),
    move = function(delta)
      local n = #items.get()
      if n > 0 then
        index.set(math.max(1, math.min(n, index.get() + delta)))
      end
    end,
    toggle = function()
      local next_items = vim.deepcopy(items.get())
      local cur = next_items[index.get()]
      if cur then
        cur.done = not cur.done
        items.set(next_items)
      end
    end,
  }
end

-- A bordered box with a title — a small helper so the boxes read like the ACP
-- panel's labelled regions.
local function titled(title)
  return { style = "rounded", text = { top = " " .. title .. " ", top_align = "left" } }
end

-- The plan list lives in its own component so its keymaps are scoped to its
-- window: j/k move the selection, <Space> toggles the highlighted item — but
-- only while this list is focused (<Tab> from the prompt).
local function Plan(ctx, props)
  use_keymap(ctx, { mode = "n", lhs = "j", rhs = function() props.on_move(1) end, desc = "next item" })
  use_keymap(ctx, { mode = "n", lhs = "k", rhs = function() props.on_move(-1) end, desc = "prev item" })
  use_keymap(ctx, { mode = "n", lhs = "<Space>", rhs = props.on_toggle, desc = "toggle item" })

  local lines = {}
  for i, item in ipairs(props.items) do
    local mark = item.done and "[x]" or "[ ]"
    local cursor = (i == props.index) and "▸ " or "  "
    lines[#lines + 1] = cursor .. mark .. " " .. item.text
  end

  return {
    comp = el.text,
    props = { grow = 1, focusable = true, ref = props.ref, border = titled("Plan  (j/k/space)"), lines = lines },
  }
end

local function Panel(ctx, props)
  local transcript = ctx.use_state({ "Welcome. Type a message below, press <CR> to send.", "" })
  local draft = ctx.use_state(0)
  local plan = use_list(ctx, props.initial_plan)

  local prompt_ref = ctx.use_ref()
  local plan_ref = ctx.use_ref()

  -- Publish focus-cycling to the outside (the <Tab> global keymap) once.
  ctx.use_effect(function()
    props.actions.current.cycle = function()
      local cur = vim.api.nvim_get_current_win()
      local plan_win = plan_ref.current and plan_ref.current.winid
      local prompt_win = prompt_ref.current and prompt_ref.current.winid
      if cur == plan_win and prompt_win then
        vim.api.nvim_set_current_win(prompt_win)
        vim.cmd("startinsert")
      elseif plan_win then
        vim.api.nvim_set_current_win(plan_win)
      end
    end
  end, {})

  local function submit(text)
    if text == "" then
      return
    end
    local lines = vim.deepcopy(transcript.get())
    lines[#lines + 1] = "› " .. text
    transcript.set(lines)
    draft.set(0)
    local bufnr = prompt_ref.current and prompt_ref.current.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end
  end

  local status = (" draft: %d chars   ·   <Tab> focus list   ·   q quit"):format(draft.get())

  return {
    comp = el.row,
    props = {},
    children = {
      {
        comp = el.col,
        props = { grow = 1 },
        children = {
          { comp = el.text, props = { grow = 1, border = titled("Conversation"), lines = transcript.get() } },
          { comp = el.text, props = { size = 1, lines = { status } } },
          {
            comp = el.text_input,
            props = {
              size = 3,
              border = titled("Prompt"),
              ref = prompt_ref,
              on_change = function(v) draft.set(#v) end,
              on_submit = submit,
            },
          },
        },
      },
      {
        comp = el.col,
        props = { size = 26 },
        children = {
          {
            comp = el.text,
            props = {
              size = 6,
              border = titled("Session"),
              lines = { "", " model   claude-opus-4-8", " cwd     ~/src/fibrous", " status  ● ready" },
            },
          },
          {
            comp = Plan,
            props = {
              ref = plan_ref,
              items = plan.items,
              index = plan.index,
              on_move = plan.move,
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
  local actions = { current = {} }
  local handle = nr.mount_as_window_host(Panel, {
    actions = actions,
    initial_plan = {
      { text = "Spec the flex layout", done = true },
      { text = "Wire the prompt input", done = true },
      { text = "Scope the list keymaps", done = false },
      { text = "Polish the borders", done = false },
    },
  }, {
    split = { direction = "vertical", position = "right", size = 74 },
    behavior = { intercept_wincmd = true, auto_unmount = true },
  })

  handle.focus() -- land in the prompt
  vim.cmd("startinsert")

  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "quit panel" } },
    { "n", "<Tab>", function() actions.current.cycle() end, { desc = "cycle focus" } },
  })
end

return M
