local Canvas = require("fibrous.inline.canvas")

local function width_entries(canvas)
  local n = 0
  for _, row in ipairs(canvas.cw) do for _ in pairs(row) do n = n + 1 end end
  return n
end

describe("canvas implicit single-cell widths", function()
  local function observe_widths(canvas)
    local touches = 0
    for _, row in ipairs(canvas.cw) do
      setmetatable(row, {
        __index = function() touches = touches + 1; return nil end,
        __newindex = function(t, key, value)
          touches = touches + 1
          rawset(t, key, value)
        end,
      })
    end
    return function() return touches end
  end

  it("paints ASCII-only rows without per-cell width lookups or writes", function()
    local canvas = Canvas.new(80, 10)
    local touches = observe_widths(canvas)
    canvas:text(0, 0, "ordinary text", "Title")
    canvas:text(-2, 1, "abc", "Comment")
    assert.equal(0, touches())
    assert.equal("ordinary text" .. (" "):rep(67), canvas:line(1))
    assert.equal("c" .. (" "):rep(79), canvas:line(2))
  end)

  it("blanks ordinary rows without per-cell width lookups or writes", function()
    local canvas = Canvas.new(80, 10)
    canvas:text(0, 0, "ordinary text", "Title")
    local touches = observe_widths(canvas)
    canvas:blank_rect({ x = 3, y = 0, w = 50, h = 4 })
    assert.equal(0, touches())
    assert.equal("ord" .. (" "):rep(77), canvas:line(1))
  end)
  it("does not allocate width entries for ordinary cells, including grown rows", function()
    local canvas = Canvas.new(120, 100)
    canvas:text(0, 0, "ordinary ASCII text", "Title")
    canvas:grow(120)
    canvas:text(0, 119, "last row")
    assert.equal(0, width_entries(canvas))
    assert.equal((" "):rep(120), canvas:line(2))
    assert.equal("last row" .. (" "):rep(112), canvas:line(120))
  end)

  it("keeps only wide heads and continuations, removing both when overwritten", function()
    local canvas = Canvas.new(10, 1)
    canvas:text(1, 0, "界")
    canvas:text(6, 0, "界")
    assert.equal(4, width_entries(canvas))
    assert.equal(2, canvas.cw[1][2])
    assert.equal(0, canvas.cw[1][3])
    canvas:text(1, 0, "ab")
    assert.equal(2, width_entries(canvas))
    canvas:blank_rect({ x = 6, y = 0, w = 1, h = 1 })
    assert.equal(0, width_entries(canvas))
    assert.equal(" ab       ", canvas:line(1))
  end)

  it("repairs either overwritten half without changing inherited highlights", function()
    local canvas = Canvas.new(6, 1)
    canvas:text(1, 0, "界x", "Title")
    canvas:text(2, 0, "Q")
    assert.equal("  Qx  ", canvas:line(1))
    assert.same({ { row = 0, start_col = 1, end_col = 4, hl = "Title" } }, canvas:highlights())
    canvas:text(1, 0, "界", "Comment")
    canvas:text(1, 0, "Q")
    assert.equal(" Q x  ", canvas:line(1))
    assert.equal(0, width_entries(canvas))
  end)
end)
