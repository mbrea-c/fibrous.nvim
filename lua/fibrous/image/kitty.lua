-- Kitty graphics protocol builders for inline images: pure string functions
-- with no terminal I/O (the registry in fibrous.image owns writing).
--
-- Images use UNICODE PLACEHOLDERS (kitty >= 0.28, ghostty): the payload is
-- transmitted once with a virtual placement (U=1), and any cell whose char is
-- U+10EEEE, whose foreground color encodes the image id, and whose combining
-- diacritics encode (row, col) displays that piece of the image. Placeholder
-- cells are ordinary text -- they scroll, clip and layer like characters, in
-- buffers, floats and under tmux -- so the renderer just paints them onto the
-- canvas; only these control sequences need a real terminal.

local diacritics = require("fibrous.image.diacritics")

local M = {}

local ESC = "\27"
local ST = ESC .. "\\"
-- max base64 payload bytes per escape (protocol limit)
local CHUNK = 4096

-- UTF-8 encode one codepoint (LuaJIT has no utf8 library; keep this pure).
---@param cp integer
---@return string
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

local PLACEHOLDER = utf8_encode(0x10EEEE)

-- 0-indexed row/col -> its combining diacritic, encoded once.
local dia = {}
---@param i integer
---@return string
local function diacritic(i)
  local s = dia[i]
  if s == nil then
    local cp = diacritics[i + 1]
    if not cp then
      error("fibrous: image exceeds the placeholder grid (" .. #diacritics .. " rows/cols)")
    end
    s = utf8_encode(cp)
    dia[i] = s
  end
  return s
end

-- The placeholder cluster for image cell (row, col), both 0-indexed: U+10EEEE
-- plus the row and column diacritics. Every cell is fully self-described (no
-- reliance on kitty's infer-from-left rule), so clipping any sub-rectangle of
-- the grid still shows the right piece. Memoized: the render loop asks per
-- painted cell.
local cells = {}
---@param row integer
---@param col integer
---@return string
function M.cell(row, col)
  local key = row * 512 + col
  local s = cells[key]
  if s == nil then
    s = PLACEHOLDER .. diacritic(row) .. diacritic(col)
    cells[key] = s
  end
  return s
end

-- Transmit base64 PNG data and create its virtual placement in one action:
-- a=T (transmit and display), U=1 (unicode placeholder placement), f=100
-- (PNG), t=d (direct payload), q=2 (no ACKs -- they would land in nvim's
-- input), fitted to rows x cols preserving aspect ratio. Payloads over 4096
-- bytes split into continuation escapes (m=1 ... m=0) that carry only m.
---@param b64 string
---@param opts { id: integer, cols: integer, rows: integer }
---@return string[] escapes
function M.transmit(b64, opts)
  local head = ("a=T,U=1,f=100,t=d,q=2,i=%d,c=%d,r=%d"):format(opts.id, opts.cols, opts.rows)
  local out = {}
  local pos = 1
  repeat
    local chunk = b64:sub(pos, pos + CHUNK - 1)
    pos = pos + CHUNK
    local last = pos > #b64
    local keys = (#out == 0 and head .. "," or "") .. "m=" .. (last and "0" or "1")
    out[#out + 1] = ESC .. "_G" .. keys .. ";" .. chunk .. ST
  until last
  return out
end

-- Graphics capability query (a=q): kitty-protocol terminals verify the tiny
-- payload (one 1x1 RGB pixel, f=24) and REPLY without storing anything;
-- everything else stays silent. No q= key -- the reply is the point.
-- fibrous.image.probe brackets this with DA1 and reads the answer back.
---@param id integer
---@return string
function M.query(id)
  return ESC .. "_Ga=q,i=" .. id .. ",s=1,v=1,t=d,f=24;AAAA" .. ST
end

-- Delete the image and free its data (uppercase I).
---@param id integer
---@return string
function M.delete(id)
  return ESC .. "_Ga=d,d=I,i=" .. id .. ST
end

-- Wrap a control sequence for tmux passthrough (needs `allow-passthrough on`;
-- detect.lua checks). Placeholder TEXT needs no wrapping -- it is just text.
---@param esc string
---@return string
function M.tmux_wrap(esc)
  return ESC .. "Ptmux;" .. esc:gsub(ESC, ESC .. ESC) .. ST
end

return M
