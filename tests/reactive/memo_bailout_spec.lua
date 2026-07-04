-- The reconciler's render bailout (VNode `memo = true`): when a parent
-- re-renders, a child spec carrying the flag whose component is unchanged and
-- whose props are SHALLOW-EQUAL to the fiber's current props is reused
-- without re-rendering — the whole subtree is skipped and, crucially, its
-- dirtiness ticks stay untouched, so the inline host's subtree memoization
-- (fiber._node) holds right through the parent's re-render. React.memo
-- semantics, opted into per call site; the flag only ever SKIPS work, it can
-- never change what an up-to-date render would show (a bailed fiber's props
-- are equal by definition, and its own state updates re-render it directly).

local runtime = require("fibrous.reactive.runtime")

describe("memo bailout (VNode memo = true)", function()
  -- A parent whose re-renders we control, wrapping one child spec built by
  -- `child_spec(render_no)`. Returns the parent's rerender fn.
  local function mount_with(child_spec)
    local rerender
    local function Parent(ctx)
      local s = ctx.use_state(0)
      rerender = function()
        s.set(s.get() + 1)
      end
      return child_spec(s.get())
    end
    local root = runtime.create_root(Parent, {}):render()
    return rerender, root
  end

  it("skips re-rendering a memo child when its props are shallow-equal", function()
    local renders, effects = 0, 0
    local function Child(ctx)
      renders = renders + 1
      ctx.use_effect(function()
        effects = effects + 1
      end)
      return nil
    end
    local props = { label = "hi" }
    local rerender = mount_with(function()
      -- a FRESH props table each render, shallow-equal to the last one — the
      -- shape a list component naturally produces
      return { comp = Child, props = { label = props.label }, memo = true }
    end)
    assert.equal(1, renders)

    rerender()
    rerender()

    assert.equal(1, renders, "shallow-equal props must bail out of the render")
    assert.equal(1, effects, "a bailed render must not re-queue effects")
  end)

  it("re-renders a memo child when a prop value changes", function()
    local renders, seen = 0, nil
    local function Child(_, props)
      renders = renders + 1
      seen = props.x
      return nil
    end
    local rerender = mount_with(function(n)
      return { comp = Child, props = { x = n < 2 and "a" or "b" }, memo = true }
    end)
    rerender() -- n=1: x stays "a" → bail
    assert.equal(1, renders)

    rerender() -- n=2: x flips to "b"
    assert.equal(2, renders)
    assert.equal("b", seen)
  end)

  it("re-renders a memo child when a prop disappears", function()
    local renders = 0
    local function Child()
      renders = renders + 1
      return nil
    end
    local rerender = mount_with(function(n)
      local props = n < 1 and { x = 1, extra = true } or { x = 1 }
      return { comp = Child, props = props, memo = true }
    end)
    assert.equal(1, renders)

    rerender() -- `extra` was removed: not shallow-equal, must re-render

    assert.equal(2, renders)
  end)

  it("still re-renders a non-memo child on every parent render", function()
    local renders = 0
    local function Child()
      renders = renders + 1
      return nil
    end
    local rerender = mount_with(function()
      return { comp = Child, props = { label = "hi" } }
    end)
    rerender()

    assert.equal(2, renders, "without the flag the default cascade is unchanged")
  end)

  it("a memo child's own state update still re-renders it", function()
    local renders, child_state = 0, nil
    local function Child(ctx)
      renders = renders + 1
      child_state = ctx.use_state("init")
      return nil
    end
    local rerender = mount_with(function()
      return { comp = Child, props = { fixed = true }, memo = true }
    end)
    assert.equal(1, renders)

    child_state.set("changed")
    assert.equal(2, renders, "state updates target the fiber directly, past the bailout")

    -- and a later parent re-render still bails without reverting that state
    rerender()
    assert.equal(2, renders)
    assert.equal("changed", child_state.get())
  end)

  it("skips the bailed child's whole subtree (grandchildren included)", function()
    local grandchild_renders = 0
    local function Grandchild()
      grandchild_renders = grandchild_renders + 1
      return nil
    end
    local function Child()
      return { comp = Grandchild, props = {} }
    end
    local rerender = mount_with(function()
      return { comp = Child, props = { fixed = 1 }, memo = true }
    end)
    rerender()

    assert.equal(1, grandchild_renders)
  end)

  it("keeps the bailed fiber's dirtiness ticks (host subtree-memo contract)", function()
    local function Child()
      return nil
    end
    local rerender, root = mount_with(function()
      return { comp = Child, props = { fixed = 1 }, memo = true }
    end)
    local child_fiber = root._fiber.child_fibers[1]
    local self_tick, tree_tick = child_fiber.self_tick, child_fiber.tree_tick

    rerender()

    assert.equal(self_tick, child_fiber.self_tick, "a bailed fiber must not be stamped")
    assert.equal(tree_tick, child_fiber.tree_tick, "its subtree did not change")
  end)

  it("does not defeat type switching", function()
    local mounted_b = false
    local function A()
      return nil
    end
    local function B()
      mounted_b = true
      return nil
    end
    local rerender = mount_with(function(n)
      return { comp = n < 1 and A or B, props = { fixed = 1 }, memo = true }
    end)
    rerender()

    assert.is_true(mounted_b, "a different comp must swap fibers, memo or not")
  end)

  it("is ignored on host primitives (their children live outside props)", function()
    -- Bailing a host fiber on props alone would skip reconciling its
    -- children_specs — which are fresh tables every render — and freeze the
    -- subtree. Guard that a memo'd host col still reconciles its children.
    local col = { __host = "col" }
    local renders = 0
    local function Leaf()
      renders = renders + 1
      return nil
    end
    local props = {}
    local rerender = mount_with(function()
      return { comp = col, props = props, memo = true, children = { { comp = Leaf, props = {} } } }
    end)
    rerender()

    assert.equal(2, renders, "host children must keep reconciling")
  end)
end)
