-- Benchmark-only, exclusive wall-clock phase accounting.
-- Hooks exist only during measure(); normal library execution is untouched.
local M = {}
local Profile = {}
Profile.__index = Profile

function M.new(opts)
  return setmetatable({ clock = opts and opts.clock or vim.uv.hrtime, hooks = {} }, Profile)
end

function Profile:wrap(owner, key, phase)
  assert(type(owner[key]) == "function", key .. " must be a function")
  assert(phase ~= "other", "'other' is reserved for uninstrumented time")
  for _, hook in ipairs(self.hooks) do
    assert(hook.owner ~= owner or hook.key ~= key, key .. " is already registered")
  end
  self.hooks[#self.hooks + 1] = { owner = owner, key = key, phase = phase }
end

-- Keeping the varargs on the stack preserves nil/multiple returns without
-- allocating a results table for every timed buffer API or row extraction.
local function finish_scope(self, phase, depth, ok, ...)
  local elapsed = self.clock() - self.starts[depth]
  self.ns[phase] = (self.ns[phase] or 0) + elapsed - self.children[depth]
  self.calls[phase] = (self.calls[phase] or 0) + 1
  self.depth = depth - 1
  if depth > 1 then
    self.children[depth - 1] = self.children[depth - 1] + elapsed
  end
  if not ok then error((...), 0) end
  return ...
end

function Profile:scope(phase, fn, ...)
  if not self.active then return fn(...) end
  assert(phase ~= "other", "'other' is reserved for uninstrumented time")
  local depth = self.depth + 1
  self.depth = depth
  self.starts[depth], self.children[depth] = self.clock(), 0
  return finish_scope(self, phase, depth, pcall(fn, ...))
end

local function finish_measure(self, start, saved, ok, ...)
  local total = self.clock() - start
  self.active = false
  for i = #saved, 1, -1 do
    local hook = saved[i]
    hook.owner[hook.key] = hook.original
  end
  if not ok then error((...), 0) end
  local report = { total_ms = total / 1e6, phases_ms = {}, calls = self.calls }
  local accounted = 0
  for phase, ns in pairs(self.ns) do
    report.phases_ms[phase] = ns / 1e6
    accounted = accounted + ns
  end
  report.phases_ms.other = math.max(0, total - accounted) / 1e6
  return report, ...
end

function Profile:measure(fn, ...)
  assert(not self.active, "a measurement is already active")
  -- Validate the complete set before changing any shared function tables.
  for _, hook in ipairs(self.hooks) do
    assert(type(hook.owner[hook.key]) == "function", hook.key .. " must be a function")
  end
  self.ns, self.calls, self.starts, self.children, self.depth = {}, {}, {}, {}, 0
  local saved = {}
  for _, hook in ipairs(self.hooks) do
    local original, phase = hook.owner[hook.key], hook.phase
    saved[#saved + 1] = { owner = hook.owner, key = hook.key, original = original }
    self.ns[phase], self.calls[phase] = 0, 0
    hook.owner[hook.key] = function(...) return self:scope(phase, original, ...) end
  end
  self.active = true
  local start = self.clock()
  return finish_measure(self, start, saved, pcall(fn, ...))
end

-- Only coarse entry points and row extraction are wrapped, never cells/words.
-- Nested calls, including Canvas.lines -> Canvas.line, count their time once.
function M.standard(opts)
  local p = M.new(opts)
  local canvas = require("fibrous.inline.canvas")
  local methods = getmetatable(canvas.new(0, 0))
  p:wrap(require("fibrous.inline.layout"), "compute", "layout")
  p:wrap(canvas, "new", "canvas_allocate")
  p:wrap(methods, "grow", "canvas_allocate")
  local render = require("fibrous.inline.render")
  p:wrap(render, "paint", "paint")
  p:wrap(render, "update", "paint")
  p:wrap(methods, "lines", "text_extract")
  p:wrap(methods, "line", "text_extract")
  p:wrap(methods, "highlights", "highlight_extract")
  p:wrap(methods, "row_spans", "highlight_extract")
  p:wrap(vim.api, "nvim_buf_set_lines", "buffer_text")
  p:wrap(vim.api, "nvim_buf_set_text", "buffer_text")
  p:wrap(vim.api, "nvim_buf_clear_namespace", "buffer_highlights")
  p:wrap(vim.api, "nvim_buf_set_extmark", "buffer_highlights")
  p:wrap(require("fibrous.sources"), "update", "sources")
  return p
end

local function percentile(values, fraction)
  table.sort(values)
  return values[math.max(1, math.ceil(#values * fraction))]
end

function M.summarize(frames)
  assert(#frames > 0, "cannot summarize an empty frame set")
  local result = { mean_ms = 0, phases = {} }
  local times = {}
  for i, frame in ipairs(frames) do
    result.mean_ms = result.mean_ms + frame.total_ms / #frames
    times[i] = frame.total_ms
    if not result.slowest or frame.total_ms > result.slowest.total_ms then
      result.slowest = { index = i, total_ms = frame.total_ms, phases_ms = frame.phases_ms }
    end
    for phase in pairs(frame.phases_ms) do
      result.phases[phase] = result.phases[phase] or { mean_ms = 0, calls_per_frame = 0, values = {} }
    end
  end
  result.p50_ms, result.p95_ms = percentile(times, 0.5), percentile(times, 0.95)
  for phase, out in pairs(result.phases) do
    for i, frame in ipairs(frames) do
      local ms = frame.phases_ms[phase] or 0
      out.mean_ms = out.mean_ms + ms / #frames
      out.calls_per_frame = out.calls_per_frame + (frame.calls[phase] or 0) / #frames
      out.values[i] = ms
    end
    out.p50_ms, out.p95_ms = percentile(out.values, 0.5), percentile(out.values, 0.95)
    out.values = nil
  end
  return result
end

M.order = { "layout", "canvas_allocate", "paint", "text_extract", "highlight_extract",
  "buffer_text", "buffer_highlights", "sources", "redraw", "other" }

function M.format(summary)
  local lines = {}
  for _, phase in ipairs(M.order) do
    local row = summary.phases[phase]
    if row then
      lines[#lines + 1] = ("  %-20s %8.3f ms  %5.1f%%  %s calls/frame"):format(
        phase, row.mean_ms, summary.mean_ms > 0 and row.mean_ms / summary.mean_ms * 100 or 0,
        phase == "other" and "-" or ("%.1f"):format(row.calls_per_frame))
    end
  end
  lines[#lines + 1] = ("  slowest frame #%d: %.3f ms; p95 %.3f ms")
    :format(summary.slowest.index, summary.slowest.total_ms, summary.p95_ms)
  return table.concat(lines, "\n")
end

return M
