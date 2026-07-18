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
-- Zero-config: the provider auto-detects (detect.lua env signals, then a
-- capability probe -- probe.lua asks the terminal itself and corrects the env
-- answer either way) and everything has a default. `config` fields can be
-- assigned directly when needed:
--   provider   "auto" (default) | "kitty" (force) | "text" (disable)
--   cell_px    { w, h } terminal cell size in px; default probes the tty
--              (TIOCGWINSZ) and falls back to 10x20 -- kitty fits the image
--              preserving aspect ratio, so rough is fine
--   writer     fun(data) escape sink; default sends to v:stderr, bypassing
--              nvim's TUI
--   clipboard  "auto" (default: the first copy() doubles as an OSC 5522
--              capability probe and learns) | "osc5522" | "tool" | "off"
--   clipboard_tool  argv override for the local-tool backend
--   notify     fun(msg, level) override (tests); default vim.notify

local dims = require("fibrous.image.dims")
local kitty = require("fibrous.image.kitty")
local detect = require("fibrous.image.detect")
local probe = require("fibrous.image.probe")
local clipboard = require("fibrous.image.clipboard")

local M = {}

local function defaults()
  return {
    provider = "auto",
    cell_px = nil,
    writer = nil,
    clipboard = "auto",
    clipboard_tool = nil,
    notify = nil,
  }
end

M.config = defaults()

local registry = {} ---@type table<integer, { refs: integer, spec: table }>
local resolved = nil ---@type ImageDetection|nil
local resolved_for = nil ---@type string|nil  config.provider the cache was computed under
local last_kind = nil ---@type string|nil  previous resolution's provider, for change detection across refresh()
local listeners = {} ---@type table<fun(), true>  on_change subscribers (mounted image components)
local epoch_n = 0 -- bumped on every provider change; components memo against it
local probed = false -- capability probe fired for this session/refresh
local engine = nil ---@type ProbeEngine|nil
local warned = false
local cleanup_armed = false
local cell_px_probed = nil

local function write(escapes)
  local w = M.config.writer or function(data)
    vim.fn.chansend(vim.v.stderr, data)
  end
  w(escapes)
end

local function notify(msg, level)
  local n = M.config.notify or vim.notify
  n(msg, level)
end

-- Reset caches, refcounts and config to a pristine state (config changes at
-- runtime, tests). Does NOT write delete escapes -- retained images are simply
-- forgotten, as after a terminal restart.
function M.reset()
  registry = {}
  resolved = nil
  resolved_for = nil
  last_kind = nil
  listeners = {}
  probed = false
  if engine then
    engine:teardown()
    engine = nil
  end
  clipboard.reset()
  warned = false
  cell_px_probed = nil
  M.config = defaults()
end

-- Adopt a resolution; a provider-kind change (probe correction, refresh under
-- new config) bumps the epoch and wakes subscribed components so mounted
-- images re-render under the new provider.
---@param det ImageDetection
local function set_resolved(det)
  local changed = last_kind ~= nil and last_kind ~= det.provider
  last_kind = det.provider
  resolved = det
  if not changed then
    return
  end
  epoch_n = epoch_n + 1
  vim.schedule(function()
    for fn in pairs(listeners) do
      pcall(fn)
    end
  end)
end

-- The production probe engine: escapes through write(), replies through
-- TermResponse (nvim surfaces OSC/DCS/CSI/APC replies there; verified 0.12).
local function get_engine()
  if engine then
    return engine
  end
  engine = probe.new({
    writer = write,
    arm = function(on_seq)
      local id = vim.api.nvim_create_autocmd("TermResponse", {
        callback = function(ev)
          local seq = (ev.data and ev.data.sequence) or (vim.v.event and vim.v.event.sequence)
          if seq then
            on_seq(seq)
          end
        end,
      })
      return function()
        pcall(vim.api.nvim_del_autocmd, id)
      end
    end,
    defer = function(ms, cb)
      local t = vim.defer_fn(cb, ms)
      return function()
        pcall(function()
          t:stop()
          t:close()
        end)
      end
    end,
  })
  return engine
end

-- Ask the terminal what it is and whether it speaks the graphics protocol,
-- and fold the answer into the env-based resolution (detect.confirm): a
-- kitty/ghostty identity promotes an unidentified terminal, a foreign one
-- demotes an env liar, silence (tmux dropping replies) changes nothing.
---@param det ImageDetection
local function run_capability_probe(det)
  local wrap = det.tmux and kitty.tmux_wrap or nil
  local job = probe.capability_job({ query = kitty.query(probe.QUERY_ID), wrap = wrap })
  get_engine():run({
    escapes = job.escapes,
    timeout = 1000,
    reduce = job.reduce,
    done = function(result)
      if not resolved then
        return
      end
      local folded = result
        and { graphics = result.graphics, identity = result.version and detect.identity(result.version) or nil }
      local new = detect.confirm(resolved, folded)
      if new then
        set_resolved(new)
        if new.provider == "text" and new.reason then
          notify("fibrous: inline images disabled: " .. new.reason, vim.log.levels.WARN)
        end
      end
    end,
  })
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
    set_resolved({ provider = forced, tmux = vim.env.TMUX ~= nil })
  else
    set_resolved(detect.provider(vim.fn.environ(), {
      termguicolors = vim.o.termguicolors,
      tmux_info = detect.tmux_info,
    }))
    -- Confirm/correct the env answer by asking the terminal itself -- once,
    -- and only where a terminal can answer (headless has no one to ask).
    if resolved.probeable and not probed and #vim.api.nvim_list_uis() > 0 then
      probed = true
      local det = resolved
      vim.schedule(function()
        run_capability_probe(det)
      end)
    end
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

-- Re-run detection (and its capability probe) NOW: after a config change, a
-- terminal reattach, an ssh reconnect. Mounted images re-render if the
-- provider changed.
function M.refresh()
  resolved = nil
  resolved_for = nil
  probed = false
  provider()
end

-- Epoch of the current provider resolution: bumped on every provider change,
-- compared by the component's spec memo so a change invalidates it.
---@return integer
function M.epoch()
  return epoch_n
end

-- Subscribe to provider changes (probe corrections, refresh); returns the
-- unsubscribe. Fired via vim.schedule, after the change is visible.
---@param fn fun()
---@return fun()
function M.on_change(fn)
  listeners[fn] = true
  return function()
    listeners[fn] = nil
  end
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

-- The base64 content of a LIVE (retained) image, or nil. Displayed images are
-- always retained, so this is what the yy copy path resolves an id through.
---@param id integer
---@return string|nil
function M.b64(id)
  local entry = registry[id]
  return entry and entry.spec.b64 or nil
end

-- Copy a live image to the SYSTEM clipboard (interact.lua binds this to `yy`
-- over image cells; apps can call it directly). Backend per config.clipboard:
-- the default "auto" makes the first copy double as an OSC 5522 capability
-- probe (see clipboard.lua) and caches what it learns.
---@param id integer
function M.copy(id)
  local b64 = M.b64(id)
  if not b64 then
    notify("fibrous: no live image with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  local det = provider()
  clipboard.copy(b64, {
    backend = M.config.clipboard,
    engine = get_engine(),
    writer = write,
    wrap = det.tmux,
    notify = notify,
    runner = function(spec, bytes, cb)
      if spec.osascript then
        local path = vim.fn.tempname() .. ".png"
        local f = io.open(path, "wb")
        if not f then
          cb(false, "tempfile failed")
          return
        end
        f:write(bytes)
        f:close()
        spec = { argv = {
          "osascript",
          "-e",
          ('set the clipboard to (read (POSIX file "%s") as «class PNGf»)'):format(path),
        } }
        bytes = nil
      end
      vim.system(spec.argv, { stdin = bytes }, function(out)
        vim.schedule(function()
          cb(out.code == 0, out.stderr and out.stderr:gsub("%s+$", "") or nil)
        end)
      end)
    end,
    env = vim.fn.environ(),
    has = function(bin)
      return vim.fn.executable(bin) == 1
    end,
    is_mac = vim.fn.has("mac") == 1,
    tool_argv = M.config.clipboard_tool,
    env_says_kitty = det.provider == "kitty",
  })
end

return M
