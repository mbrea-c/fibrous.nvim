-- The terminal-draw harness (fibrous.bench.termdraw) drives a child nvim in a
-- real pty and counts the BYTES it writes to the terminal per redraw — the
-- "one layer down" measure that the buffer-write metric can't see (it counts
-- what fibrous writes to the buffer; this counts what nvim's TUI then pushes at
-- the terminal, highlight repaints and escape overhead included — the real
-- ssh+tmux cost). These pin the mechanism: a moving workload draws bytes, a
-- no-op draws far fewer, and a highlight-only churn (invisible to the buffer
-- metric) still shows up here.

local termdraw = require("fibrous.bench.termdraw")

describe("bench.termdraw", function()
  it("counts terminal bytes: a moving workload draws, a no-op barely does", function()
    local moving = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[
        _G.FRAME = function(i)
          vim.api.nvim_buf_set_lines(0, 0, -1, false, { (tostring(i % 10)):rep(38) })
        end
      ]],
    })
    local static = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[ _G.FRAME = function() end ]],
    })
    assert.is_true(moving.bytes > 0, "a changing line must produce terminal output")
    assert.is_true(moving.frames == 15)
    assert.is_true(static.bytes < moving.bytes, "an idle frame draws less than a moving one")
  end)

  it("sees a highlight-only redraw that the buffer-write metric cannot", function()
    -- No buffer write at all — only a group's colour flips — yet the terminal
    -- repaints the cells using it. This is the flicker the cells/op metric misses.
    local hl = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { ("X"):rep(38) })
        vim.api.nvim_set_hl(0, "Grp", { fg = "#00ff00" })
        vim.api.nvim_buf_add_highlight(0, 0, "Grp", 0, 0, -1)
        _G.FRAME = function(i)
          vim.api.nvim_set_hl(0, "Grp", { fg = i % 2 == 0 and "#00ff00" or "#ff0000" })
        end
      ]],
    })
    assert.is_true(hl.bytes > 0, "a highlight-only change still costs terminal draw")
  end)
end)
