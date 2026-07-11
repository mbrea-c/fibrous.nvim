-- The markdown widget: render markdown source as rich, interactive blocks.
-- Demonstrates ui.markdown — a pure-Lua parser (no treesitter) feeding the
-- shared document renderer — with headings, inline emphasis/code, LINKS that
-- are real interactive spans (move onto one and press <CR>, or click it),
-- lists, GFM task lists and tables, blockquotes, and fenced code.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local SOURCE = table.concat({
  "# Markdown in fibrous",
  "",
  "Render **markdown** *source* as rich blocks, with `inline code` and a",
  "[clickable link](https://example.com) that hovers, clicks, and flash-jumps",
  "like any other widget.",
  "",
  "## Lists",
  "",
  "- a plain bullet",
  "- a bullet with `code`",
  "- [x] a finished task",
  "- [ ] a pending task",
  "",
  "## Tables",
  "",
  "| Language | Speed  | Note        |",
  "| :------- | -----: | :---------: |",
  "| lua      |   fast | **vendored** |",
  "| vimscript| slower | legacy      |",
  "",
  "## Quotes and code",
  "",
  "> Blockquotes render with a rule and padding,",
  "> across as many lines as you like.",
  "",
  "```lua",
  "local function add(a, b)",
  "  return a + b",
  "end",
  "```",
  "",
  "Move the cursor onto the link above and press <CR>.  Press  q  to close.",
}, "\n")

local function Doc()
  return {
    comp = ui.col,
    props = { grow = 1, style = { padding = { x = 2, y = 1 } } },
    children = {
      {
        comp = ui.markdown,
        props = {
          text = SOURCE,
          on_link = function(url)
            vim.notify("open link: " .. url)
          end,
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Doc, {}, { width = 62, height = 30, mode = "scroll" })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
