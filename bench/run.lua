-- Benchmarks for the inline host (tracker "NEW UI HOST" task 8). Invoked as:
--   make bench      (nvim --headless -u NONE -i NONE -l bench/run.lua)
--
-- Perf posture (tracker decision): every commit is a full measure + repaint of
-- the whole tree, and these numbers are the gate for whether that stays
-- acceptable or damage-tracking gets pulled out of the back pocket. Scenarios:
--   * pure layout+paint      the engine alone, no buffer writes
--   * mount                  create_root + first commit + teardown
--   * full re-commit         set_props → every component re-renders + reflush
--   * incremental update     one leaf's use_state set() → scoped re-render,
--                            full reflush (the common interactive path)
--   * scroll tick            WinScrolled → subwin manager resync only
--
-- N counts SECTIONS; each section is col{ label, row{ button, checkbox },
-- paragraph }, i.e. ~6 nodes — so N=100 is a ~600-node tree.

local root_dir = vim.fn.getcwd()
package.path = table.concat({
  root_dir .. "/lua/?.lua",
  root_dir .. "/lua/?/init.lua",
  package.path,
}, ";")

local uv = vim.uv or vim.loop

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function bench(name, iters, fn)
  fn(0) -- warmup (JIT + caches)
  collectgarbage("collect")
  local t0 = uv.hrtime()
  for i = 1, iters do
    fn(i)
  end
  local per_op = (uv.hrtime() - t0) / iters / 1e6
  io.write(("%-52s %10.3f ms/op   (%d iters)\n"):format(name, per_op, iters))
end

---------------------------------------------------------------------------
-- Scenario trees
---------------------------------------------------------------------------

local LOREM = "the quick brown fox jumps over the lazy dog and packs boxes"

local function section(i)
  return {
    comp = ui.col,
    props = { border = "single", padding = { x = 1 } },
    children = {
      { comp = ui.label, props = { text = "Section " .. i, hl = "Title" } },
      {
        comp = ui.row,
        props = { gap = 2 },
        children = {
          { comp = ui.button, props = { label = "Run " .. i, on_press = function() end } },
          { comp = ui.checkbox, props = { label = "opt " .. i, checked = i % 2 == 0 } },
        },
      },
      { comp = ui.paragraph, props = { text = LOREM } },
    },
  }
end

-- App of `n` sections; `leaf_setter` (optional table) receives the use_state
-- setter of one extra leaf for the incremental-update scenario.
local function app_of(n, leaf_setter)
  return function(ctx, props)
    local _ = props and props.tick -- set_props forces the full re-render path
    local children = {}
    for i = 1, n do
      children[i] = section(i)
    end
    if leaf_setter then
      local s = ctx.use_state(0)
      leaf_setter.set = s.set
      children[#children + 1] = { comp = ui.label, props = { text = "count " .. s.get() } }
    end
    return { comp = ui.col, props = { gap = 1 }, children = children }
  end
end

local function fixed_host(w, h)
  return inline_host.new({
    get_size = function()
      return { width = w, height = h }
    end,
  })
end

---------------------------------------------------------------------------
-- Pure engine: layout + paint, no reconciler, no buffers
---------------------------------------------------------------------------

local function pure_tree(n)
  local children = {}
  for i = 1, n do
    children[i] = {
      kind = "col",
      props = { border = "single", padding = { x = 1 } },
      children = {
        { kind = "text", props = { text_hl = "Title" }, text = "Section " .. i },
        { kind = "text", props = { wrap = true }, text = LOREM },
      },
    }
  end
  return { kind = "col", props = { gap = 1 }, children = children }
end

local N = tonumber(vim.env.BENCH_N) or 100
io.write(("inline host benchmarks — N = %d sections (~%d nodes)\n\n"):format(N, N * 6))

bench("pure layout+paint (scroll mode)", 50, function()
  local tree = pure_tree(N)
  layout.compute(tree, { width = 60 })
  render.paint(tree, 60, tree.size.h)
end)

---------------------------------------------------------------------------
-- Reconciler + host: mount / full re-commit / incremental update
---------------------------------------------------------------------------

bench("mount (create_root + first commit + teardown)", 20, function()
  local host = fixed_host(60)
  local root = runtime.create_root(app_of(N), {}, { host = host })
  root:render()
  root:unmount()
end)

do
  local host = fixed_host(60)
  local root = runtime.create_root(app_of(N), { tick = 0 }, { host = host })
  root:render()
  bench("full re-commit (set_props, every component)", 50, function(i)
    root:set_props({ tick = i })
  end)
  root:unmount()
end

do
  local host = fixed_host(60)
  local setter = {}
  local root = runtime.create_root(app_of(N, setter), {}, { host = host })
  root:render()
  bench("incremental update (one leaf use_state)", 50, function(i)
    setter.set(i)
  end)
  root:unmount()
end

---------------------------------------------------------------------------
-- Scroll tick: WinScrolled → subwin resync only (no re-layout)
---------------------------------------------------------------------------

do
  local function App()
    local children = {}
    for i = 1, N do
      children[#children + 1] = { comp = ui.label, props = { text = "row " .. i } }
      if i % (math.floor(N / 4) + 1) == 0 then
        children[#children + 1] = { comp = ui.text_input, props = { border = "single" } }
      end
    end
    return { comp = ui.col, props = {}, children = children }
  end
  local handle = mount.floating(App, {}, { width = 40, height = 20, mode = "scroll" })
  local max_top = vim.api.nvim_buf_line_count(handle.bufnr) - 20
  bench("scroll tick (subwin resync via WinScrolled)", 200, function(i)
    local topline = (i * 7) % max_top + 1
    vim.api.nvim_win_call(handle.winid, function()
      vim.fn.winrestview({ topline = topline, lnum = topline })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
  end)
  handle.unmount()
end

io.write("\ndone\n")
