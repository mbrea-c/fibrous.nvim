-- Kitty graphics protocol escape builders and Unicode placeholder cells
-- (inline images). Pure string functions: transmit chunking, deletes, tmux
-- passthrough wrapping, and the U+10EEEE + row/col-diacritic cell clusters.

local kitty = require("fibrous.image.kitty")

local ESC = "\27"
local ST = ESC .. "\\"

-- U+10EEEE in UTF-8
local PLACEHOLDER = "\244\142\187\174"

describe("image.kitty", function()
  describe("cell", function()
    it("encodes row and column as combining diacritics after U+10EEEE", function()
      -- diacritics[1] = U+0305, [2] = U+030D, [3] = U+030E
      assert.equal(PLACEHOLDER .. "\204\133\204\133", kitty.cell(0, 0))
      assert.equal(PLACEHOLDER .. "\204\141\204\142", kitty.cell(1, 2))
    end)

    it("covers the full diacritic table", function()
      local d = require("fibrous.image.diacritics")
      assert.equal(297, #d)
      -- last entry is U+1D244 (4-byte UTF-8)
      local last = kitty.cell(296, 296)
      assert.equal(#PLACEHOLDER + 8, #last)
    end)

    it("errors beyond the 297-cell placeholder range", function()
      assert.has_error(function()
        kitty.cell(297, 0)
      end, "placeholder")
    end)
  end)

  describe("transmit", function()
    it("one small payload is a single m=0 escape with all keys", function()
      local chunks = kitty.transmit("QUJD", { id = 5, cols = 3, rows = 2 })
      assert.same({ ESC .. "_Ga=T,U=1,f=100,t=d,q=2,i=5,c=3,r=2,m=0;QUJD" .. ST }, chunks)
    end)

    it("payloads over 4096 bytes chunk; only the first escape carries keys", function()
      local b64 = ("A"):rep(5000)
      local chunks = kitty.transmit(b64, { id = 9, cols = 10, rows = 4 })
      assert.equal(2, #chunks)
      assert.equal(ESC .. "_Ga=T,U=1,f=100,t=d,q=2,i=9,c=10,r=4,m=1;" .. ("A"):rep(4096) .. ST, chunks[1])
      assert.equal(ESC .. "_Gm=0;" .. ("A"):rep(904) .. ST, chunks[2])
    end)

    it("an exactly-4096-byte payload stays a single chunk", function()
      local chunks = kitty.transmit(("B"):rep(4096), { id = 1, cols = 1, rows = 1 })
      assert.equal(1, #chunks)
      assert.truthy(chunks[1]:find("m=0;", 1, true))
    end)
  end)

  it("delete frees the image data by id", function()
    assert.equal(ESC .. "_Ga=d,d=I,i=77" .. ST, kitty.delete(77))
  end)

  it("tmux_wrap doubles ESCs inside a passthrough envelope", function()
    local wrapped = kitty.tmux_wrap(ESC .. "_Ga=d,d=I,i=1" .. ST)
    assert.equal(ESC .. "Ptmux;" .. ESC .. ESC .. "_Ga=d,d=I,i=1" .. ESC .. ESC .. "\\" .. ST, wrapped)
  end)
end)
