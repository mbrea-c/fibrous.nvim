-- Reactivity demo: `use_state` drives the rendered count, and `use_effect` logs
-- each change as a side effect. State is mutated two ways:
--   * cursor interaction — hover a button and press <CR>/<Space>;
--   * external keymaps (+/-/r) driving an imperative actions table the
--     component publishes (via a prop) once at mount — the state handle closes
--     over a stable hook slot, so the captured inc/dec/reset stay live across
--     every re-render.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local function Counter(ctx, props)
  local count = ctx.use_state(0)

  -- Publish the imperative API exactly once (empty deps). Safe because
  -- count.set/get reference the persistent hook slot, not this render's values.
  ctx.use_effect(function()
    props.actions.current = {
      inc = function() count.set(count.get() + 1) end,
      dec = function() count.set(count.get() - 1) end,
      reset = function() count.set(0) end,
    }
  end, {})

  -- A second effect that re-runs whenever the count changes (deps = { n }),
  -- echoing to :messages so you can watch the reactive loop fire.
  local n = count.get()
  ctx.use_effect(function()
    vim.notify("counter → " .. n)
  end, { n })

  return {
    comp = ui.col,
    props = { border = "rounded", padding = { x = 2, y = 1 }, gap = 1 },
    children = {
      { comp = ui.label, props = { text = "Count: " .. n, hl = "Title" } },
      {
        comp = ui.row,
        props = { gap = 2 },
        children = {
          { comp = ui.button, props = { label = "+1", on_press = function() count.set(count.get() + 1) end } },
          { comp = ui.button, props = { label = "-1", on_press = function() count.set(count.get() - 1) end } },
          { comp = ui.button, props = { label = "reset", on_press = function() count.set(0) end } },
        },
      },
      { comp = ui.label, props = { text = "<CR>/<Space> press · or +/-/r · q quits", hl = "Comment" } },
    },
  }
end

local M = {}

function M.run()
  local actions = { current = {} }
  local handle = nr.mount(Counter, { actions = actions }, { width = 44, height = 7 })
  handle.focus()
  return util.bind(handle, {
    { "n", "+", function() actions.current.inc() end, { desc = "increment" } },
    { "n", "-", function() actions.current.dec() end, { desc = "decrement" } },
    { "n", "r", function() actions.current.reset() end, { desc = "reset" } },
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
