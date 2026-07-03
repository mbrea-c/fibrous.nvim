-- Rich-text span lists ("Style rework" S4): `text` on text nodes (and the
-- label/paragraph components) may be a list of spans — bare strings or
-- { "chunk", hl = ... } tables. spans.lua is the pure normalization half:
-- flatten a list into the full text plus byte-indexed hl ranges the layout
-- engine threads through wrapping.

local spans = require("fibrous.inline.spans")

describe("inline.spans", function()
  it("flattens a span list into text plus hl ranges", function()
    local text, ranges = spans.flatten({ "plain ", { "loud", hl = "Title" }, { "!" } })
    assert.equal("plain loud!", text)
    -- only hl-carrying spans produce ranges; 1-indexed, end-exclusive bytes
    assert.same({ { s = 7, e = 11, hl = "Title" } }, ranges)
  end)

  it("hl_at reports the hl covering a byte position", function()
    local _, ranges = spans.flatten({ "ab", { "cd", hl = "X" } })
    assert.is_nil(spans.hl_at(ranges, 2))
    assert.equal("X", spans.hl_at(ranges, 3))
    assert.equal("X", spans.hl_at(ranges, 4))
    assert.is_nil(spans.hl_at(ranges, 5))
  end)

  it("invalid spans error loudly", function()
    assert.has_error(function()
      spans.flatten({ { text = "x" } })
    end, "span")
    assert.has_error(function()
      spans.flatten({ true })
    end, "span")
  end)
end)
