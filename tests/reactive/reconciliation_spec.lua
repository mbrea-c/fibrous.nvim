local runtime = require("fibrous.reactive.runtime")

describe("reconciliation", function()
  it("renders nested function components from the returned element", function()
    local seen_label
    local function Child(_, props)
      seen_label = props.label
      return nil
    end
    local function Parent()
      return { comp = Child, props = { label = "hi" } }
    end

    runtime.create_root(Parent, {}):render()

    assert.equal("hi", seen_label)
  end)

  it("reuses a child fiber (and its hook state) across a parent re-render", function()
    local parent_state, child_state
    local child_renders = 0
    local function Child(ctx)
      local s = ctx.use_state("init")
      child_state = s
      child_renders = child_renders + 1
      return nil
    end
    local function Parent(ctx)
      local p = ctx.use_state(0)
      parent_state = p
      return { comp = Child, props = { x = p.get() } }
    end

    runtime.create_root(Parent, {}):render()
    assert.equal(1, child_renders)

    child_state.set("changed")
    assert.equal("changed", child_state.get())

    -- Re-render the parent; the child has the same `comp` at the same position,
    -- so its fiber — and thus its state — must be reused, not recreated.
    parent_state.set(1)

    assert.equal("changed", child_state.get(), "child state should survive parent re-render")
  end)

  it("unmounts the old child and mounts a new one when comp changes", function()
    local events = {}
    local function A(ctx)
      ctx.use_effect(function()
        return function()
          table.insert(events, "A:cleanup")
        end
      end, {})
      return nil
    end
    local function B(ctx)
      ctx.use_effect(function()
        table.insert(events, "B:mount")
      end, {})
      return nil
    end
    local toggle
    local function Parent(ctx)
      local s = ctx.use_state("A")
      toggle = s
      return { comp = s.get() == "A" and A or B, props = {} }
    end

    runtime.create_root(Parent, {}):render()
    toggle.set("B")

    assert.same({ "A:cleanup", "B:mount" }, events)
  end)

  it("unmounts a child (running cleanup) when it is conditionally removed", function()
    local cleaned = false
    local function Child(ctx)
      ctx.use_effect(function()
        return function()
          cleaned = true
        end
      end, {})
      return nil
    end
    local show
    local function Parent(ctx)
      local s = ctx.use_state(true)
      show = s
      if s.get() then
        return { comp = Child, props = {} }
      end
      return nil
    end

    runtime.create_root(Parent, {}):render()
    assert.is_false(cleaned)

    show.set(false)

    assert.is_true(cleaned)
  end)

  it("runs effects bottom-up: children before their parent", function()
    local order = {}
    local function Child(ctx)
      ctx.use_effect(function()
        table.insert(order, "child")
      end, {})
      return nil
    end
    local function Parent(ctx)
      ctx.use_effect(function()
        table.insert(order, "parent")
      end, {})
      return { comp = Child, props = {} }
    end

    runtime.create_root(Parent, {}):render()

    assert.same({ "child", "parent" }, order)
  end)
end)
