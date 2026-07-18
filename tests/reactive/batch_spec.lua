-- Sync-batched state rendering (design-set-batching.md). `runtime.batch(fn)`
-- opens a dispatch scope: inside it, `.set` writes the slot EAGERLY (reads
-- stay fresh) but only marks the fiber dirty; when the OUTERMOST batch exits,
-- the dirty set is deduped (fibers with a dirty ancestor collapse into the
-- ancestor's pass, unmounted fibers are dropped), each remaining subtree
-- renders once, and each affected root commits ONCE. Everything happens
-- before batch() returns, so callers still observe a flushed world; sets
-- outside any batch keep the old synchronous render-per-set behavior.

local runtime = require("fibrous.reactive.runtime")

-- A counting host bridge: pure reactive trees have no host instances, so only
-- `commit` matters here.
local function counting_host()
  local host = { commits = 0 }
  host.commit = function()
    host.commits = host.commits + 1
  end
  return host
end

describe("runtime.batch", function()
  it("returns the wrapped function's values (including nils)", function()
    local a, b, c = runtime.batch(function(x)
      return x, nil, "three"
    end, 1)
    assert.equal(1, a)
    assert.is_nil(b)
    assert.equal("three", c)
  end)

  it("set inside a batch updates get() immediately but defers the render", function()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}):render()

    runtime.batch(function()
      handle.set(7)
      assert.equal(7, handle.get()) -- eager slot write: reads are never stale
      assert.equal(1, renders) -- but no render happened yet
    end)

    assert.equal(2, renders) -- exactly one render at batch exit
    assert.equal(7, handle.get())
  end)

  it("N sets on one fiber cost one render and one commit", function()
    local host = counting_host()
    local a, b, c
    local renders = 0
    local function App(ctx)
      a = ctx.use_state(0)
      b = ctx.use_state(0)
      c = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}, { host = host }):render()
    assert.equal(1, host.commits)

    runtime.batch(function()
      a.set(1)
      b.set(2)
      c.set(3)
    end)

    assert.equal(2, renders, "three sets in one batch must render once")
    assert.equal(2, host.commits, "three sets in one batch must commit once")
    assert.same({ 1, 2, 3 }, { a.get(), b.get(), c.get() })
  end)

  it("sets on two sibling fibers render each subtree once and commit once", function()
    local renders = { root = 0, left = 0, right = 0 }
    local left_state, right_state
    local function Left(ctx)
      left_state = ctx.use_state("l")
      renders.left = renders.left + 1
      return nil
    end
    local function Right(ctx)
      right_state = ctx.use_state("r")
      renders.right = renders.right + 1
      return nil
    end
    -- Two function components as true siblings under a host primitive.
    local function App()
      renders.root = renders.root + 1
      return {
        comp = { __host = "row" },
        props = {},
        children = {
          { comp = Left, props = {} },
          { comp = Right, props = {} },
        },
      }
    end
    local host = counting_host()
    host.create_instance = function()
      return {}
    end
    host.update_instance = function() end
    host.destroy_instance = function() end
    runtime.create_root(App, {}, { host = host }):render()
    assert.equal(1, host.commits)
    assert.same({ 1, 1 }, { renders.left, renders.right })

    runtime.batch(function()
      left_state.set("L")
      right_state.set("R")
    end)

    assert.same({ 2, 2 }, { renders.left, renders.right })
    assert.equal(1, renders.root, "the clean parent must not re-render")
    assert.equal(2, host.commits, "two sibling subtree renders share one commit")
  end)

  it("a dirty child collapses into its dirty ancestor's pass", function()
    local host = counting_host()
    local renders = { parent = 0, child = 0 }
    local parent_state, child_state
    local function Child(ctx)
      child_state = ctx.use_state(0)
      renders.child = renders.child + 1
      return nil
    end
    local function Parent(ctx)
      parent_state = ctx.use_state(0)
      renders.parent = renders.parent + 1
      return { comp = Child, props = {} }
    end
    runtime.create_root(Parent, {}, { host = host }):render()

    runtime.batch(function()
      child_state.set(1)
      parent_state.set(1)
    end)

    assert.equal(2, renders.parent)
    assert.equal(2, renders.child, "child must render once via the parent's pass, not twice")
    assert.equal(2, host.commits)
    assert.equal(1, child_state.get())
  end)

  it("refs written AFTER a set are visible to the batch-exit render (the dropdown footgun)", function()
    local handle, ref
    local seen
    local function App(ctx)
      handle = ctx.use_state(0)
      ref = ctx.use_ref("initial")
      seen = ref.current
      return nil
    end
    runtime.create_root(App, {}):render()

    runtime.batch(function()
      handle.set(1) -- under the old synchronous schedule this rendered HERE,
      ref.current = "written-after-set" -- making this write invisible
    end)

    assert.equal("written-after-set", seen)
  end)

  it("a value-equal set inside a batch stays a no-op", function()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(3)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}):render()

    runtime.batch(function()
      handle.set(3)
    end)

    assert.equal(1, renders)
  end)

  it("set-then-set-back still renders once (dirty once marked stays marked)", function()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state("orig")
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}):render()

    runtime.batch(function()
      handle.set("changed")
      handle.set("orig")
    end)

    assert.equal(2, renders)
    assert.equal("orig", handle.get())
  end)

  it("nested batches flush only when the outermost exits", function()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}):render()

    runtime.batch(function()
      runtime.batch(function()
        handle.set(1)
      end)
      assert.equal(1, renders, "inner batch exit must not flush")
      handle.set(2)
    end)

    assert.equal(2, renders)
    assert.equal(2, handle.get())
  end)

  it("outside any batch, set renders synchronously exactly as before", function()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}):render()

    handle.set(1)
    assert.equal(2, renders)
    handle.set(2)
    assert.equal(3, renders)
  end)

  it("a set during the batch-exit render settles in a follow-up pass", function()
    local host = counting_host()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(0)
      renders = renders + 1
      if handle.get() == 1 then
        handle.set(2) -- render-time correction: must queue, not recurse
      end
      return nil
    end
    runtime.create_root(App, {}, { host = host }):render()

    runtime.batch(function()
      handle.set(1)
    end)

    assert.equal(2, handle.get())
    assert.equal(3, renders, "pass with 1, then the settling pass with 2")
    assert.equal(3, host.commits, "each settling pass commits (effects must see a mounted tree)")
  end)

  it("errors on livelock (sets that never settle) and recovers afterwards", function()
    local handle
    local function App(ctx)
      handle = ctx.use_state(0)
      if handle.get() > 0 then
        handle.set(handle.get() + 1) -- always a fresh value: never settles
      end
      return nil
    end
    runtime.create_root(App, {}):render()

    assert.has_error(function()
      runtime.batch(function()
        handle.set(1)
      end)
    end, "did not settle")

    -- The batch machinery must be reset: a later, well-behaved root works.
    local ok_handle
    local renders = 0
    local function Sane(ctx)
      ok_handle = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(Sane, {}):render()
    runtime.batch(function()
      ok_handle.set(5)
    end)
    assert.equal(2, renders)
    assert.equal(5, ok_handle.get())
  end)

  it("an error in the batched fn propagates, but queued sets still flush", function()
    local host = counting_host()
    local handle
    local renders = 0
    local function App(ctx)
      handle = ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}, { host = host }):render()

    assert.has_error(function()
      runtime.batch(function()
        handle.set(9)
        error("boom")
      end)
    end, "boom")

    -- The state write happened, so the world must still be brought up to date.
    assert.equal(9, handle.get())
    assert.equal(2, renders)
    assert.equal(2, host.commits)

    -- And the depth counter must be back at zero: the next set is synchronous.
    handle.set(10)
    assert.equal(3, renders)
  end)

  it("effects triggered by the flush apply their sets within the same batch call", function()
    local host = counting_host()
    local count, double
    local function App(ctx)
      count = ctx.use_state(0)
      double = ctx.use_state(0)
      local c = count.get()
      ctx.use_effect(function()
        double.set(c * 2)
      end, { c })
      return nil
    end
    runtime.create_root(App, {}, { host = host }):render()
    assert.equal(1, host.commits) -- the first effect set 0, a value-equal no-op

    runtime.batch(function()
      count.set(3)
    end)

    assert.equal(6, double.get(), "the effect's set must land before batch() returns")
    assert.equal(3, host.commits, "count pass + the effect's follow-up pass")
  end)

  it("dirtying two roots in one batch commits each root exactly once", function()
    local host_a, host_b = counting_host(), counting_host()
    local sa, sb
    local function A(ctx)
      sa = ctx.use_state(0)
      return nil
    end
    local function B(ctx)
      sb = ctx.use_state(0)
      return nil
    end
    runtime.create_root(A, {}, { host = host_a }):render()
    runtime.create_root(B, {}, { host = host_b }):render()

    runtime.batch(function()
      sa.set(1)
      sb.set(1)
      sa.set(2)
    end)

    assert.equal(2, host_a.commits)
    assert.equal(2, host_b.commits)
    assert.same({ 2, 1 }, { sa.get(), sb.get() })
  end)

  it("a batch with no sets performs no render and no commit", function()
    local host = counting_host()
    local renders = 0
    local function App(ctx)
      ctx.use_state(0)
      renders = renders + 1
      return nil
    end
    runtime.create_root(App, {}, { host = host }):render()

    runtime.batch(function() end)

    assert.equal(1, renders)
    assert.equal(1, host.commits)
  end)

  it("drops a set on a fiber unmounted earlier in the same flush", function()
    local host = counting_host()
    local show, child_state
    local child_renders = 0
    local function Child(ctx)
      child_state = ctx.use_state("alive")
      child_renders = child_renders + 1
      return nil
    end
    local function Parent(ctx)
      show = ctx.use_state(true)
      local visible = show.get()
      ctx.use_effect(function()
        if not visible and child_state then
          -- A stale handle poking a fiber that the pass above just removed.
          child_state.set("zombie")
        end
      end, { visible })
      return visible and { comp = Child, props = {} } or nil
    end
    runtime.create_root(Parent, {}, { host = host }):render()
    assert.equal(1, child_renders)

    assert.has_no_error(function()
      runtime.batch(function()
        show.set(false)
      end)
    end)

    assert.equal(1, child_renders, "an unmounted fiber must not be re-rendered")
  end)
end)
