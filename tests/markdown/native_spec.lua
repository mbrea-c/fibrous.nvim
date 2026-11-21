local fibrous = require("fibrous")
local Host = require("fibrous.inline.host")
local runtime = require("fibrous.reactive.runtime")
local ui = require("fibrous.inline.components")

describe("opt-in native Markdown", function()
  after_each(function()
    fibrous.setup({ native_markdown = false })
  end)

  it("defaults to Lua and never loads the optional adapter", function()
    fibrous.setup({ native_markdown = false })
    local previous = package.loaded["fibrous.markdown.native"]
    local calls = 0
    package.loaded["fibrous.markdown.native"] = {
      install = function()
        calls = calls + 1
      end,
    }
    local host = Host.new({
      get_size = function()
        return { width = 40 }
      end,
    })
    host.teardown()
    package.loaded["fibrous.markdown.native"] = previous
    assert.equal(0, calls)
  end)

  it("requires explicit opt-in, with a per-host opt-out", function()
    local previous = package.loaded["fibrous.markdown.native"]
    local calls = 0
    package.loaded["fibrous.markdown.native"] = {
      install = function()
        calls = calls + 1
      end,
    }
    fibrous.setup({ native_markdown = true })
    local host = Host.new({
      get_size = function()
        return { width = 40 }
      end,
    })
    host.teardown()
    local lua_host = Host.new({
      native_markdown = false,
      get_size = function()
        return { width = 40 }
      end,
    })
    lua_host.teardown()
    package.loaded["fibrous.markdown.native"] = previous
    assert.equal(1, calls)
  end)

  it("keeps the fit-content layout in charge when native Markdown is enabled", function()
    fibrous.setup({ native_markdown = true })
    local size, fitted = { width = 40 }, nil
    local host = Host.new({
      get_size = function() return size end,
      on_fit_width = function(width) fitted = width end,
    })
    local root = runtime.create_root(ui.markdown, { text = "hello" }, { host = host })
    root:render()
    size.width = 3
    host.relayout()
    local backend, reason = host.markdown_backend, host.markdown_fallback
    root:unmount()
    assert.equal(3, fitted)
    assert.equal("lua", backend)
    assert.equal("content-fitted width", reason)
  end)

  it("rejects invalid configuration without changing the previous setting", function()
    fibrous.setup({ native_markdown = false })
    assert.has_error(function()
      fibrous.setup({ native_markdown = "yes" })
    end)
    assert.equal(false, require("fibrous.config").native_markdown)
  end)

  it("releases a declined document when an unmounted handle is retained", function()
    fibrous.setup({ native_markdown = true })
    local loader = package.loadlib
    package.loadlib = function()
      return nil, "test missing module"
    end
    local native = require("fibrous.markdown.native")
    native._reset_loader()
    local host = Host.new({
      get_size = function()
        return { width = 40 }
      end,
    })
    local root = runtime.create_root(ui.markdown, { text = "released document" }, { host = host })
    root:render()
    local weak = setmetatable({ host.tree }, { __mode = "v" })
    root:unmount()
    root = nil
    collectgarbage("collect")
    collectgarbage("collect")
    package.loadlib = loader
    native._reset_loader()
    assert.is_nil(host.tree)
    assert.is_nil(weak[1])
  end)

  it("does not enter a module with an incompatible ABI", function()
    fibrous.setup({ native_markdown = true })
    local loader, called = package.loadlib, false
    package.loadlib = function()
      return function()
        return {
          abi_version = 999,
          compile = function()
            called = true
            error("incompatible ABI")
          end,
        }
      end
    end
    local native = require("fibrous.markdown.native")
    native._reset_loader()
    local host = Host.new({
      get_size = function()
        return { width = 40 }
      end,
    })
    local root = runtime.create_root(ui.markdown, { text = "hello" }, { host = host })
    root:render()
    root:unmount()
    package.loadlib = loader
    native._reset_loader()
    assert.is_false(called)
  end)

  it("falls back to Lua if the native module is unavailable", function()
    fibrous.setup({ native_markdown = true })
    local loader = package.loadlib
    package.loadlib = function()
      return nil, "test module unavailable"
    end
    local native = require("fibrous.markdown.native")
    native._reset_loader()
    local size = { width = 40 }
    local host = Host.new({
      get_size = function()
        return size
      end,
    })
    local root = runtime.create_root(ui.markdown, { text = "hello **world**" }, { host = host })
    root:render()
    size.width = 20
    host.relayout()
    assert.equal("hello world", vim.trim(host.canvas_lines[1]))
    assert.equal("lua", host.markdown_backend)
    root:unmount()
    package.loadlib = loader
    native._reset_loader()
  end)
end)
