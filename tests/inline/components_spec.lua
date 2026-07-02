-- The inline component primitives (tracker "NEW UI HOST" task 5): thin
-- function components over the `text` host leaf, so the reconciler and host
-- stay unchanged. Public prop surface: `hl` is the FOREGROUND (mapped to the
-- node's text_hl), `bg` the background fill (mapped to the node's hl); box and
-- layout props pass straight through. Interactive components forward their
-- handlers and a `role` onto the node props — that is what the task-6 hit-map
-- reads off the laid-out tree.
--
--   label     nowrap text
--   paragraph wrapped text
--   button    "[ label ]", role = "button", on_press
--   checkbox  "[x]/[ ] label", role = "checkbox", checked + on_toggle

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local ui = require("fibrous.inline.components")

local function host_of(w, h)
  return inline_host.new({
    get_size = function()
      return { width = w, height = h }
    end,
  })
end

local function lines_of(host)
  return vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false)
end

describe("inline.components", function()
  it("re-exports the host primitives", function()
    assert.equal("col", ui.col.__host)
    assert.equal("row", ui.row.__host)
    assert.equal("text", ui.text.__host)
    assert.equal("text_input", ui.text_input.__host)
  end)

  it("label renders its text without wrapping; hl is the foreground", function()
    local function App()
      return { comp = ui.label, props = { text = "Name:", hl = "Title" } }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "Name:   " }, lines_of(host))
    local mark = vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })[1]
    assert.equal("Title", mark[4].hl_group)
    -- no background fill: the span covers only the text
    assert.equal(5, mark[4].end_col)
    root:unmount()
  end)

  it("label bg fills the whole rect as background", function()
    local function App()
      return { comp = ui.label, props = { text = "hi", bg = "Visual" } }
    end
    local host = host_of(6)
    local root = runtime.create_root(App, {}, { host = host }):render()

    local mark = vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })[1]
    assert.equal("Visual", mark[4].hl_group)
    assert.equal(6, mark[4].end_col)
    root:unmount()
  end)

  it("paragraph wraps to the available width", function()
    local function App()
      return { comp = ui.paragraph, props = { text = "the quick brown" } }
    end
    local host = host_of(6)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "the   ", "quick ", "brown " }, lines_of(host))
    root:unmount()
  end)

  it("button renders [ label ] and forwards its handler and role to the node", function()
    local pressed = function() end
    local function App()
      return { comp = ui.button, props = { label = "OK", on_press = pressed } }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "[ OK ]  " }, lines_of(host))
    assert.equal("button", host.tree.props.role)
    assert.rawequal(pressed, host.tree.props.on_press)
    root:unmount()
  end)

  it("checkbox reflects its checked state and re-renders on change", function()
    local setter
    local function App(ctx)
      local checked = ctx.use_state(false)
      setter = checked
      return {
        comp = ui.checkbox,
        props = {
          label = "Opt",
          checked = checked.get(),
          on_toggle = function(v)
            checked.set(v)
          end,
        },
      }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "[ ] Opt " }, lines_of(host))
    assert.equal("checkbox", host.tree.props.role)
    assert.is_false(host.tree.props.checked)

    setter.set(true)
    assert.same({ "[x] Opt " }, lines_of(host))
    assert.is_true(host.tree.props.checked)

    -- the forwarded handler is the activation path the hit-map will call
    host.tree.props.on_toggle(false)
    assert.same({ "[ ] Opt " }, lines_of(host))
    root:unmount()
  end)

  it("button and checkbox shrink-wrap in a stretch container (hover hugs the widget)", function()
    local function App()
      return {
        comp = ui.col, -- default align = stretch
        props = {},
        children = {
          { comp = ui.button, props = { label = "OK" } },
          { comp = ui.checkbox, props = { label = "Opt" } },
        },
      }
    end
    local host = host_of(12)
    local root = runtime.create_root(App, {}, { host = host }):render()

    -- the rect (what hover paints) covers only the widget's own cells
    assert.same({ x = 0, y = 0, w = 6, h = 1 }, host.tree.children[1].rect)
    assert.same({ x = 0, y = 1, w = 7, h = 1 }, host.tree.children[2].rect)
    root:unmount()
  end)

  it("align_self = stretch makes a button full-width again", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.button, props = { label = "OK", align_self = "stretch" } },
        },
      }
    end
    local host = host_of(12)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ x = 0, y = 0, w = 12, h = 1 }, host.tree.children[1].rect)
    root:unmount()
  end)

  it("box props pass through to the underlying node", function()
    local function App()
      return { comp = ui.button, props = { label = "OK", border = true } }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({
      "┌──────┐",
      "│[ OK ]│",
      "└──────┘",
    }, lines_of(host))
    root:unmount()
  end)
end)
