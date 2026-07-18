-- Copy an inline image to the SYSTEM clipboard. Two backends:
--
--   osc5522  kitty's clipboard-data protocol: the escape travels to the
--            terminal that owns the clipboard, so it works over ssh (+tmux,
--            passthrough-wrapped) and carries real image/png MIME data.
--            kitty confirms a write with `status=DONE`; a terminal without
--            the protocol stays silent -- so the FIRST copy doubles as the
--            capability probe (bracketed with DA1 via fibrous.image.probe)
--            and the learned backend is cached for the rest of the session.
--   tool     wl-copy / xclip / osascript with the decoded PNG on stdin, for
--            terminals without the protocol (ghostty) when a display is
--            reachable.
--
-- Pure pieces (escape builder, tool chooser) + a copy flow whose engine,
-- writer, runner and notify are all injected by fibrous.image -- this module
-- never touches config, terminals or processes itself.

local probe = require("fibrous.image.probe")

local M = {}

local ESC = "\27"
local ST = ESC .. "\\"
local PNG_MIME = vim.base64.encode("image/png")
-- The protocol chunks at 4096 DATA bytes; 5460 base64 chars = 4095 bytes,
-- which is both 4-char aligned (each chunk decodes independently) and a
-- multiple of 3 (no mid-stream padding).
local CHUNK = 5460

-- Learned backend for this session ("osc5522" | "tool"), nil = not yet known.
M.state = { backend = nil }

function M.reset()
  M.state.backend = nil
end

-- The OSC 5522 write transaction for one base64 PNG payload: start, wdata
-- chunks carrying the mime (itself base64, per protocol), empty terminator.
---@param b64 string
---@return string[] escapes
function M.osc_write(b64)
  local out = { ESC .. "]5522;type=write" .. ST }
  local pos = 1
  repeat
    local chunk = b64:sub(pos, pos + CHUNK - 1)
    pos = pos + CHUNK
    out[#out + 1] = ESC .. "]5522;type=wdata:mime=" .. PNG_MIME .. ";" .. chunk .. ST
  until pos > #b64
  out[#out + 1] = ESC .. "]5522;type=wdata" .. ST
  return out
end

-- Pick a local clipboard tool: an argv taking the PNG on stdin, or the
-- osascript marker (macOS wants a file coerced to a PNGf clipboard class).
---@param env table<string, string>
---@param has fun(bin: string): boolean
---@param is_mac? boolean
---@return { argv?: string[], osascript?: boolean }|nil
function M.tool(env, has, is_mac)
  if is_mac and has("osascript") then
    return { osascript = true }
  end
  if env.WAYLAND_DISPLAY and has("wl-copy") then
    return { argv = { "wl-copy", "-t", "image/png" } }
  end
  if env.DISPLAY and has("xclip") then
    return { argv = { "xclip", "-selection", "clipboard", "-t", "image/png", "-i" } }
  end
  return nil
end

local function size_label(b64)
  local kb = math.floor(#b64 * 3 / 4 / 1024 + 0.5)
  return (kb > 0 and kb or 1) .. "kB png"
end

---@class ClipboardCtx
---@field backend "auto"|"osc5522"|"tool"|"off"
---@field engine ProbeEngine
---@field writer fun(data: string)
---@field wrap boolean  tmux passthrough-wrap escapes
---@field notify fun(msg: string, level: integer)
---@field runner fun(spec: table, bytes: string, cb: fun(ok: boolean, err?: string))
---@field env table<string, string>
---@field has fun(bin: string): boolean
---@field is_mac? boolean
---@field tool_argv? string[]  config override, used verbatim
---@field env_says_kitty boolean  tie-break when a probe times out

---@param b64 string
---@param ctx ClipboardCtx
function M.copy(b64, ctx)
  local kitty = require("fibrous.image.kitty")
  local function wrapped(esc)
    return ctx.wrap and kitty.tmux_wrap(esc) or esc
  end
  local ok_msg = "fibrous: image copied to clipboard (" .. size_label(b64) .. ")"

  local function run_tool()
    local spec = ctx.tool_argv and { argv = ctx.tool_argv } or M.tool(ctx.env, ctx.has, ctx.is_mac)
    if not spec then
      ctx.notify(
        "fibrous: no clipboard route: terminal lacks the kitty clipboard protocol and no wl-copy/xclip found",
        vim.log.levels.WARN
      )
      return
    end
    ctx.runner(spec, vim.base64.decode(b64), function(ok, err)
      if ok then
        ctx.notify(ok_msg, vim.log.levels.INFO)
      else
        ctx.notify("fibrous: clipboard tool failed: " .. (err or "?"), vim.log.levels.WARN)
      end
    end)
  end

  local function write_osc()
    local out = {}
    for _, esc in ipairs(M.osc_write(b64)) do
      out[#out + 1] = wrapped(esc)
    end
    return table.concat(out)
  end

  local backend = ctx.backend ~= "auto" and ctx.backend or M.state.backend
  if backend == "off" then
    return
  end
  if backend == "osc5522" then
    -- learned or forced: trusted, no bracket, no round trip
    ctx.writer(write_osc())
    ctx.notify(ok_msg, vim.log.levels.INFO)
    return
  end
  if backend == "tool" then
    run_tool()
    return
  end

  -- Unlearned: this write doubles as the capability probe.
  ctx.engine:run({
    escapes = write_osc() .. wrapped(probe.DA1),
    timeout = 1000,
    reduce = function(evt)
      if evt.kind == "clipboard" then
        return evt.status == "DONE" and "done" or "failed"
      end
      if evt.kind == "da1" then
        return "unsupported"
      end
      return nil
    end,
    done = function(result)
      if result == "done" then
        M.state.backend = "osc5522"
        ctx.notify(ok_msg, vim.log.levels.INFO)
      elseif result == "unsupported" or result == "failed" then
        M.state.backend = "tool"
        run_tool()
      elseif ctx.env_says_kitty then
        -- timeout, but every env signal says the terminal is kitty: the
        -- response just never routed back (tmux). Trust the write.
        M.state.backend = "osc5522"
        ctx.notify(ok_msg .. " (unconfirmed: no terminal response)", vim.log.levels.INFO)
      else
        run_tool()
      end
    end,
  })
end

return M
