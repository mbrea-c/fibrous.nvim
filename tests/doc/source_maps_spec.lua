local Source = require("fibrous.doc.source")
local Markdown = require("fibrous.markdown")

describe("intermediate identity provenance", function()
  it("keeps identity maps and their in-bounds slices constant size", function()
    local map = Source.identity(("x"):rep(10000), 100)
    local sliced = Source.slice(map, 5, 9000)
    assert.equal(104, sliced[1])
    assert.equal(9100, sliced[8997])
    assert.is_true(vim.tbl_count(map) <= 4)
    assert.is_true(vim.tbl_count(sliced) <= 4)
  end)

  it("still exposes plain dense byte arrays on public AST nodes", function()
    local map = Source.identity("hello", 10)
    local node = Source.node({}, Source.slice(map, 2, 4))
    assert.is_nil(getmetatable(node.source_map))
    assert.same({ 11, 12, 13, 14 }, node.source_map)
    assert.same({ 5, false, 8, 9 }, Source.node({}, Source.slice({ 5, false, 8 }, 1, 3)).source_map)
    assert.same({ 8, 9 }, Source.node({}, Source.slice(Source.slice({ [1] = 5, [3] = 8 }, 1, 3), 2, 2)).source_map)
  end)

  it("limits joined maps to the actual line length", function()
    local text, map = Source.join({ "he" }, { Source.identity("hello", 10) })
    assert.equal("he", text)
    assert.same({ 10, 11, 12 }, Source.node({}, map).source_map)
  end)

  it("preserves public byte maps through CRLF, nested prefixes, escapes and tables", function()
    local fence = string.char(96):rep(3)
    local texts = {
      "# heading\r\n\r\n> - escaped " .. string.char(92) .. "*literal" .. string.char(92)
        .. "* 界é\r\n>   next words\r\n\r\n" .. fence .. "lua\r\nlocal x = 1\r\nprint(x)\r\n" .. fence,
      "| left | right |\r\n| --- | --- |\r\n| a" .. string.char(92) .. "|b | **chosen** |",
      fence .. "\nsingle line\n" .. fence,
    }
    for _, text in ipairs(texts) do
      local function check(node)
        if node.source_map then
          assert.is_nil(getmetatable(node.source_map))
          if node.text then
            assert.equal(#node.text + 1, #node.source_map)
            for byte = 1, #node.text do
              local shown = node.text:sub(byte, byte)
              local original = text:sub(node.source_map[byte] + 1, node.source_map[byte] + 1)
              assert.is_true(shown == original or shown == "\n" and original == "\r")
            end
          end
        end
        for key, value in pairs(node) do
          if key ~= "source_map" and type(value) == "table" then check(value) end
        end
      end
      check(Markdown.parse(text, { source = true }))
    end
  end)
end)
