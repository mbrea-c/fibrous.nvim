-- The image registry (fibrous.image): spec resolution (deterministic ids,
-- cell sizing) and the refcounted retain/release lifecycle, over a capture
-- writer so no escape ever reaches a real terminal.

local image = require("fibrous.image")

local function be32(n)
  return string.char(
    math.floor(n / 2 ^ 24) % 256,
    math.floor(n / 2 ^ 16) % 256,
    math.floor(n / 2 ^ 8) % 256,
    n % 256
  )
end

-- A sniffable PNG header (w x h px), padded so content differs by dims alone.
local function png_b64(w, h)
  local bytes = "\137PNG\r\n\26\10" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
  return vim.base64.encode(bytes)
end

local written

describe("fibrous.image", function()
  -- scoped to THIS describe: a file-level before_each would attach to the
  -- harness root and run for every spec in the whole suite
  before_each(function()
    image.reset()
    image.config.provider = "kitty"
    image.config.cell_px = { w = 10, h = 20 }
    written = {}
    image.config.writer = function(data)
      written[#written + 1] = data
    end
  end)

  after_each(function()
    image.reset()
  end)

  describe("image.spec", function()
    it("resolves natural size in cells from pixel dims / cell_px", function()
      local s = image.spec({ b64 = png_b64(200, 100) })
      assert.equal(20, s.cols)
      assert.equal(5, s.rows)
    end)

    it("max caps scale down preserving aspect", function()
      local s = image.spec({ b64 = png_b64(200, 100), max_cols = 10 })
      assert.equal(10, s.cols)
      assert.equal(3, s.rows) -- 5 * 0.5 = 2.5, rounds up
    end)

    it("explicit cols derive rows from the aspect ratio", function()
      local s = image.spec({ b64 = png_b64(200, 100), cols = 40 })
      assert.equal(40, s.cols)
      assert.equal(10, s.rows)
    end)

    it("explicit cols and rows win outright", function()
      local s = image.spec({ b64 = png_b64(200, 100), cols = 7, rows = 9, max_cols = 3 })
      assert.equal(7, s.cols)
      assert.equal(9, s.rows)
    end)

    it("ids are deterministic over content and size, and distinct across both", function()
      local a = image.spec({ b64 = png_b64(200, 100) })
      local b = image.spec({ b64 = png_b64(200, 100) })
      assert.equal(a.id, b.id)
      assert.equal(a.hl, b.hl)
      local other = image.spec({ b64 = png_b64(100, 100) })
      assert.truthy(a.id ~= other.id)
      local resized = image.spec({ b64 = png_b64(200, 100), cols = 4 })
      assert.truthy(a.id ~= resized.id)
    end)

    it("the hl group name embeds the id in hex", function()
      local s = image.spec({ b64 = png_b64(200, 100) })
      assert.equal(("FibrousImage_%06x"):format(s.id), s.hl)
    end)

    it("whitespace in the base64 (ipynb style) is stripped", function()
      local raw = png_b64(64, 32)
      local wrapped = raw:sub(1, 10) .. "\n" .. raw:sub(11)
      local s = image.spec({ b64 = wrapped })
      assert.same({ 6, 2 }, { s.cols, s.rows })
    end)

    it("raw data bytes work too", function()
      local bytes = vim.base64.decode(png_b64(100, 100))
      local s = image.spec({ data = bytes })
      assert.equal(10, s.cols)
    end)

    it("returns nil with a reason for non-PNG content", function()
      local s, err = image.spec({ b64 = vim.base64.encode("not a png, but long enough to sniff") })
      assert.is_nil(s)
      assert.truthy(err)
    end)

    it("returns nil when the provider resolves to text", function()
      image.config.provider = "text"
      local s, err = image.spec({ b64 = png_b64(10, 10) })
      assert.is_nil(s)
      assert.truthy(err)
    end)
  end)

  describe("image retain/release", function()
    it("first retain transmits (id, geometry, payload); further retains do not", function()
      local s = image.spec({ b64 = png_b64(40, 40) })
      image.retain(s)
      assert.equal(1, #written)
      assert.truthy(written[1]:find("a=T,U=1", 1, true))
      assert.truthy(written[1]:find(("i=%d"):format(s.id), 1, true))
      assert.truthy(written[1]:find(("c=%d,r=%d"):format(s.cols, s.rows), 1, true))
      image.retain(s)
      assert.equal(1, #written)
    end)

    it("defines the id-encoding highlight group on retain", function()
      local s = image.spec({ b64 = png_b64(40, 40) })
      image.retain(s)
      local hl = vim.api.nvim_get_hl(0, { name = s.hl })
      assert.equal(s.id, hl.fg)
    end)

    it("the last release deletes; earlier ones do not", function()
      local s = image.spec({ b64 = png_b64(40, 40) })
      image.retain(s)
      image.retain(s)
      image.release(s)
      assert.equal(1, #written)
      image.release(s)
      assert.equal(2, #written)
      assert.truthy(written[2]:find("a=d,d=I", 1, true))
      assert.truthy(written[2]:find(("i=%d"):format(s.id), 1, true))
    end)

    it("retain after full release transmits again", function()
      local s = image.spec({ b64 = png_b64(40, 40) })
      image.retain(s)
      image.release(s)
      image.retain(s)
      assert.equal(3, #written)
      assert.truthy(written[3]:find("a=T", 1, true))
    end)

    it("release of an unretained spec is a safe no-op", function()
      local s = image.spec({ b64 = png_b64(40, 40) })
      image.release(s)
      assert.equal(0, #written)
    end)
  end)
end)
