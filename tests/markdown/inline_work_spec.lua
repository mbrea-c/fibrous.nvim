local Inline = require("fibrous.markdown.inline")
local Source = require("fibrous.doc.source")

describe("inline plain-run scanning", function()
  it("does not take one substring per ordinary input byte", function()
    local text = ("Ordinary 界é prose with spaces and punctuation. "):rep(100)
    for _, mapped in ipairs({ false, true }) do
      local sub, calls = string.sub, 0
      string.sub = function(...) calls = calls + 1; return sub(...) end
      local ok, nodes = pcall(Inline.parse, text, mapped and Source.identity(text) or nil)
      string.sub = sub
      if not ok then error(nodes, 0) end
      assert.equal(1, #nodes)
      assert.equal(text, nodes[1].text)
      assert.is_true(calls < 20)
    end
  end)

  it("keeps malformed syntax and terminal backslashes literal", function()
    local text = "literal ! [unclosed <bad snake_case lone$ broken~ trailing" .. string.char(92)
    assert.same({ { type = "text", text = text } }, Inline.parse(text))
    assert.same({}, Inline.parse(""))
  end)

  it("preserves trailing-space and backslash hard breaks between plain runs", function()
    assert.same({
      { type = "text", text = "first" }, { type = "hardbreak" },
      { type = "text", text = "second" }, { type = "hardbreak" },
      { type = "text", text = "last" },
    }, Inline.parse("first  \nsecond" .. string.char(92) .. "\nlast"))
  end)

  it("retains exact UTF-8 byte maps around escapes, marks and links", function()
    local text = "plain 界é text " .. string.char(92) .. "*literal" .. string.char(92)
      .. "* **bold** [label](url) tail\nnext"
    local nodes = Inline.parse(text, Source.identity(text))
    local function check(list)
      for _, node in ipairs(list) do
        if node.text then
          assert.is_true(node.source_map ~= nil)
          for byte = 1, #node.text do
            assert.equal(node.text:sub(byte, byte),
              text:sub(node.source_map[byte] + 1, node.source_map[byte] + 1))
          end
        end
        if node.children then check(node.children) end
      end
    end
    check(nodes)
    assert.equal("plain 界é text *literal* ", nodes[1].text)
    assert.equal("strong", nodes[2].type)
  end)
end)
