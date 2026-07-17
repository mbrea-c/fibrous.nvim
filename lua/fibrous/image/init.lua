-- Inline image support: the registry tying the pure pieces together. An image
-- is transmitted to the terminal ONCE (kitty graphics protocol, Unicode
-- placeholders -- see kitty.lua) and referenced from buffer text by id; this
-- module owns that lifecycle:
--
--   spec(props)    resolve content + sizing into { id, hl, cols, rows, b64 }
--   retain(spec)   refcount up; the first retain defines the id-encoding hl
--                  group and writes the transmit escapes
--   release(spec)  refcount down; the last release deletes the image
--
-- Ids are DETERMINISTIC: 24 bits of sha256(content .. size), which is exactly
-- what fits in an RGB foreground color. No allocator state, stable across
-- remounts, and the same output shown twice shares one transmission.
--
-- Zero-config: the provider auto-detects (detect.lua) and everything has a
-- default. `config` fields can be assigned directly when needed:
--   provider  "auto" (default) | "kitty" (force) | "text" (disable)
--   cell_px   { w, h } terminal cell size in px; default probes the tty
--             (TIOCGWINSZ) and falls back to 10x20 -- kitty fits the image
--             preserving aspect ratio, so rough is fine
--   writer    fun(data) escape sink; default sends to v:stderr, bypassing
--             nvim's TUI

local dims = require("fibrous.image.dims")
local kitty = require("fibrous.image.kitty")
local detect = require("fibrous.image.detect")

local M = {}

local function defaults()
  return { provider = "auto", cell_px = nil, writer = nil }
end

M.config = defaults()

local registry = {} ---@type table<integer, { refs: integer, spec: table }>
local resolved = nil ---@type ImageDetection|nil
local resolved_for = nil ---@type string|nil  config.provider the cache was computed under
local warned = false
local cleanup_armed = false
local cell_px_probed = nil

-- Reset caches, refcounts and config to a pristine state (config changes at
-- runtime, tests). Does NOT write delete escapes -- retained images are simply
-- forgotten, as after a terminal restart.
function M.reset()
  registry = {}
  resolved = nil
  resolved_for = nil
  warned = false
  cell_px_probed = nil
  M.config = defaults()
end

---@return ImageDetection
local function provider()
  local forced = M.config.provider
  -- cached per config.provider value, so assigning the field later still
  -- takes effect (auto-detection itself runs at most once)
  if resolved and resolved_for == forced then
    return resolved
  end
  resolved_for = forced
  if forced == "kitty" or forced == "text" then
    resolved = { provider = forced, tmux = vim.env.TMUX ~= nil }
  else
    resolved = detect.provider(vim.fn.environ(), {
      termguicolors = vim.o.termguicolors,
      tmux_info = detect.tmux_info,
    })
  end
  if resolved.warn and not warned then
    warned = true
    local warn = resolved.warn
    vim.schedule(function()
      vim.notify(warn, vim.log.levels.WARN)
    end)
  end
  return resolved
end

-- Cell size in pixels from the controlling tty. Headless / some ssh paths
-- report 0 pixels; callers get the fallback via cell_px() below.
---@return { w: integer, h: integer }|nil
local function probe_cell_px()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil
  end
  pcall(
    ffi.cdef,
    [[
      typedef struct { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; } fibrous_winsize;
      int ioctl(int fd, unsigned long request, ...);
    ]]
  )
  local ok2, ws = pcall(ffi.new, "fibrous_winsize")
  if not ok2 then
    return nil
  end
  local ok3, ret = pcall(ffi.C.ioctl, 1, 0x5413, ws) -- TIOCGWINSZ
  if not ok3 or ret ~= 0 then
    return nil
  end
  local rows, cols = tonumber(ws.ws_row), tonumber(ws.ws_col)
  local xp, yp = tonumber(ws.ws_xpixel), tonumber(ws.ws_ypixel)
  if rows == 0 or cols == 0 or xp == 0 or yp == 0 then
    return nil
  end
  return { w = math.floor(xp / cols), h = math.floor(yp / rows) }
end

---@return { w: integer, h: integer }
local function cell_px()
  if M.config.cell_px then
    return M.config.cell_px
  end
  if not cell_px_probed then
    cell_px_probed = probe_cell_px() or { w = 10, h = 20 }
  end
  return cell_px_probed
end

local function round(x)
  return math.floor(x + 0.5)
end

-- The placeholder grid addresses at most #diacritics rows/cols.
local GRID_MAX = 296

-- Resolve image props into a displayable spec, or nil + reason (unsupported
-- provider, non-PNG content) -- the component shows its alt text then.
--
-- Sizing: explicit `cols`/`rows` win (one given, the other derives from the
-- aspect ratio); otherwise natural size = pixel dims / cell_px, scaled down
-- aspect-preserving to fit `max_cols`/`max_rows`.
---@param props { b64?: string, data?: string, cols?: integer, rows?: integer, max_cols?: integer, max_rows?: integer }
---@return { id: integer, hl: string, cols: integer, rows: integer, b64: string }|nil spec
---@return string|nil reason
function M.spec(props)
  local p = provider()
  if p.provider ~= "kitty" then
    return nil, p.reason or "image provider is text"
  end
  local b64 = props.b64
  if b64 then
    if b64:find("%s") then
      b64 = b64:gsub("%s", "") -- ipynb wraps base64 in newlines
    end
  elseif props.data then
    b64 = vim.base64.encode(props.data)
  else
    return nil, "image needs `b64` or `data`"
  end
  local px = dims.png_b64(b64)
  if not px then
    return nil, "content is not a PNG"
  end
  local cell = cell_px()
  local nat_c = math.max(round(px.w / cell.w), 1)
  local nat_r = math.max(round(px.h / cell.h), 1)
  local cols, rows = props.cols, props.rows
  if cols and not rows then
    rows = round(nat_r * cols / nat_c)
  elseif rows and not cols then
    cols = round(nat_c * rows / nat_r)
  elseif not cols then
    local scale = math.min(1, (props.max_cols or math.huge) / nat_c, (props.max_rows or math.huge) / nat_r)
    cols, rows = round(nat_c * scale), round(nat_r * scale)
  end
  cols = math.min(math.max(cols, 1), GRID_MAX)
  rows = math.min(math.max(rows, 1), GRID_MAX)
  local id = tonumber(vim.fn.sha256(b64 .. ":" .. cols .. "x" .. rows):sub(1, 6), 16)
  if id == 0 then
    id = 1 -- id 0 is invalid in the protocol
  end
  return { id = id, hl = ("FibrousImage_%06x"):format(id), cols = cols, rows = rows, b64 = b64 }
end

local function write(escapes)
  local w = M.config.writer or function(data)
    vim.fn.chansend(vim.v.stderr, data)
  end
  w(escapes)
end

-- Free every live image at exit: kitty keeps transmitted data per window, and
-- under tmux that window outlives this nvim. Per-id deletes (never d=A -- a
-- sibling tmux pane may have its own images in the same kitty window).
local function arm_cleanup()
  if cleanup_armed then
    return
  end
  cleanup_armed = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      local wrap = provider().tmux
      local out = {}
      for id in pairs(registry) do
        local esc = kitty.delete(id)
        out[#out + 1] = wrap and kitty.tmux_wrap(esc) or esc
      end
      registry = {}
      if #out > 0 then
        write(table.concat(out))
      end
    end,
  })
end

---@param spec { id: integer, hl: string, cols: integer, rows: integer, b64: string }
function M.retain(spec)
  local entry = registry[spec.id]
  if entry then
    entry.refs = entry.refs + 1
    return
  end
  registry[spec.id] = { refs = 1, spec = spec }
  vim.api.nvim_set_hl(0, spec.hl, { fg = spec.id })
  arm_cleanup()
  local chunks = kitty.transmit(spec.b64, { id = spec.id, cols = spec.cols, rows = spec.rows })
  if provider().tmux then
    for i, c in ipairs(chunks) do
      chunks[i] = kitty.tmux_wrap(c)
    end
  end
  write(table.concat(chunks))
end

---@param spec { id: integer }
function M.release(spec)
  local entry = registry[spec.id]
  if not entry then
    return
  end
  entry.refs = entry.refs - 1
  if entry.refs > 0 then
    return
  end
  registry[spec.id] = nil
  local esc = kitty.delete(spec.id)
  write(provider().tmux and kitty.tmux_wrap(esc) or esc)
end

return M
