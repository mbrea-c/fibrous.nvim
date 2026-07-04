-- The inline component primitives (tracker "NEW UI HOST" task 5): thin
-- function components over the `text` host leaf, so the reconciler and host
-- stay unchanged. ALL styling lives in props.style (node vocabulary:
-- `text_hl` = foreground, `hl` = fill; the removed pre-style-table aliases
-- error loudly). Layout props pass straight through. Interactive components
-- forward their handlers and a `role` onto the node props — that is what the
-- task-6 hit-map reads off the laid-out tree.
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
    assert.equal("raw_buffer", ui.raw_buffer.__host)
  end)

  it("label renders its text without wrapping; style.text_hl is the foreground", function()
    local function App()
      return { comp = ui.label, props = { text = "Name:", style = { text_hl = "Title" } } }
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

  it("label style.hl fills the whole rect as background", function()
    local function App()
      return { comp = ui.label, props = { text = "hi", style = { hl = "Visual" } } }
    end
    local host = host_of(6)
    local root = runtime.create_root(App, {}, { host = host }):render()

    local mark = vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })[1]
    assert.equal("Visual", mark[4].hl_group)
    assert.equal(6, mark[4].end_col)
    root:unmount()
  end)

  it("the removed flat color props error loudly on components too", function()
    for _, props in ipairs({
      { text = "x", hl = "Title" },
      { text = "x", bg = "Visual" },
      { text = "x", hover_hl = "Search" },
    }) do
      local function App()
        return { comp = ui.label, props = props }
      end
      local host = host_of(4)
      assert.has_error(function()
        runtime.create_root(App, {}, { host = host }):render()
      end, "removed")
    end
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

  it("label accepts a rich-text span list", function()
    local function App()
      return { comp = ui.label, props = { text = { "ab ", { "cd", hl = "Title" } } } }
    end
    local host = host_of(6)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({ "ab cd " }, lines_of(host))
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "Title" then
        found = { m[2], m[3], m[4].end_col }
      end
    end
    assert.same({ 0, 3, 5 }, found)
    root:unmount()
  end)

  it("button renders a bracket chip and forwards its handler and role to the node", function()
    local pressed = function() end
    local function App()
      return { comp = ui.button, props = { label = "OK", on_press = pressed } }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    -- the brackets are the themed BORDER, so a full-width button (a root node
    -- fills the host) keeps them at its edges
    assert.same({ "[ OK   ]" }, lines_of(host))
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
    -- an explicit border REPLACES the chip's bracket border (box keys are
    -- atomic): border = true means a real themed box, not brackets in a box
    local function App()
      return { comp = ui.button, props = { label = "OK", style = { border = true } } }
    end
    local host = host_of(8)
    local root = runtime.create_root(App, {}, { host = host }):render()

    assert.same({
      "╭──────╮",
      "│ OK   │",
      "╰──────╯",
    }, lines_of(host))
    root:unmount()
  end)

  describe("themed defaults", function()
    -- All extmark spans of `hl` as { row, col, end_col } triples.
    local function marks_with(bufnr, hl)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
        if m[4].hl_group == hl then
          out[#out + 1] = { m[2], m[3], m[4].end_col }
        end
      end
      return out
    end

    -- Buttons sit in a col so their shrink-wrap applies (the chip hugs the widget).
    local function col_of(child)
      return function()
        return { comp = ui.col, props = {}, children = { child } }
      end
    end

    it("button gets the FibrousButton chip and FibrousButtonHover hover", function()
      local host = host_of(8)
      local App = col_of({ comp = ui.button, props = { label = "OK" } })
      local root = runtime.create_root(App, {}, { host = host }):render()

      -- same 6-cell footprint as ever, one uniform span: the transparent
      -- bracket border inherits the chip fill
      assert.same({ "[ OK ]  " }, lines_of(host))
      assert.same({ { 0, 0, 6 } }, marks_with(host.bufnr, "FibrousButton"))
      assert.equal("FibrousButtonHover", host.tree.children[1].style.hover.hl)
      root:unmount()
    end)

    it("the brackets are border chars: restyle them with a border prop", function()
      local host = host_of(8)
      local App = col_of({
        comp = ui.button,
        props = { label = "OK", style = { border = { left = "(", right = ")", hl = false } } },
      })
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({ "( OK )  " }, lines_of(host))
      root:unmount()
    end)

    it("explicit props win over the theme", function()
      local host = host_of(8)
      local App =
        col_of({ comp = ui.button, props = { label = "OK", style = { hl = "Visual", _hover = { hl = "Search" } } } })
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({}, marks_with(host.bufnr, "FibrousButton"))
      assert.same({ { 0, 0, 6 } }, marks_with(host.bufnr, "Visual"))
      assert.equal("Search", host.tree.children[1].style.hover.hl)
      root:unmount()
    end)

    it("theme = false opts a component out of its defaults", function()
      local function App()
        return { comp = ui.button, props = { label = "OK", theme = false } }
      end
      local host = host_of(8)
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({}, marks_with(host.bufnr, "FibrousButton"))
      -- the brackets ARE theme (border + padding), so opting out drops them:
      -- a bare-label starting point for wrapper components
      assert.same({ "OK      " }, lines_of(host))
      root:unmount()
    end)

    it("checkbox marks render dim when unchecked, accented when checked", function()
      local checked
      local function App(ctx)
        checked = ctx.use_state(false)
        return { comp = ui.checkbox, props = { label = "Opt", checked = checked.get() } }
      end
      local host = host_of(8)
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({ "[ ] Opt " }, lines_of(host))
      assert.same({ { 0, 0, 3 } }, marks_with(host.bufnr, "FibrousDim"))

      checked.set(true)
      assert.same({ "[x] Opt " }, lines_of(host))
      assert.same({ { 0, 0, 3 } }, marks_with(host.bufnr, "FibrousCheckboxMark"))
      root:unmount()
    end)

    it("a marks prop overrides the themed checkbox marks key-wise", function()
      local checked
      local function App(ctx)
        checked = ctx.use_state(true)
        return {
          comp = ui.checkbox,
          props = {
            label = "Opt",
            checked = checked.get(),
            -- override only `checked`; `unchecked` keeps the themed default
            marks = { checked = { "*", hl = "Accent" } },
          },
        }
      end
      local host = host_of(8)
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({ "* Opt   " }, lines_of(host))
      assert.same({ { 0, 0, 1 } }, marks_with(host.bufnr, "Accent"))

      checked.set(false)
      assert.same({ "[ ] Opt " }, lines_of(host))
      assert.same({ { 0, 0, 3 } }, marks_with(host.bufnr, "FibrousDim"))
      root:unmount()
    end)

    it("host primitives default their theme key to their own tag", function()
      local theme = require("fibrous.inline.theme")
      theme.styles.text = { text_hl = "ThemedText" }
      local function App()
        return { comp = ui.text, props = { text = "hi" } } -- no theme prop
      end
      local host = host_of(4)
      local root = runtime.create_root(App, {}, { host = host }):render()

      assert.same({ { 0, 0, 2 } }, marks_with(host.bufnr, "ThemedText"))
      root:unmount()
      theme.styles.text = nil
    end)

    it("any node can opt into a theme key by prop", function()
      local function App()
        return { comp = ui.label, props = { text = "hi", theme = "button" } }
      end
      local host = host_of(8)
      local root = runtime.create_root(App, {}, { host = host }):render()

      -- the full chip: bracket border + padding + fill (a root node fills the host)
      assert.same({ "[ hi   ]" }, lines_of(host))
      assert.same({ { 0, 0, 8 } }, marks_with(host.bufnr, "FibrousButton"))
      root:unmount()
    end)

    it("an unknown theme key errors loudly", function()
      local function App()
        return { comp = ui.label, props = { text = "hi", theme = "buttn" } }
      end
      local host = host_of(4)
      assert.has_error(function()
        runtime.create_root(App, {}, { host = host }):render()
      end, "buttn")
    end)
  end)
end)
