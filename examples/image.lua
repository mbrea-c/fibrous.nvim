-- ui.image: inline images via kitty Unicode placeholders. Run this in kitty
-- or ghostty (and under tmux with `allow-passthrough on`) to see pixels; on
-- any other terminal every image degrades to its alt text -- which is also
-- worth seeing, it is the path notebook outputs take on unsupported setups.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

-- A real 120x80 PNG (a gradient), base64 with embedded newlines exactly the
-- way ipynb files store image outputs (ui.image strips the whitespace).
local png = [[
iVBORw0KGgoAAAANSUhEUgAAAHgAAABQEAIAAAANafqdAAAAIGNIUk0AAHomAACAhAAA+gAAAIDo
AAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqBxEVMjmJFsNM
AAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTA3LTE3VDIxOjUwOjU3KzAwOjAwjuQFjwAAACV0RVh0
ZGF0ZTptb2RpZnkAMjAyNi0wNy0xN1QyMTo1MDo1NyswMDowMP+5vTMAAAAodEVYdGRhdGU6dGlt
ZXN0YW1wADIwMjYtMDctMTdUMjE6NTA6NTcrMDA6MDCorJzsAAABbElEQVR42u3d0Q3CMAxFUQeY
BCZJJ+t+6U4wAx+prKdzRkCWdV2KGFVV51kQ4fW4an4/PghCBvq5DDRJA33V/L59EMQM9JhlQxPT
0JKDuOQw0Gho6NnQhw1NzkBraKKOQg2NoxDaJseY5SjEhgYDDZuPQk85yNrQw0ATlhyOQjQ0dBzo
VV4fJego1NBoaGicHDY0jkLoOdDehybpKJQcpCWHt+3Q0NByoJfn0NjQ0PQoNNDEbWhHIRoaNDTs
H2ivj5JzFC4NTdSG1tBoaGg60F5OwoaGrkfhNQ5HIVEb2mM7NDRoaNg+0J5Dk3QU+qYQyQEGGm4Y
6OW/vklqaL9YQXKAgYZ7GtpAY0ODoxC2J4cNTVRyjMNzaDQ0SA5wFMJfDW1DIznAUQh3JIc/DSLr
KLSh0dCgoWF/QxtospLDUYijEJo2tLftCEoODU3Whj4MNFHJ4SjEUQgaGu5IDgONhoaWyeE5NFFH
oYYmxw9ziaSWkA3WJwAAAABJRU5ErkJggg==
]]

local function Images()
  return {
    comp = ui.col,
    props = { gap = 1, style = { border = "rounded", padding = { x = 2, y = 1 } } },
    children = {
      { comp = ui.label, props = { text = "Inline images", style = { text_hl = "Title" } } },
      { comp = ui.paragraph, props = { text = "Natural size (120x80 px over the probed cell size):" } },
      { comp = ui.image, props = { b64 = png, alt = "<gradient 120x80> (terminal has no image support)" } },
      { comp = ui.paragraph, props = { text = "The same content capped at max_cols = 6 (aspect preserved, one shared transmission):" } },
      { comp = ui.image, props = { b64 = png, max_cols = 6 } },
      { comp = ui.paragraph, props = { text = "Undecodable content degrades to alt:" } },
      { comp = ui.image, props = { b64 = vim.base64.encode(("not a png"):rep(5)), alt = "<broken figure> (alt fallback)" } },
      { comp = ui.label, props = { text = "Press  q  to close.", style = { text_hl = "Comment" } } },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Images, {}, { width = 56, height = 24 })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
