local nr = require("fibrous")
local el = require("fibrous.components")
local use_keymap = require("fibrous.hooks.use_keymap")

local function find_map(bufnr, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if m.lhs == lhs then
      return m
    end
  end
end

describe("use_keymap (component-scoped)", function()
  it("binds on every leaf buffer in the calling component's subtree", function()
    local hits = 0
    local ref_a, ref_b
    local function App(ctx)
      ref_a = ref_a or ctx.use_ref()
      ref_b = ref_b or ctx.use_ref()
      use_keymap(ctx, { mode = "n", lhs = "x", rhs = function() hits = hits + 1 end })
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text, props = { focusable = true, ref = ref_a, lines = { "a" } } },
          {
            comp = el.row, -- a nested container, to prove the map reaches grandchildren
            props = {},
            children = {
              { comp = el.text, props = { focusable = true, ref = ref_b, lines = { "b" } } },
            },
          },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 24, height = 6 } })

    -- Bound on both the direct child AND the nested grandchild (bubbling-like).
    assert.is_not_nil(find_map(ref_a.current.bufnr, "n", "x"))
    local mb = find_map(ref_b.current.bufnr, "n", "x")
    assert.is_not_nil(mb)
    mb.callback()
    assert.equal(1, hits)

    handle.unmount()
  end)

  it("does not leak to leaves outside the declaring component's subtree", function()
    local ref_inner, ref_outer
    local function Inner(ctx)
      ref_inner = ref_inner or ctx.use_ref()
      use_keymap(ctx, { mode = "n", lhs = "z", rhs = function() end })
      return { comp = el.text, props = { focusable = true, ref = ref_inner, lines = { "in" } } }
    end
    local function App(ctx)
      ref_outer = ref_outer or ctx.use_ref()
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = Inner, props = {} },
          { comp = el.text, props = { focusable = true, ref = ref_outer, lines = { "out" } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 24, height = 6 } })

    assert.is_not_nil(find_map(ref_inner.current.bufnr, "n", "z"))
    assert.is_nil(find_map(ref_outer.current.bufnr, "n", "z"))

    handle.unmount()
  end)

  it("invokes the latest handler across re-renders (fresh closure)", function()
    local seen = {}
    local ref
    local actions = { current = {} }
    local function App(ctx)
      local n = ctx.use_state(0)
      ref = ref or ctx.use_ref()
      ctx.use_effect(function()
        actions.current.bump = function() n.set(n.get() + 1) end
      end, {})
      local count = n.get()
      use_keymap(ctx, { mode = "n", lhs = "p", rhs = function() seen[#seen + 1] = count end })
      return {
        comp = el.col,
        props = {},
        children = {
          { comp = el.text, props = { focusable = true, ref = ref, lines = { tostring(count) } } },
        },
      }
    end

    local handle = nr.mount(App, {}, { size = { width = 20, height = 4 } })

    find_map(ref.current.bufnr, "n", "p").callback() -- sees 0
    actions.current.bump() -- re-render → count = 1
    find_map(ref.current.bufnr, "n", "p").callback() -- must see 1, not stale 0

    assert.same({ 0, 1 }, seen)

    handle.unmount()
  end)
end)
