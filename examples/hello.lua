-- The smallest possible app: a static floating panel. Demonstrates a function
-- component returning a `col` container with a single bordered `text` leaf, and
-- the floating mount target (design.md §3A).

local nr = require("nui-reactive")
local el = require("nui-reactive.components")
local util = require("examples.util")

local function Hello()
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
            "   Hello from nui-reactive! ",
            "",
            "   A React-like reactive UI",
            "   framework for Neovim.",
            "",
            "   Press  q  to close.",
          },
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Hello, {}, { size = { width = 40, height = 10 } })
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
