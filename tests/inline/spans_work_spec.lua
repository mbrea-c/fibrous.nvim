local Spans = require("fibrous.inline.spans")

-- Deliberately simple bytewise oracle, independent of the optimized traversal.
local function reference(pieces, ranges)
  local runs = {}
  for _, p in ipairs(pieces) do
    local i = 1
    while i <= #p.text do
      local r = Spans.attr_at(ranges, p.s + i - 1)
      local j = i + 1
      while j <= #p.text and Spans.attr_at(ranges, p.s + j - 1) == r do
        j = j + 1
      end
      local chunk = p.text:sub(i, j - 1)
      local hl = r and r.hl or nil
      local id = r and r.id or nil
      local source = r and r.source
      local positions
      if source then
        positions = {}
        for k = i, j - 1 do
          local at = r.source_base + p.s + k - 1 - r.s
          local mapped = source.map and source.map[at] or not source.map and at - 1
          positions[#positions + 1] = type(mapped) == "number" and (source.offset or 0) + mapped or false
        end
      end
      local last = runs[#runs]
      if last and last.hl == hl and last.id == id and last.source == source then
        last.text = last.text .. chunk
        if positions then for _, position in ipairs(positions) do last.source_positions[#last.source_positions + 1] = position end end
      else
        runs[#runs + 1] = {
          text = chunk,
          hl = hl,
          source = source, source_positions = positions,
          id = id,
          hover_hl = r and r.hover_hl or nil,
          on_click = r and r.on_click or nil,
          role = r and r.role or nil,
        }
      end
      i = j
    end
  end
  return runs
end

describe("span attribution work", function()
  it("does not look up the covering span once per text byte", function()
    local list = {}
    for i = 1, 48 do list[i] = { ("word "):rep(3), hl = i % 2 == 0 and "Title" or "Comment" } end
    local text, ranges = Spans.flatten(list)
    local attr, calls = Spans.attr_at, 0
    Spans.attr_at = function(...)
      calls = calls + 1
      return attr(...)
    end
    local ok, result = pcall(Spans.runs, { { s = 1, text = text } }, ranges)
    Spans.attr_at = attr
    if not ok then error(result, 0) end
    assert.equal(48, #result)
    assert.is_true(calls <= 2 * #ranges)
  end)

  it("matches bytewise attribution across gaps, empty spans, mappings and reordered pieces", function()
    local click = function() end
    local source = { id = "mapped", offset = 7, map = { 8, 9, false, 14, 15, 16, 17 } }
    local text, ranges = Spans.flatten({
      "plain ", { "", hl = "Empty" },
      { "αβ!", style = { text_hl = "Title", _hover = { text_hl = "Search" } },
        on_click = click, role = "link", source = source },
      " gap ", { "tail", hl = "Comment" }, { "", hl = "Empty" },
    })
    local sets = {
      { { s = 1, text = text } },
      { { s = 7, text = "α" }, { s = 9, text = "β!" }, { s = 12, text = " " }, { s = 13, text = "gap" } },
      { { s = #text - 3, text = "tail" }, { s = 1, text = "plain" }, { s = 7, text = "αβ!" } },
      { { s = #text + 1, text = "extra" } },
      {},
    }
    for _, pieces in ipairs(sets) do assert.same(reference(pieces, ranges), Spans.runs(pieces, ranges)) end
    for start = 1, #text do
      local pieces = { { s = start, text = text:sub(start, start + 5) } }
      assert.same(reference(pieces, ranges), Spans.runs(pieces, ranges))
    end
  end)
end)
