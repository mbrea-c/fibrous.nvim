local function bench(file, env)
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", file },
    { cwd = vim.fn.getcwd(), env = vim.tbl_extend("force", { BENCH_JSON = "1", BENCH_N = "3" }, env or {}) }):wait(30000)
  assert.equal(0, result.code, (result.stdout or "") .. (result.stderr or ""))
  return vim.json.decode(result.stdout)
end

describe("resize phase benchmarks", function()
  it("compares unprofiled and profiled frames with identical draw output", function()
    local out = bench("bench/resize_profile.lua", { BENCH_PROFILE_ORDER = "profiled-first" })
    assert.equal("resize_profile", out.bench)
    assert.equal(4, #out.results)
    for _, result in ipairs(out.results) do
      assert.equal(24, result.frames)
      assert.equal(result.profile.mean_ms, result.value)
      assert.is_true(result.unprofiled.mean_ms >= 0)
      assert.is_true(math.abs(result.overhead_ms - (result.value - result.unprofiled.mean_ms)) < 1e-6)
      assert.equal(64, #result.fingerprint)
      local sum = 0
      for _, phase in pairs(result.profile.phases) do sum = sum + phase.mean_ms end
      assert.is_true(math.abs(sum - result.value) < 1e-6)
      assert.is_true(result.profile.slowest.total_ms >= result.profile.p95_ms)
      assert.is_true(result.profile.phases.layout.calls_per_frame > 0)
      assert.is_true(result.output_matches)
    end
  end)

  it("keeps optional real-TUI profiling separate from default output and draw cost", function()
    local plain = bench("bench/resize_term.lua", { BENCH_PROFILE = "0", BENCH_FRAMES = "2" })
    local profiled = bench("bench/resize_term.lua", { BENCH_PROFILE = "1", BENCH_FRAMES = "2" })
    assert.equal(3, #profiled.results)
    for i, result in ipairs(profiled.results) do
      assert.is_nil(plain.results[i].profile)
      assert.equal(plain.results[i].fingerprint, result.fingerprint)
      assert.equal(plain.results[i].bytes, result.bytes)
      assert.equal(2, result.frames)
      assert.is_true(result.profile.phases.redraw.calls_per_frame > 0)
      assert.is_true(result.profile.phases.layout.calls_per_frame > 0)
      local sum = 0
      for _, phase in pairs(result.profile.phases) do sum = sum + phase.mean_ms end
      assert.is_true(math.abs(sum - result.profile.mean_ms) < 1e-6)
    end
  end)
end)
