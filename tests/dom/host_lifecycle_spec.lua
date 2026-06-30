local runtime = require("fibrous.reactive.runtime")

-- A mock HostConfig: records the sequence of host operations the reconciler
-- drives, so we can assert lifecycle behavior without touching nui/Neovim.
local function mock_host()
  local events = {}
  local id = 0
  return {
    events = events,
    create_instance = function(tag, props)
      id = id + 1
      local instance = { tag = tag, id = id }
      table.insert(events, { "create", tag, props })
      return instance
    end,
    update_instance = function(instance, prev_props, next_props)
      table.insert(events, { "update", instance.tag, next_props })
    end,
    destroy_instance = function(instance)
      table.insert(events, { "destroy", instance.tag })
    end,
  }
end

local text = { __host = "text" }

describe("host lifecycle", function()
  it("creates an instance when a host primitive mounts", function()
    local function App()
      return { comp = text, props = { content = "hi" } }
    end
    local host = mock_host()

    runtime.create_root(App, {}, { host = host }):render()

    assert.same({ { "create", "text", { content = "hi" } } }, host.events)
  end)

  it("updates the instance (not recreate) when host props change", function()
    local setter
    local function App(ctx)
      local s = ctx.use_state("a")
      setter = s
      return { comp = text, props = { content = s.get() } }
    end
    local host = mock_host()

    runtime.create_root(App, {}, { host = host }):render()
    setter.set("b")

    assert.same({
      { "create", "text", { content = "a" } },
      { "update", "text", { content = "b" } },
    }, host.events)
  end)

  it("destroys the instance when the host is removed", function()
    local setter
    local function App(ctx)
      local show = ctx.use_state(true)
      setter = show
      if show.get() then
        return { comp = text, props = { content = "hi" } }
      end
      return nil
    end
    local host = mock_host()

    runtime.create_root(App, {}, { host = host }):render()
    setter.set(false)

    assert.same({
      { "create", "text", { content = "hi" } },
      { "destroy", "text" },
    }, host.events)
  end)

  it("destroys host instances on unmount", function()
    local function App()
      return { comp = text, props = { content = "hi" } }
    end
    local host = mock_host()

    local root = runtime.create_root(App, {}, { host = host }):render()
    root:unmount()

    assert.same({
      { "create", "text", { content = "hi" } },
      { "destroy", "text" },
    }, host.events)
  end)
end)
