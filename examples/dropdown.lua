-- ui.dropdown: a select field. Focus the input (<CR> or i with the cursor on
-- it) and the option popup opens as an OVERLAY — a zero-footprint ui.popup
-- float that escapes the mount's box instead of reserving rows in it. Type to
-- fuzzy-filter, <C-n>/<C-p> to move the selection, <CR>/<C-y> to commit it
-- into the field, <C-e> to close the popup and keep typing; unfocusing
-- commits the selection too. The first dropdown is strict (text matching no
-- option reverts on unfocus), the second allows free text.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local FRUITS = {
  "apple",
  "apricot",
  "banana",
  "blackberry",
  "blueberry",
  "cherry",
  "cranberry",
  "grape",
  "mango",
  "papaya",
  "peach",
  "pear",
}

local function Dropdowns(ctx)
  local fruit = ctx.use_state("banana")
  local topping = ctx.use_state("")

  return {
    comp = ui.col,
    props = { gap = 1, style = { border = "rounded", padding = { x = 2, y = 1 } } },
    children = {
      { comp = ui.label, props = { text = "Dropdowns", style = { text_hl = "Title" } } },
      { comp = ui.label, props = { text = "Strict select (picked: " .. fruit.get() .. "):" } },
      {
        comp = ui.dropdown,
        props = {
          options = FRUITS,
          value = fruit.get(),
          width = 24,
          max_height = 6,
          on_select = function(v)
            fruit.set(v)
          end,
        },
      },
      { comp = ui.label, props = { text = "Free text allowed (picked: " .. topping.get() .. "):" } },
      {
        comp = ui.dropdown,
        props = {
          options = { "chocolate", "caramel", "cream", "crumble" },
          value = topping.get(),
          width = 24,
          free_text = true,
          on_select = function(v)
            topping.set(v)
          end,
        },
      },
      { comp = ui.label, props = { text = "Press  q  to close.", style = { text_hl = "Comment" } } },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Dropdowns, {}, { width = 44, height = 12 })
  handle.focus()
  return util.bind(handle, {
    {
      "n",
      "q",
      function()
        handle.unmount()
      end,
      { desc = "close example" },
    },
  })
end

return M
