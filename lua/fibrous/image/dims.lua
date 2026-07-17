-- PNG dimension sniffing for inline images. The IHDR chunk is mandatory and
-- first, so width/height sit at fixed offsets in the first 24 bytes -- a
-- 32-char base64 prefix decodes to exactly those, letting perijove size an
-- ipynb output without decoding (or copying) the whole blob.

local M = {}

local MAGIC = "\137PNG\r\n\26\10"

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Pixel dimensions of a PNG, from its raw bytes (24 needed).
---@param bytes string
---@return { w: integer, h: integer }|nil
function M.png(bytes)
  if type(bytes) ~= "string" or #bytes < 24 then
    return nil
  end
  if bytes:sub(1, 8) ~= MAGIC or bytes:sub(13, 16) ~= "IHDR" then
    return nil
  end
  return { w = be32(bytes, 17), h = be32(bytes, 21) }
end

-- Pixel dimensions from base64-encoded PNG data; only a 32-char prefix
-- (24 bytes) is ever decoded.
---@param b64 string
---@return { w: integer, h: integer }|nil
function M.png_b64(b64)
  if type(b64) ~= "string" or #b64 < 32 then
    return nil
  end
  local ok, bytes = pcall(vim.base64.decode, b64:sub(1, 32))
  if not ok then
    return nil
  end
  return M.png(bytes)
end

return M
