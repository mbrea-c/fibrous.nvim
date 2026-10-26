-- Benchmark-only timers must not change rendering or double-count nested work.
local function module()
  return dofile("bench/phase_profile.lua")
end

local function clock()
  local now = 0
  return function() return now end, function(ms) now = now + ms * 1e6 end
end

describe("benchmark phase accounting", function()
  it("subtracts child time and preserves arguments and nil return values", function()
    local read, spend = clock()
    local p = module().new({ clock = read })
    local functions = {
      child = function(a, b) spend(3); return a, nil, b end,
    }
    functions.parent = function()
      spend(2)
      local a, empty, b = functions.child("first", "last")
      spend(1)
      return a, empty, b
    end
    local parent, child = functions.parent, functions.child
    p:wrap(functions, "parent", "layout")
    p:wrap(functions, "child", "paint")
    local report, a, empty, b = p:measure(function()
      spend(4)
      return functions.parent()
    end)
    assert.equal(10, report.total_ms)
    assert.equal(3, report.phases_ms.layout)
    assert.equal(3, report.phases_ms.paint)
    assert.equal(4, report.phases_ms.other)
    assert.equal(1, report.calls.layout)
    assert.equal("first", a)
    assert.is_nil(empty)
    assert.equal("last", b)
    assert.equal(parent, functions.parent)
    assert.equal(child, functions.child)
  end)

  it("counts same-phase and recursive calls without counting elapsed time twice", function()
    local read, spend = clock()
    local p = module().new({ clock = read })
    local functions = {}
    functions.recurse = function(n)
      spend(1)
      if n > 0 then functions.recurse(n - 1) end
    end
    p:wrap(functions, "recurse", "paint")
    local report = p:measure(function() functions.recurse(3) end)
    assert.equal(4, report.total_ms)
    assert.equal(4, report.phases_ms.paint)
    assert.equal(4, report.calls.paint)
    assert.equal(0, report.phases_ms.other)
  end)

  it("restores functions and the measurement state after an error", function()
    local read, spend = clock()
    local p = module().new({ clock = read })
    local marker = {}
    local functions = { work = function() spend(2); error(marker) end }
    local original = functions.work
    p:wrap(functions, "work", "layout")
    local ok, err = pcall(function() p:measure(function() functions.work() end) end)
    assert.falsy(ok)
    assert.equal(marker, err)
    assert.equal(original, functions.work)
    local report = p:measure(function() spend(1) end)
    assert.equal(1, report.total_ms)
    assert.equal(0, report.calls.layout)
    assert.equal(1, report.phases_ms.other)
  end)

  it("unwinds a caught inner error before timing the next call", function()
    local read, spend = clock()
    local p = module().new({ clock = read })
    local functions = {
      bad = function() spend(2); error("expected") end,
      good = function() spend(3) end,
    }
    p:wrap(functions, "bad", "layout")
    p:wrap(functions, "good", "paint")
    local report = p:measure(function()
      pcall(functions.bad)
      functions.good()
      spend(1)
    end)
    assert.equal(6, report.total_ms)
    assert.equal(2, report.phases_ms.layout)
    assert.equal(3, report.phases_ms.paint)
    assert.equal(1, report.phases_ms.other)
  end)

  it("does not install timers outside a measurement and rejects duplicate hooks", function()
    local read, spend = clock()
    local p = module().new({ clock = read })
    local functions = { work = function() spend(2) end }
    local original = functions.work
    p:wrap(functions, "work", "layout")
    assert.equal(original, functions.work)
    functions.work()
    assert.has_error(function() p:wrap(functions, "work", "paint") end, "already")
    assert.equal(original, functions.work)
    local report = p:measure(function() functions.work() end)
    assert.equal(2, report.total_ms)
  end)

  it("validates all hooks before replacing any functions", function()
    local p = module().new()
    local functions = { first = function() end, second = function() end }
    local first = functions.first
    p:wrap(functions, "first", "layout")
    p:wrap(functions, "second", "paint")
    functions.second = nil
    assert.has_error(function() p:measure(function() end) end, "function")
    assert.equal(first, functions.first)
  end)

  it("rejects nested measurements and still restores the outer hooks", function()
    local p = module().new()
    local functions = { work = function() end }
    local original = functions.work
    p:wrap(functions, "work", "layout")
    assert.has_error(function()
      p:measure(function() p:measure(function() end) end)
    end, "already")
    assert.equal(original, functions.work)
  end)

  it("summarizes exclusive means and identifies the slowest frame without adding percentiles", function()
    local summary = module().summarize({
      { total_ms = 10, phases_ms = { layout = 8, other = 2 }, calls = { layout = 2 } },
      { total_ms = 20, phases_ms = { layout = 4, other = 16 }, calls = { layout = 1 } },
    })
    assert.equal(15, summary.mean_ms)
    assert.equal(10, summary.p50_ms)
    assert.equal(20, summary.p95_ms)
    assert.equal(6, summary.phases.layout.mean_ms)
    assert.equal(9, summary.phases.other.mean_ms)
    assert.equal(1.5, summary.phases.layout.calls_per_frame)
    assert.equal(2, summary.slowest.index)
    assert.equal(20, summary.slowest.total_ms)
    assert.equal(4, summary.slowest.phases_ms.layout)
    assert.equal(16, summary.slowest.phases_ms.other)
    assert.has_error(function() module().summarize({}) end, "empty")
  end)

  it("measures all buffer targets and leaves a bordered multi-column render unchanged", function()
    local fixture = dofile("bench/resize_fixture.lua")
    local runtime = require("fibrous.reactive.runtime")
    local Host = require("fibrous.inline.host")
    local size = { width = 100 }
    local host = Host.new({ get_size = function() return size end })
    local root = runtime.create_root(fixture.scene("mixed", 25), {}, { host = host })
    local p = module().standard()
    local set_lines = vim.api.nvim_buf_set_lines
    local set_mark = vim.api.nvim_buf_set_extmark
    local ok, err = pcall(function()
      root:render()
      size.width = 64
      host.relayout()
      local expected = fixture.fingerprint(host)
      size.width = 100
      host.relayout()
      size.width = 64
      local report = p:measure(host.relayout)
      assert.equal(expected, fixture.fingerprint(host))
      assert.is_true(report.calls.layout >= 2, "root and nested container must be included")
      for _, phase in ipairs({ "canvas_allocate", "paint", "text_extract", "highlight_extract",
        "buffer_text", "buffer_highlights", "sources" }) do
        assert.is_true(report.calls[phase] > 0, "missing phase: " .. phase)
        assert.is_true(report.phases_ms[phase] >= 0)
      end
      local sum = 0
      for _, ms in pairs(report.phases_ms) do sum = sum + ms end
      assert.is_true(math.abs(sum - report.total_ms) < 1e-6)
      assert.equal(set_lines, vim.api.nvim_buf_set_lines)
      assert.equal(set_mark, vim.api.nvim_buf_set_extmark)
    end)
    root:unmount()
    if not ok then error(err, 0) end
  end)
end)
