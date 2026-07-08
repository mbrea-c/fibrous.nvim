-- Keyed reconciliation (React semantics). At each level, children carrying a
-- `key` are matched to the previous render's fibers BY KEY — so an entry keeps
-- its fiber (and hook state) when it moves, rather than being reused by index
-- for whatever now sits at its slot. Children WITHOUT a key fall back to
-- positional (index) matching, exactly as before. State/identity is observed
-- through the inline host: each Item renders its own use_state value as text.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function text(h)
  return table.concat(vim.api.nvim_buf_get_lines(h.bufnr, 0, -1, false), "\n")
end

-- one stateful component per row; captures its setter under a logical name
local function make_item(setters)
  return function(ctx, props)
    local n = ctx.use_state(0)
    setters[props.name] = n
    return { comp = ui.label, props = { text = props.name .. "=" .. n.get() } }
  end
end

describe("inline keyed reconciliation", function()
  it("state follows the KEY across an insert-above, not the position", function()
    local setters = {}
    local Item = make_item(setters)
    local function App(_, props)
      local kids = {}
      for _, name in ipairs(props.names) do
        kids[#kids + 1] = { comp = Item, key = name, props = { name = name } }
      end
      return { comp = ui.col, props = {}, children = kids }
    end

    local h = mount.floating(App, { names = { "a", "b", "c" } }, { width = 16, height = 8 })
    setters.b.set(9) -- b's private state = 9
    assert.truthy(text(h):find("b=9", 1, true))

    h.set_props({ names = { "x", "a", "b", "c" } }) -- shove one in at the front

    -- b was matched by key → same fiber → its state rode along
    assert.truthy(text(h):find("b=9", 1, true), "state did not follow the key across the insert")
    assert.truthy(text(h):find("a=0", 1, true), "a must keep its own (zero) state")
    assert.truthy(text(h):find("x=0", 1, true))
    h.unmount()
  end)

  it("reorders the rendered rows when keys are reordered", function()
    local setters = {}
    local Item = make_item(setters)
    local function App(_, props)
      local kids = {}
      for _, name in ipairs(props.names) do
        kids[#kids + 1] = { comp = Item, key = name, props = { name = name } }
      end
      return { comp = ui.col, props = {}, children = kids }
    end

    local h = mount.floating(App, { names = { "a", "b", "c" } }, { width = 16, height = 8 })
    setters.a.set(1)
    setters.c.set(3)
    h.set_props({ names = { "c", "b", "a" } }) -- reverse

    local lines = vim.api.nvim_buf_get_lines(h.bufnr, 0, -1, false)
    -- rows now read c, b, a — each with its OWN state (c=3, a=1), proving the
    -- fibers moved rather than the props being smeared across fixed slots
    assert.truthy(lines[1]:find("c=3", 1, true), "row 1 should be c with its state")
    assert.truthy(lines[3]:find("a=1", 1, true), "row 3 should be a with its state")
    h.unmount()
  end)

  it("keyless children still match positionally (index fallback)", function()
    local setters = {}
    local Item = make_item(setters)
    local function App(_, props)
      local kids = {}
      for _, name in ipairs(props.names) do
        kids[#kids + 1] = { comp = Item, props = { name = name } } -- NO key
      end
      return { comp = ui.col, props = {}, children = kids }
    end

    local h = mount.floating(App, { names = { "a", "b", "c" } }, { width = 16, height = 8 })
    setters.b.set(9) -- the fiber at index 2 holds state 9
    h.set_props({ names = { "x", "a", "b", "c" } }) -- prepend

    -- keyless = index match: index 2's fiber (state 9) now renders "a"
    assert.truthy(text(h):find("a=9", 1, true), "keyless must stay positional (state tied to the slot)")
    h.unmount()
  end)

  it("runs the effect cleanup of a removed key exactly once", function()
    local cleaned = {}
    local function Item(ctx, props)
      ctx.use_effect(function()
        return function()
          cleaned[#cleaned + 1] = props.name
        end
      end, {})
      return { comp = ui.label, props = { text = props.name } }
    end
    local function App(_, props)
      local kids = {}
      for _, name in ipairs(props.names) do
        kids[#kids + 1] = { comp = Item, key = name, props = { name = name } }
      end
      return { comp = ui.col, props = {}, children = kids }
    end

    local h = mount.floating(App, { names = { "a", "b", "c" } }, { width = 16, height = 8 })
    h.set_props({ names = { "a", "c" } }) -- drop b (from the MIDDLE)

    assert.same({ "b" }, cleaned, "only the removed key's cleanup should run")
    assert.truthy(text(h):find("a", 1, true))
    assert.truthy(text(h):find("c", 1, true))
    h.unmount()
  end)
end)
