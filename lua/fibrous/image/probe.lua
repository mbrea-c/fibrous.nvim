-- Terminal capability probing. Instead of trusting env vars, ask the terminal
-- and read its answer: nvim surfaces terminal replies (OSC, DCS, CSI and APC
-- alike, verified on 0.12) through the TermResponse autocmd, so a query
-- bracketed by DA1 (`CSI c`, which every terminal answers) gives three
-- distinguishable outcomes: the capability reply arrived (supported), DA1
-- arrived without it (not supported), or nothing arrived (the response never
-- routed back, e.g. tmux dropping passthrough replies -- the caller falls
-- back to env signals).
--
-- `classify` is the pure response parser; `new` builds a serialized query
-- engine with writer / TermResponse subscription / timer all injectable
-- (production wiring lives in fibrous.image). Serialization matters: two
-- concurrent jobs would both match the shared DA1 bracket shape.

local M = {}

-- Queries whose replies classify() recognizes. The graphics query is in
-- kitty.lua (it needs the APC builder); these two are bare constants.
M.XTVERSION = "\27[>q"
M.DA1 = "\27[c"

---@class ProbeEvent
---@field kind "graphics"|"xtversion"|"da1"|"clipboard"
---@field id? integer   graphics: the i= query id the reply carries
---@field msg? string   graphics: OK or an error tag
---@field version? string  xtversion: the terminal's name/version text
---@field status? string   clipboard: the OSC 5522 status value

-- Parse one TermResponse sequence (terminator already stripped by nvim) into
-- a ProbeEvent, or nil for anything a probe never asked about.
---@param seq string
---@return ProbeEvent|nil
function M.classify(seq)
  -- kitty graphics APC reply: ESC _ G <keys> ; <msg>. Replying at all -- OK
  -- or error -- proves the terminal speaks the graphics protocol.
  local keys, msg = seq:match("^\27_G([^;]*);(.*)$")
  if keys then
    local id = tonumber(keys:match("i=(%d+)"))
    if id then
      return { kind = "graphics", id = id, msg = msg }
    end
    return nil
  end
  -- XTVERSION DCS reply: ESC P > | <text>
  local version = seq:match("^\27P>|(.*)$")
  if version then
    return { kind = "xtversion", version = version }
  end
  -- DA1 CSI reply: ESC [ ? <attrs> c
  if seq:match("^\27%[%?[%d;]*c$") then
    return { kind = "da1" }
  end
  -- kitty clipboard protocol OSC reply: ESC ] 5522 ; <metadata>
  local meta = seq:match("^\27%]5522;(.*)$")
  if meta then
    return { kind = "clipboard", status = meta:match("status=([%w_]+)") }
  end
  return nil
end

-- The query id our graphics capability queries carry (replies for any other
-- id belong to someone else's probe).
M.QUERY_ID = 31

-- The graphics-capability job for the engine: one volley of graphics query +
-- XTVERSION + DA1 bracket, and a reducer that collects what answered until
-- the bracket lands. Result: { graphics: boolean, version: string|nil };
-- detect.confirm folds it into the env-based resolution.
---@param opts { query: string, wrap?: fun(esc: string): string }
---@return { escapes: string, reduce: fun(evt: ProbeEvent): table|nil }
function M.capability_job(opts)
  local wrap = opts.wrap or function(esc)
    return esc
  end
  local state = { graphics = false, version = nil }
  return {
    escapes = wrap(opts.query) .. wrap(M.XTVERSION) .. wrap(M.DA1),
    reduce = function(evt)
      if evt.kind == "graphics" and evt.id == M.QUERY_ID then
        state.graphics = true
      elseif evt.kind == "xtversion" then
        state.version = evt.version
      elseif evt.kind == "da1" then
        return state
      end
      return nil
    end,
  }
end

---@class ProbeJob
---@field escapes string  query bytes, already tmux-wrapped by the caller
---@field timeout integer  ms until done(nil)
---@field reduce fun(evt: ProbeEvent): any|nil  non-nil finishes the job
---@field done fun(result: any|nil)  nil means timeout

---@class ProbeEngine
---@field run fun(self: ProbeEngine, job: ProbeJob)
---@field teardown fun(self: ProbeEngine)

---@param deps { writer: fun(data: string), arm: fun(on_seq: fun(seq: string)): fun(), defer: fun(ms: integer, cb: fun()): fun() }
---@return ProbeEngine
function M.new(deps)
  local queue = {} ---@type ProbeJob[]
  local active = nil ---@type ProbeJob|nil
  local disarm = nil ---@type fun()|nil
  local cancel = nil ---@type fun()|nil

  local start_next

  local function finish(result)
    local job = active
    if cancel then
      cancel()
      cancel = nil
    end
    active = nil
    if job then
      job.done(result)
    end
    start_next()
  end

  local function on_seq(seq)
    if not active then
      return
    end
    local evt = M.classify(seq)
    if not evt then
      return
    end
    local result = active.reduce(evt)
    if result ~= nil then
      finish(result)
    end
  end

  start_next = function()
    if active then
      return
    end
    local job = table.remove(queue, 1)
    if not job then
      if disarm then
        disarm()
        disarm = nil
      end
      return
    end
    active = job
    if not disarm then
      disarm = deps.arm(on_seq)
    end
    deps.writer(job.escapes)
    cancel = deps.defer(job.timeout, function()
      cancel = nil
      finish(nil)
    end)
  end

  return {
    run = function(_, job)
      queue[#queue + 1] = job
      start_next()
    end,
    teardown = function(_)
      queue = {}
      active = nil
      if cancel then
        cancel()
        cancel = nil
      end
      if disarm then
        disarm()
        disarm = nil
      end
    end,
  }
end

return M
