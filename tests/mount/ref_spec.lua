local nr = require("fibrous")
local el = require("fibrous.components")

local function buf_with_line(text)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
        if line == text then
          return b
        end
      end
    end
  end
  return nil
end

describe("refs + effect timing", function()
  it("runs effects after commit, with a ref pointing at the live buffer", function()
    local seen_bufnr, seen_valid
    local function App(ctx)
      local ref = ctx.use_ref()
      ctx.use_effect(function()
        local handle = ref.current
        seen_bufnr = handle and handle.bufnr
        seen_valid = handle ~= nil and handle.bufnr ~= nil and vim.api.nvim_buf_is_valid(handle.bufnr)
        -- Imperatively own the buffer (the transcript pattern): write directly,
        -- bypassing the declarative `lines` prop.
        if handle and handle.bufnr then
          vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, { "from-effect" })
        end
      end, {})

      return {
        comp = el.col,
        props = {},
        children = {
          -- ref-managed leaf: no `lines`, owned by the effect above.
          { comp = el.text, props = { ref = ref } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 20, height = 4 } })

    assert.is_not_nil(seen_bufnr, "ref.current should be populated by commit time")
    assert.is_true(seen_valid, "the buffer should be mounted/valid when the effect runs")
    assert.is_not_nil(buf_with_line("from-effect"))

    handle.unmount()
  end)

  it("does not clobber a ref-managed buffer on re-render (no lines prop)", function()
    local setter, ref_handle
    local function App(ctx)
      local s = ctx.use_state(0)
      setter = s
      local ref = ctx.use_ref()
      ctx.use_effect(function()
        ref_handle = ref.current
        if ref.current and ref.current.bufnr then
          vim.api.nvim_buf_set_lines(ref.current.bufnr, 0, -1, false, { "owned" })
        end
      end, {})
      return {
        comp = el.col,
        -- a sibling whose content DOES change, forcing re-render/commit
        props = {},
        children = {
          { comp = el.text, props = { ref = ref } },
          { comp = el.text, props = { lines = { "count=" .. s.get() } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 20, height = 6 } })
    assert.is_not_nil(buf_with_line("owned"))

    setter.set(1) -- re-render + commit; must not wipe the ref-managed buffer

    assert.is_not_nil(buf_with_line("count=1"))
    assert.is_not_nil(buf_with_line("owned"), "ref-managed buffer must survive a commit")

    handle.unmount()
  end)
end)
