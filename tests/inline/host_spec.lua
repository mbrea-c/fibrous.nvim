-- The inline HostConfig (tracker "NEW UI HOST" task 3): the bridge the
-- reconciler drives. Rather than a window per leaf, the whole committed
-- fiber tree is laid out (layout.compute), painted (render.paint) and flushed
-- into ONE host-owned scratch buffer as full lines + extmark highlight spans.
-- The buffer is unmodifiable; a mount target shows it in the root float.
--
-- Sizing comes from an injected `get_size` (the mount target reads its window):
-- height = nil is scroll mode (buffer grows with content), a number is app mode
-- (fixed canvas). `relayout()` re-runs layout+paint at the current size without
-- re-rendering components — the resize-sync entry point.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")

local col = { __host = "col" }
local text = { __host = "text" }

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- All extmark highlight spans in the buffer, in a comparable shape.
local function marks_of(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
  end
  return out
end

describe("inline.host", function()
  it("commit paints the tree into the host buffer (scroll mode)", function()
    local function App()
      return {
        comp = col,
        props = {},
        children = {
          { comp = text, props = { text = "hi" } },
          { comp = text, props = { text = "there" } },
        },
      }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 6 }
      end,
    })

    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "hi    ", "there " }, lines_of(host.bufnr))
    assert.is_false(vim.bo[host.bufnr].modifiable)
    root:unmount()
  end)

  it("app mode paints the full fixed height; grow spacers take the leftover", function()
    local function App()
      return {
        comp = col,
        props = {},
        children = {
          { comp = text, props = { text = "top" } },
          { comp = col, props = { grow = 1 } },
          { comp = text, props = { text = "bot" } },
        },
      }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 4, height = 4 }
      end,
    })

    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "top ", "    ", "    ", "bot " }, lines_of(host.bufnr))
    root:unmount()
  end)

  it("highlight spans land as extmarks", function()
    local function App()
      return { comp = text, props = { text = "hi", text_hl = "Title" } }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 4 }
      end,
    })

    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ { row = 0, col = 0, end_col = 2, hl = "Title" } }, marks_of(host.bufnr))
    root:unmount()
  end)

  it("a state update rewrites lines and replaces (not accumulates) extmarks", function()
    local setter
    local function App(ctx)
      local s = ctx.use_state("aa")
      setter = s
      return { comp = text, props = { text = s.get(), text_hl = "Title" } }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 6 }
      end,
    })
    local root = runtime.create_root(App, {}, { host = host }):render()

    setter.set("bbbb")

    assert.same({ "bbbb  " }, lines_of(host.bufnr))
    assert.same({ { row = 0, col = 0, end_col = 4, hl = "Title" } }, marks_of(host.bufnr))
    root:unmount()
  end)

  it("relayout() recomputes at the current size without re-rendering components", function()
    local w = 10
    local renders = 0
    local function App()
      renders = renders + 1
      return { comp = text, props = { text = "the quick", wrap = true } }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = w }
      end,
    })
    local root = runtime.create_root(App, {}, { host = host }):render()
    assert.same({ "the quick " }, lines_of(host.bufnr))

    w = 5
    host.relayout()

    assert.same({ "the  ", "quick" }, lines_of(host.bufnr))
    assert.equal(1, renders)
    root:unmount()
  end)

  it("descends through function components to the host nodes they render", function()
    local function Label(_, props)
      return { comp = text, props = { text = props.caption } }
    end
    local function App()
      return {
        comp = col,
        props = {},
        children = {
          { comp = Label, props = { caption = "wrapped" } },
        },
      }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 8 }
      end,
    })

    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "wrapped " }, lines_of(host.bufnr))
    root:unmount()
  end)

  it("teardown deletes the host buffer", function()
    local function App()
      return { comp = text, props = { text = "bye" } }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 4 }
      end,
    })
    local root = runtime.create_root(App, {}, { host = host }):render()
    local bufnr = host.bufnr
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))

    root:unmount()

    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)

  it("rejects unknown host primitives", function()
    local bogus = { __host = "bogus" }
    local function App()
      return { comp = bogus, props = {} }
    end
    local host = inline_host.new({
      get_size = function()
        return { width = 4 }
      end,
    })

    assert.has_error(function()
      runtime.create_root(App, {}, { host = host }):render()
    end, "unknown host primitive")

    host.teardown()
  end)
end)
