local runtime = require("nui-reactive.reactive.runtime")

describe("use_state", function()
  it("exposes the initial value through get()", function()
    local seen
    local function App(ctx)
      local count = ctx.use_state(5)
      seen = count.get()
      return nil
    end

    runtime.create_root(App, {}):render()

    assert.equal(5, seen)
  end)

  it("re-renders the owning component and reflects the new value after set()", function()
    local handle
    local renders = 0
    local function App(ctx)
      local count = ctx.use_state(0)
      handle = count
      renders = renders + 1
      return nil
    end

    runtime.create_root(App, {}):render()
    assert.equal(0, handle.get())
    assert.equal(1, renders)

    handle.set(7)

    assert.equal(7, handle.get())
    assert.equal(2, renders, "set() should trigger exactly one re-render")
  end)

  it("does not re-render when set() is called with the unchanged value", function()
    local handle
    local renders = 0
    local function App(ctx)
      local count = ctx.use_state(3)
      handle = count
      renders = renders + 1
      return nil
    end

    runtime.create_root(App, {}):render()
    handle.set(3)

    assert.equal(1, renders, "setting the same value should be a no-op")
  end)

  it("keeps independent storage for multiple use_state calls (positional slots)", function()
    local a_handle, b_handle
    local function App(ctx)
      local a = ctx.use_state("a")
      local b = ctx.use_state("b")
      a_handle, b_handle = a, b
      return nil
    end

    runtime.create_root(App, {}):render()
    a_handle.set("A")

    assert.equal("A", a_handle.get())
    assert.equal("b", b_handle.get(), "second slot must be unaffected by the first")
  end)

  it("supports false and nil initial values", function()
    local flag
    local function App(ctx)
      local f = ctx.use_state(false)
      flag = f
      return nil
    end

    runtime.create_root(App, {}):render()

    assert.is_false(flag.get())
  end)
end)
