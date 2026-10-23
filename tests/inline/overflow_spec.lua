local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function tree(value, overflow)
  return { kind = "col", props = {}, children = {
    { kind = "col", props = { grow = 1, overflow = overflow or "hidden" }, children = {
      { kind = "text", props = { height = 4, hl = "Search" }, text = value or "one\ntwo\nhidden\nleak" },
    } },
    { kind = "text", props = { height = 1 }, text = "END" },
  } }
end

describe("inline overflow", function()
  it("clips embedded inputs and their root-buffer mirrors above the footer", function()
    local function App()
      return { comp = ui.col, props = {}, children = {
        { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
          { comp = ui.text_input, props = { value = "one\nleak", height = 2, render = "always" } },
        } },
        { comp = ui.button, props = { label = "Overview", theme = false, height = 1 } },
      } }
    end
    local app = mount.floating(App, {}, { width = 12, height = 2, mode = "fixed" })
    local found
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == app.winid then found = win end
    end
    assert.is_not_nil(found)
    assert.equal(1, vim.api.nvim_win_get_height(found))
    local lines = vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false)
    assert.truthy(lines[2]:find("Overview", 1, true))
    app.unmount()
  end)

  it("leaves adjacent wide characters intact when a fully clipped child updates", function()
    local function make(value)
      return { kind = "row", props = {}, children = {
        { kind = "row", props = { width = 1, overflow = "hidden" }, children = {
          { kind = "text", props = { width = 2 }, text = "a" },
          { kind = "text", props = { width = 2 }, text = value },
        } },
        { kind = "text", props = { width = 2 }, text = "界" },
      } }
    end
    local first = layout.compute(make("old"), { width = 3, height = 1 })
    local c = render.paint(first, 3, 1)
    assert.same({ "a界" }, c:lines())
    local next_tree = make("new")
    next_tree._prev, next_tree._old_rect = first, first.rect
    local body = next_tree.children[1]
    body._prev, body._old_rect = first.children[1], first.children[1].rect
    body.children[1], next_tree.children[2] = first.children[1].children[1], first.children[2]
    body.children[1]._memo, next_tree.children[2]._memo = true, true
    body.children[2]._old_rect = first.children[1].children[2].rect
    body.children[2]._old_clip = first.children[1].children[2].clip
    layout.compute(next_tree, { width = 3, height = 1 })
    local rows = render.update(c, next_tree)
    assert.same({ "a界" }, c:lines())
    assert.same({}, rows)
  end)

  it("updates a clipped subtree without overwriting unchanged footer cells", function()
    local function App(_, props)
      return { comp = ui.col, props = {}, children = {
        { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
          { comp = ui.label, props = { height = 4, text = props.text, style = { hl = "Search" } } },
        } },
        { comp = ui.button, props = { label = "END", theme = false, height = 1 } },
      } }
    end
    local app = mount.floating(App, { text = "a\nb\nleak\nleak" }, { width = 5, height = 3 })
    app.set_props({ text = "x\ny\noops\noops" })
    assert.same({ "x    ", "y    ", "END  " }, vim.api.nvim_buf_get_lines(app.bufnr, 0, -1, false))
    app.unmount()
  end)

  it("clips descendants above a footer including their background", function()
    local t = tree()
    layout.compute(t, { width = 5, height = 3 })
    local c = render.paint(t, 5, 3)
    assert.same({ "one  ", "two  ", "END  " }, c:lines())
    for _, mark in ipairs(c:highlights()) do
      assert.is_true(mark.row < 2)
    end
  end)

  it("clips horizontally and composes nested clipping with padding", function()
    local t = { kind = "col", props = { overflow = "hidden", padding = 1 }, children = {
      { kind = "row", props = { height = 1, overflow = "hidden" }, children = {
        { kind = "text", props = { width = 8 }, text = "界abcd" },
      } },
      { kind = "text", props = {}, text = "hidden" },
    } }
    layout.compute(t, { width = 6, height = 3 })
    assert.same({ "      ", " 界ab ", "      " }, render.paint(t, 6, 3):lines())
  end)

  it("keeps incremental paint inside the clip and repaints when the clip changes", function()
    local first = tree()
    layout.compute(first, { width = 5, height = 3 })
    local c = render.paint(first, 5, 3)
    local next_tree = tree("new\ntext\noops\nleak")
    next_tree._prev, next_tree._old_rect = first, first.rect
    for i, child in ipairs(next_tree.children) do
      child._prev, child._old_rect = first.children[i], first.children[i].rect
    end
    render.update(c, layout.compute(next_tree, { width = 5, height = 3 }))
    assert.same({ "new  ", "text ", "END  " }, c:lines())
    assert.same(render.paint(next_tree, 5, 3):lines(), c:lines())

    local leaf = next_tree.children[1].children[1]
    leaf._memo = true
    local resized = tree()
    resized.children[1].props.height, resized.children[1].props.grow = 1, nil
    resized.children[1].children = { leaf }
    resized._prev, resized._old_rect = next_tree, next_tree.rect
    resized.children[1]._prev = next_tree.children[1]
    resized.children[1]._old_rect = next_tree.children[1].rect
    resized.children[2]._old_rect = next_tree.children[2].rect
    layout.compute(resized, { width = 5, height = 3 })
    render.update(c, resized)
    assert.same({ "new  ", "END  ", "     " }, c:lines())
    assert.same(render.paint(resized, 5, 3):lines(), c:lines())
  end)

  it("clips hover marks and keeps a footer reachable at minimum height", function()
    local function App()
      return { comp = ui.col, props = {}, children = {
        { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
          { comp = ui.button, props = {
            label = "tall", height = 4, theme = false, style = { _hover = { hl = "Search" } },
          } },
        } },
        { comp = ui.button, props = { label = "Overview", theme = false, height = 1 } },
      } }
    end
    local app = mount.floating(App, {}, { width = 12, height = 2 })
    vim.api.nvim_set_current_win(app.winid)
    vim.api.nvim_win_set_cursor(app.winid, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = app.bufnr })
    local found = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(app.bufnr, -1, 0, -1, { details = true })) do
      if mark[4].hl_group == "Search" then
        found = true
        assert.equal(0, mark[2])
      end
    end
    assert.is_true(found)
    app.unmount()

    app = mount.floating(App, {}, { width = 12, height = 1 })
    local targets = require("fibrous.targets").targets({ winid = app.winid })
    assert.equal(1, #targets)
    assert.truthy(vim.api.nvim_buf_get_lines(app.bufnr, 0, 1, false)[1]:find("Overview", 1, true))
    app.unmount()
  end)

  it("lands Tab on the visible border when a button's content is clipped", function()
    local function App()
      return { comp = ui.col, props = {}, children = {
        { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
          { comp = ui.button, props = {
            label = "clipped", theme = false, height = 2, style = { border = { top = true } },
          } },
        } },
        { comp = ui.button, props = { label = "Overview", theme = false, height = 1 } },
      } }
    end
    local app = mount.floating(App, {}, { width = 12, height = 2 })
    vim.api.nvim_set_current_win(app.winid)
    vim.api.nvim_win_set_cursor(app.winid, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "xt", false)
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(app.winid))
    app.unmount()
  end)

  it("excludes clipped buttons from Tab and jump targets without another buffer", function()
    local function App()
      return { comp = ui.col, props = {}, children = {
        { comp = ui.col, props = { grow = 1, overflow = "hidden" }, children = {
          { comp = ui.button, props = { label = "visible", theme = false } },
          { comp = ui.button, props = { label = "hidden", theme = false } },
        } },
        { comp = ui.button, props = { label = "Overview", theme = false, height = 1 } },
      } }
    end
    local app = mount.floating(App, {}, { width = 12, height = 2, mode = "fixed" })
    local function press(key)
      vim.api.nvim_set_current_win(app.winid)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
    end
    vim.api.nvim_win_set_cursor(app.winid, { 1, 0 })
    press("<Tab>")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(app.winid))
    press("<Tab>")
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(app.winid))
    local targets = require("fibrous.targets").targets({ winid = app.winid })
    assert.equal(2, #targets)
    app.unmount()
  end)
end)
