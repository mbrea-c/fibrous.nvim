-- PNG dimension sniffing (inline images): the IHDR chunk sits at a fixed
-- offset, so width/height can be read from the first 24 bytes -- or from a
-- short base64 prefix -- without decoding the blob.

local dims = require("fibrous.image.dims")

-- A syntactically valid PNG header: magic, IHDR length, "IHDR", w, h (both
-- 32-bit big-endian), then bit depth etc. Enough for sniffing.
local function png_header(w, h)
  local function be32(n)
    return string.char(
      math.floor(n / 2 ^ 24) % 256,
      math.floor(n / 2 ^ 16) % 256,
      math.floor(n / 2 ^ 8) % 256,
      n % 256
    )
  end
  return "\137PNG\r\n\26\10" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
end

describe("image.dims", function()
  it("reads PNG width/height from raw bytes", function()
    assert.same({ w = 640, h = 480 }, dims.png(png_header(640, 480)))
  end)

  it("reads dimensions past one byte boundaries", function()
    assert.same({ w = 1, h = 100000 }, dims.png(png_header(1, 100000)))
  end)

  it("rejects non-PNG bytes", function()
    assert.is_nil(dims.png("GIF89a not a png at all, but long enough to read"))
  end)

  it("rejects truncated headers", function()
    assert.is_nil(dims.png("\137PNG\r\n\26\10"))
  end)

  it("reads dimensions from a base64 prefix without decoding the blob", function()
    -- pad with junk so only a prefix decode can be at work
    local blob = png_header(320, 200) .. ("x"):rep(100000)
    assert.same({ w = 320, h = 200 }, dims.png_b64(vim.base64.encode(blob)))
  end)

  it("rejects base64 of non-PNG data", function()
    assert.is_nil(dims.png_b64(vim.base64.encode("definitely not a png, but long enough")))
  end)

  it("rejects strings that are not base64 at all", function()
    assert.is_nil(dims.png_b64("!!!not base64!!!"))
  end)
end)
