local termdraw = require("fibrous.bench.termdraw")

describe("inline overflow terminal rendering", function()
  it("keeps the footer visible across real TUI redraws", function()
    local result_path = vim.fn.tempname()
    termdraw.measure({
      cols = 40, rows = 12, frames = 3, rtp = { vim.fn.getcwd() },
      init = ([[
        local mount = require("fibrous.inline.mount")
        local ui = require("fibrous.inline.components")
        local function App(_, props)
          return { comp = ui.col, props = {}, children = {
            { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
              { comp = ui.label, props = { text = props.text } },
            } },
            { comp = ui.button, props = { label = "Overview", theme = false, height = 1 } },
          } }
        end
        local app = mount.floating(App, { text = "first" }, {
          width = 20, height = 3, row = 1, col = 1, mode = "fixed", border = "none",
        })
        app.focus()
        _G.FRAME = function(i)
          app.set_props({ text = ("content " .. i .. "\n"):rep(40) })
          vim.cmd("redraw")
          local origin = vim.api.nvim_win_get_position(app.winid)
          local line = ""
          for x = 1, 20 do
            line = line .. vim.fn.screenstring(origin[1] + 3, origin[2] + x)
          end
          vim.fn.writefile({ line }, %q)
        end
      ]]):format(result_path),
    })
    local lines = vim.fn.readfile(result_path)
    vim.fn.delete(result_path)
    assert.truthy(lines[1]:find("Overview", 1, true))
    assert.falsy(lines[1]:find("content", 1, true))
  end)
end)
