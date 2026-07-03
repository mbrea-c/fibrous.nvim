-- The smallest possible app: a static floating panel. Demonstrates a function
-- component returning a bordered `col` of labels, and the floating mount
-- target.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local function Hello()
  return {
    comp = ui.col,
    props = { border = "rounded", padding = { x = 3, y = 1 } },
    children = {
      { comp = ui.label, props = { text = "Hello from fibrous!", hl = "Title" } },
      { comp = ui.label, props = { text = "" } },
      { comp = ui.paragraph, props = { text = "A React-like reactive UI framework for Neovim." } },
      { comp = ui.label, props = { text = "" } },
      { comp = ui.label, props = { text = "Press  q  to close.", hl = "Comment" } },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Hello, {}, { width = 40, height = 9 })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
