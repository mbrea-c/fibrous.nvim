-- Reactivity demo: `use_state` drives the rendered count, and `use_effect` logs
-- each change as a side effect. External keymaps mutate the state through an
-- imperative actions table the component publishes (via a prop) once at mount —
-- the state handle closes over a stable hook slot, so the captured inc/dec/reset
-- stay live across every re-render.

local nr = require("fibrous")
local el = require("fibrous.components")
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
    comp = el.col,
    props = {},
    children = {
      {
        comp = el.text,
        props = {
          border = "rounded",
          lines = {
            "",
            "        Count: " .. n,
            "",
            "   +  increment     -  decrement",
            "   r  reset          q  quit",
          },
        },
      },
    },
  }
end

local M = {}

function M.run()
  local actions = { current = {} }
  local handle = nr.mount(Counter, { actions = actions }, { size = { width = 42, height = 8 } })
  return util.bind(handle, {
    { "n", "+", function() actions.current.inc() end, { desc = "increment" } },
    { "n", "-", function() actions.current.dec() end, { desc = "decrement" } },
    { "n", "r", function() actions.current.reset() end, { desc = "reset" } },
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
