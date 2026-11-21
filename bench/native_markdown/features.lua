-- One backend and feature per Neovim process. Verification inspects each step.
package.path = "./lua/?.lua;./lua/?/init.lua;./bench/?.lua;" .. package.path
local dir = "bench/native_markdown/"
local mode, case = assert(vim.env.BENCH_MODE), assert(vim.env.BENCH_CASE)
local pointer_test = vim.env.BENCH_PHASE == "pty"
local verify = pointer_test or vim.env.BENCH_PHASE == "verify"
local count = tonumber(vim.env.BENCH_N) or 40
assert(count > 0 and count == math.floor(count))
if mode == "lua" then
  dofile(dir .. "coalesced.lua")
else
  assert(mode == "rust")
end
local adapter = mode == "rust" and dofile(dir .. "adapter.lua")
local ui = require("fibrous.inline.components")
local Host = require("fibrous.inline.host")
local runtime = require("fibrous.reactive.runtime")
local sources = require("fibrous.sources")

local fixtures = {
  edits = "Paragraph %d contains **styled text** with several words to wrap.",
  stream = "Paragraph %d contains **styled text** with several words to wrap.",
  tables = "## Table %d\n\n| Left | Middle | Amount |\n| :--- | :---: | ---: |\n"
    .. "| alpha | **centered cell** | 12345 |\n| 界面 | short | 8 |",
  inline_math = "Example %d uses $E = mc^2$ and $x^2$ in a sentence with several words to wrap.",
  display_math = "Example %d\n\n$$\n\\frac{a}{b}\n$$",
  links = "Paragraph %d adds enough words here to wrap during a resize.",
}
local paragraphs = {}
for i = 1, count do paragraphs[i] = assert(fixtures[case]):format(i) end
local lead = "Anchor plain text before a stretch of words which fills several lines when the window narrows."
local link_text = "See [GUIDE detailed navigation TAIL](guide) beside [INDEX](index)."
local original = lead .. "\n\n" .. (case == "links" and link_text .. "\n\n" or "") .. table.concat(paragraphs, "\n\n")
local text = original
local events = {}
local function props(value, live)
  return {text = value, live = live, source = {id = "feature", text = value},
    on_link = function(url) events[#events + 1] = url end}
end
local size = {width = 72, height = 19, row = 0, col = 0, mode = "scroll"}
local host, get_size, on_flush, set_props, relayout, cleanup, handle
if case == "links" then
  local mount = require("fibrous.inline.mount")
  local new = Host.new
  Host.new = function(opts)
    host = new(opts)
    get_size, on_flush = opts.get_size, opts.on_flush
    return host
  end
  handle = mount.floating(ui.markdown, props(text), size)
  Host.new = new
  handle.focus()
  set_props, relayout, cleanup = handle.set_props, handle.relayout, handle.unmount
else
  get_size = function() return {width = size.width} end
  host = Host.new({get_size = get_size})
  local root = runtime.create_root(ui.markdown, props(text), {host = host})
  root:render()
  set_props = function(p) root:set_props(p) end
  relayout = function() host.relayout() end
  cleanup = function() root:unmount() end
end

local result = {case = case, mode = mode, n = count, status = "ok", frames = {}, samples = {}}
local function finish()
  cleanup()
  io.write(vim.json.encode(result) .. "\n")
end
if adapter then
  local ok, err = pcall(adapter.attach, host, get_size, on_flush)
  if not ok then
    -- Recognize the initial prototype's explicit layout refusals for before/after comparisons.
    -- Missing libraries, Lua errors, and other unexpected failures abort the run.
    local reason = tostring(err):match(":%d+: (.*)$")
    if reason ~= "only Markdown list-marker rows are supported"
        and reason ~= "only left-aligned Markdown columns are supported" then error(err) end
    result.status, result.reason = "unsupported", reason
    return finish()
  end
end

local function locate(lines, word)
  for row, line in ipairs(lines) do
    local at = line:find(word, 1, true)
    if at then return {row, at} end -- one-based row and byte column
  end
end
local function snapshot(step, issues)
  local lines = vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false)
  local marks, groups = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, host.ns, 0, -1, {details = true})) do
    local d = m[4]
    marks[#marks + 1] = {m[2], m[3], d.end_row, d.end_col, d.hl_group}
    groups[d.hl_group] = true
  end
  if case == "tables" then
    local complete = locate(lines, "12345") ~= nil
    if not locate(lines, "┼") or not locate(lines, "│") or complete ~= (size.width >= 30) then
      issues[#issues + 1] = "table separators or right-column clipping differ"
    end
    if complete and not locate(lines, "Left  │    Middle     │ Amount") then
      issues[#issues + 1] = "column alignment differs"
    end
  elseif case == "inline_math" then
    if not locate(lines, "²") or not groups.FibrousMathVariable or not groups["@markup.math"] then
      issues[#issues + 1] = "typeset inline math or styling missing"
    end
  elseif case == "display_math" then
    local bar = locate(lines, "─")
    if not bar or bar[2] ~= math.floor((size.width - 1) / 2) + 1
        or vim.trim(lines[bar[1] - 1]) ~= "a" or vim.trim(lines[bar[1] + 1]) ~= "b"
        or not groups.FibrousMathVariable then
      issues[#issues + 1] = "fraction stacking, centering or styling differs"
    end
  end
  local projected = {}
  for _, word in ipairs({"Anchor", "REVISION", "LIVECHUNK", "centered", "mc^2", "frac", "GUIDE", "TAIL"}) do
    local pos = text:find(word, 1, true)
    if pos then
      local places = sources.project("feature", pos - 1, pos - 1 + #word)
      local coords = {}
      for _, p in ipairs(places) do coords[#coords + 1] = {p.row, p.start_col, p.end_col} end
      projected[#projected + 1] = {word, coords}
      if word == "Anchor" and #coords == 0 then issues[#issues + 1] = "missing Anchor projection" end
    end
  end
  -- Record selection as well as source-to-display projection. Buffer handles differ between runs.
  local pos = locate(lines, "Anchor")
  if pos then
    local selection = sources.resolve(host.bufnr,
      {lnum = pos[1], col = pos[2], end_lnum = pos[1], end_col = pos[2] + 5})
    for _, r in ipairs(selection) do
      projected[#projected + 1] = {r.source.id, r.start_byte, r.end_byte, r.quote, r.precision}
    end
  end
  local function digest(value) return vim.fn.sha256(vim.json.encode(value)) end
  return {step = step, text = digest(lines), highlights = digest(marks), sources = digest(projected),
    events = vim.list_extend({}, events), issues = issues}
end

local recording = false
local function perform(op, fn)
  local start = vim.uv.hrtime()
  fn()
  if recording then
    local list = result.samples[op] or {}
    list[#list + 1] = (vim.uv.hrtime() - start) / 1e6
    result.samples[op] = list
  end
end
local function observe(label, issues)
  if verify then result.frames[#result.frames + 1] = snapshot(label, issues or {}) end
end
local function resize(w)
  size.width = w
  perform("resize", relayout)
end
local function edit(label, value, live)
  text = value
  local p = props(value, live)
  perform("edit", function() set_props(p) end)
  observe(label)
end
local function reflow(w, label, expected, absent)
  resize(w)
  local issues = {}
  if verify then
    local lines = vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false)
    if expected and not locate(lines, expected) then issues[#issues + 1] = "missing " .. expected end
    if absent and locate(lines, absent) then issues[#issues + 1] = "unexpected " .. absent end
  end
  observe(label, issues)
end
local function run_edits()
  local prefix = ("Paragraph %d contains "):format(math.ceil(count / 2))
  local at = assert(original:find(prefix .. "**styled text**", 1, true)) + #prefix
  local changed = original:sub(1, at - 1) .. "**REVISION replacement**" .. original:sub(at + #"**styled text**")
  edit("replace in the middle", changed)
  reflow(28, "resize after replacement", "REVISION")
  edit("append paragraph", changed .. "\n\nREVISION tail with **more text**.")
  reflow(49, "resize after append", "REVISION")
  edit("delete inserted and replaced text", original)
  reflow(72, "resize after deletion", nil, "REVISION")
end
local function run_stream()
  local chunk = original .. "\n\nLIVECHUNK **partial"
  edit("append an open bold span in live mode", chunk, true)
  reflow(25, "resize during streaming", "LIVECHUNK")
  chunk = chunk .. " complete**"
  edit("append closing delimiter in live mode", chunk, true)
  reflow(44, "resize completed live text", "**partial")
  edit("settle the same source", chunk, false)
  reflow(32, "resize settled Markdown", "LIVECHUNK", "**partial")
  edit("restore original document", original, false)
  reflow(72, "restore original width", nil, "LIVECHUNK")
end

local mouse = require("fibrous.inline.mousemove")
local initial_pointer = mouse._getmousepos
local function run_links()
  local wide
  for _, w in ipairs({72, 18, 37, 24, 72}) do
    if w ~= size.width then resize(w) end
    local lines = vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false)
    local issues = {}
    local function click(pos, expected)
      local row, col = pos[1], pos[2]
      local before = #events
      if pointer_test then
        vim.cmd("redraw")
        local pos = vim.fn.screenpos(handle.winid, row, col)
        assert(pos.row > 0 and pos.col > 0, "mouse target is outside the visible viewport")
        local api = vim.api
        api.nvim_input_mouse("left", "press", "", 0, pos.row - 1, pos.col - 1)
        api.nvim_input_mouse("left", "release", "", 0, pos.row - 1, pos.col - 1)
        -- This mapped input follows the release in Neovim's input queue.
        api.nvim_input("<F12>")
        coroutine.yield()
      else
        mouse._getmousepos = function()
          return {winid = handle.winid, line = row, column = col, coladd = 0, screenrow = row, screencol = col}
        end
        perform("click", function()
          mouse._on_move()
          vim.api.nvim_win_set_cursor(handle.winid, {row, col - 1})
          vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
        end)
      end
      if verify and (#events ~= before + (expected and 1 or 0) or expected and events[#events] ~= expected) then
        issues[#issues + 1] = ("row %d col %d expected %s, got %s"):format(row, col, expected or "no link",
          events[before + 1] or "no link")
      end
    end
    local guide = assert(locate(lines, "GUIDE"))
    local tail = assert(locate(lines, "TAIL"))
    if not wide then wide = guide end
    if w == 18 then
      assert(guide[1] ~= wide[1] and guide[1] ~= tail[1], "fixture must move and split the link")
      assert(lines[wide[1]] and #lines[wide[1]] >= wide[2], "old link cell must remain visible")
      click(wide, nil)
    end
    click(guide, "guide")
    click(tail, "guide")
    click(assert(locate(lines, "INDEX")), "index")
    click(assert(locate(lines, "plain")), nil)
    observe("click visible links at width " .. w, issues)
  end
end
local function cycle()
  events = {}
  if case == "edits" then run_edits()
  elseif case == "stream" then run_stream()
  elseif case == "links" then run_links()
  else
    for _, w in ipairs({48, 18, 36, 26, 62, 72}) do reflow(w, "resize to " .. w) end
  end
end
if pointer_test then
  assert(case == "links")
  vim.o.mouse = "a"
  vim.o.mousetime = 1
  local receipt = assert(vim.env.BENCH_POINTER_RECEIPT)
  local test = coroutine.create(run_links)
  local function advance()
    local ok, err = coroutine.resume(test)
    if not ok then
      vim.fn.writefile({tostring(err)}, receipt)
      vim.cmd("cquit 2")
    elseif coroutine.status(test) == "dead" then
      vim.fn.writefile({vim.json.encode(result)}, receipt)
      cleanup()
      vim.cmd("qa!")
    end
  end
  vim.keymap.set("n", "<F12>", function() vim.schedule(advance) end, {buffer = handle.bufnr})
  vim.schedule(advance)
  return
end
if verify then
  cycle()
else
  cycle()
  collectgarbage("collect")
  recording = true
  for _ = 1, 4 do cycle() end
end
mouse._getmousepos = initial_pointer
finish()
