-- Image provider auto-detection: a pure function of an env table plus
-- injectable facts (termguicolors, a tmux prober), so every terminal
-- combination is testable headless. fibrous.image calls it once and caches.

local M = {}

-- Does this TERM/env identify a terminal with Unicode placeholder support?
-- kitty and ghostty both implement them; WezTerm implements the graphics
-- protocol but NOT placeholders, so it is excluded deliberately.
---@param env table<string, string>
---@return boolean
local function placeholder_term(env)
  local term = env.TERM or ""
  if term:find("kitty", 1, true) or term:find("ghostty", 1, true) then
    return true
  end
  if env.KITTY_WINDOW_ID or env.GHOSTTY_RESOURCES_DIR then
    return true
  end
  local prog = env.TERM_PROGRAM
  return prog == "kitty" or prog == "ghostty"
end

---@class ImageDetection
---@field provider "kitty"|"text"
---@field tmux boolean
---@field reason? string  why the provider degraded to text
---@field warn? string    user-actionable problem, surfaced once by the caller
---@field probeable? boolean  worth confirming/promoting via a capability probe (fibrous.image.probe): the env answer could be wrong AND queries can reach the terminal

---@param env table<string, string>
---@param opts { termguicolors: boolean, tmux_info?: fun(): { term?: string, passthrough?: string }|nil }
---@return ImageDetection
function M.provider(env, opts)
  opts = opts or {}
  if not opts.termguicolors then
    return { provider = "text", tmux = false, reason = "termguicolors is off (image ids ride on RGB foregrounds)" }
  end
  if env.TMUX then
    local info = opts.tmux_info and opts.tmux_info() or nil
    if not info or not info.term then
      return { provider = "text", tmux = true, reason = "could not query the outer terminal through tmux" }
    end
    -- without passthrough, neither images nor probe queries reach the outer
    -- terminal, so nothing below is probeable
    local passthrough = info.passthrough == "on" or info.passthrough == "all"
    if not placeholder_term({ TERM = info.term }) then
      return {
        provider = "text",
        tmux = true,
        reason = "outer terminal '" .. info.term .. "' has no placeholder support",
        probeable = passthrough,
      }
    end
    if not passthrough then
      return {
        provider = "text",
        tmux = true,
        reason = "tmux allow-passthrough is off",
        warn = "fibrous: inline images need `set -g allow-passthrough on` in tmux",
      }
    end
    return { provider = "kitty", tmux = true, probeable = true }
  end
  if env.TERM_PROGRAM == "WezTerm" then
    return { provider = "text", tmux = false, reason = "WezTerm has no Unicode placeholder support" }
  end
  if placeholder_term(env) then
    return { provider = "kitty", tmux = false, probeable = true }
  end
  return { provider = "text", tmux = false, reason = "terminal not identified as kitty/ghostty", probeable = true }
end

-- The terminal's normalized name from an XTVERSION reply ("kitty(0.47.4)",
-- "WezTerm 20240203-...", "tmux 3.5a"): lowercased leading word, or nil.
---@param version string
---@return string|nil
function M.identity(version)
  local name = version:match("^%s*([%a][%w_%-]*)")
  return name and name:lower() or nil
end

-- Terminals whose identity implies Unicode placeholder support. Identity, not
-- the graphics reply, is the decider: WezTerm and Konsole answer graphics
-- queries yet do not render placeholders, so speaking the protocol proves
-- nothing about the placement style we use.
local PLACEHOLDER_IDENTITIES = { kitty = true, ghostty = true }

-- Fold a capability-probe result into an env-based resolution: the corrected
-- ImageDetection, or nil for "no change". `probe` nil = timeout (responses
-- never routed back): the env answer stands. An `identity` of "tmux" means
-- tmux answered the queries itself (they never reached the outer terminal),
-- which proves nothing either way.
---@param current ImageDetection
---@param probe { graphics: boolean|nil, identity: string|nil }|nil
---@return ImageDetection|nil
function M.confirm(current, probe)
  if not probe or probe.identity == "tmux" then
    return nil
  end
  if probe.identity then
    if PLACEHOLDER_IDENTITIES[probe.identity] then
      if current.provider ~= "kitty" then
        return { provider = "kitty", tmux = current.tmux }
      end
      return nil
    end
    if current.provider == "kitty" then
      return {
        provider = "text",
        tmux = current.tmux,
        reason = "terminal identified itself as '" .. probe.identity .. "' (no placeholder support)",
      }
    end
    return nil
  end
  -- no identity reply: only the hard negative acts (bracket came back, the
  -- graphics query was ignored -- whatever the env said, images cannot work)
  if probe.graphics == false and current.provider == "kitty" then
    return {
      provider = "text",
      tmux = current.tmux,
      reason = "terminal did not answer a graphics capability query",
    }
  end
  return nil
end

-- The real tmux prober: one `tmux display` answers both questions (formats
-- expand option names, so allow-passthrough needs no separate `show`).
---@return { term: string, passthrough: string }|nil
function M.tmux_info()
  local ok, out = pcall(vim.fn.system, { "tmux", "display-message", "-p", "#{client_termname}\n#{allow-passthrough}" })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  local lines = vim.split(out, "\n", { plain = true })
  if not lines[1] or lines[1] == "" then
    return nil
  end
  return { term = lines[1], passthrough = lines[2] or "" }
end

return M
