local runtime = require("fibrous.reactive.runtime")

describe("use_effect", function()
  it("runs the effect once on mount", function()
    local runs = 0
    local function App(ctx)
      ctx.use_effect(function()
        runs = runs + 1
      end, {})
      return nil
    end

    runtime.create_root(App, {}):render()

    assert.equal(1, runs)
  end)

  it("does not re-run on re-render when deps are unchanged", function()
    local runs = 0
    local handle
    local function App(ctx)
      local s = ctx.use_state(0)
      handle = s
      ctx.use_effect(function()
        runs = runs + 1
      end, { "stable" })
      return nil
    end

    runtime.create_root(App, {}):render()
    handle.set(1) -- forces a re-render, but the effect deps are unchanged

    assert.equal(1, runs)
  end)

  it("re-runs when a dep changes, calling the previous cleanup first", function()
    local events = {}
    local handle
    local function App(ctx)
      local n = ctx.use_state(0)
      handle = n
      -- Capture the value in a local so the cleanup closes over *this* render's
      -- value (`.get()` is a live read, so reading it inside cleanup would see
      -- the latest value instead).
      local v = n.get()
      ctx.use_effect(function()
        table.insert(events, "run:" .. v)
        return function()
          table.insert(events, "cleanup:" .. v)
        end
      end, { v })
      return nil
    end

    runtime.create_root(App, {}):render()
    handle.set(1)

    assert.same({ "run:0", "cleanup:0", "run:1" }, events)
  end)

  it("re-runs on every render when no dependency array is given", function()
    local runs = 0
    local handle
    local function App(ctx)
      local s = ctx.use_state(0)
      handle = s
      ctx.use_effect(function()
        runs = runs + 1
      end) -- no deps
      return nil
    end

    runtime.create_root(App, {}):render()
    handle.set(1)
    handle.set(2)

    assert.equal(3, runs)
  end)

  it("runs cleanup on unmount", function()
    local events = {}
    local function App(ctx)
      ctx.use_effect(function()
        table.insert(events, "run")
        return function()
          table.insert(events, "cleanup")
        end
      end, {})
      return nil
    end

    local root = runtime.create_root(App, {}):render()
    root:unmount()

    assert.same({ "run", "cleanup" }, events)
  end)
end)
