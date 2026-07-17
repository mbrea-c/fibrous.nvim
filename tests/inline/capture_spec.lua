-- capture_cursor (requests.md): a subwindow leaf may opt into holding the
-- cursor — edge h/j/k/l and <C-d>/<C-u> stay native motions inside the float
-- instead of stepping out into the page. <Esc> (and <C-w>, which acts on the
-- host pane anyway) remain the ways out. Off by default: the glide-through
-- traversal is the norm; a notebook cell is the kind of widget that wants
-- deliberate exits only.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function subwin_of(handle)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[w].fibrous_anchor == handle.winid then
      return w
    end
  end
  return nil
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function app(bufnr, props)
  return function()
    return {
      comp = ui.col,
      props = {},
      children = {
        { comp = ui.label, props = { text = "head" } },
        {
          comp = ui.raw_buffer,
          props = vim.tbl_extend("force", { bufnr = bufnr, render = "always", wrap = false }, props or {}),
        },
        { comp = ui.label, props = { text = "tail" } },
      },
    }
  end
end

describe("inline capture_cursor", function()
  it("edge h/j/k/l stay inside a capturing widget", function()
    local bufnr = make_buf({ "one", "two" })
    local handle = mount.floating(app(bufnr, { capture_cursor = true }), {}, { width = 12, height = 8 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    vim.api.nvim_feedkeys("k", "xt", false) -- top edge: would exit without capture
    assert.equal(sub, vim.api.nvim_get_current_win())

    vim.api.nvim_win_set_cursor(sub, { 2, 0 })
    vim.api.nvim_feedkeys("j", "xt", false) -- bottom edge
    assert.equal(sub, vim.api.nvim_get_current_win())

    vim.api.nvim_feedkeys("h", "xt", false) -- left edge
    assert.equal(sub, vim.api.nvim_get_current_win())

    vim.api.nvim_win_set_cursor(sub, { 2, 2 })
    vim.api.nvim_feedkeys("l", "xt", false) -- right edge
    assert.equal(sub, vim.api.nvim_get_current_win())

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("<C-d>/<C-u> stay native inside a capturing widget", function()
    local lines = {}
    for i = 1, 30 do
      lines[i] = "line " .. i
    end
    local bufnr = make_buf(lines)
    local handle = mount.floating(app(bufnr, { capture_cursor = true, height = 5 }), {}, { width = 12, height = 8 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "xt", false)
    -- still in the float, and the float itself scrolled
    assert.equal(sub, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_get_cursor(sub)[1] > 1)

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("<Esc> still pops out of a capturing widget", function()
    local bufnr = make_buf({ "one", "two" })
    local handle = mount.floating(app(bufnr, { capture_cursor = true }), {}, { width = 12, height = 8 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("without the prop, the edge exit still glides out (the default)", function()
    local bufnr = make_buf({ "one", "two" })
    local handle = mount.floating(app(bufnr), {}, { width = 12, height = 8 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    vim.api.nvim_win_set_cursor(sub, { 1, 0 })
    vim.api.nvim_feedkeys("k", "xt", false)
    assert.equal(handle.winid, vim.api.nvim_get_current_win())

    handle.unmount()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
