-- ui.popup: a zero-footprint overlay leaf. Unlike every other subwindow leaf
-- (text_input, raw_buffer, container), a popup occupies NO cells in its
-- parent's layout: the node measures 0x0 and its rect is just an anchor
-- point in the flow. Its children flush into the popup's own buffer (a host
-- flush target, exactly the container machinery) shown in a float placed AT
-- the anchor: directly below the preceding sibling, same left edge. The
-- float escapes the mount's box (it clips against the editor, not the root
-- viewport), sits in a reserved zindex band above any nesting depth, and is
-- never focusable: a popup is a display surface, the anchoring widget keeps
-- the focus and drives it through ordinary reactive state.

local mount = require("fibrous.inline.mount")
local subwin = require("fibrous.inline.subwin")
local ui = require("fibrous.inline.components")

-- All floats anchored to `winid`, in creation order; row/col reconstructed in
-- ROOT coordinates (see container_spec).
local function subwins_of(winid)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == winid then
      local cfg = vim.api.nvim_win_get_config(win)
      if not cfg.hide then
        local fp = vim.api.nvim_win_get_position(win)
        local rp = vim.api.nvim_win_get_position(winid)
        cfg.row, cfg.col = fp[1] - rp[1], fp[2] - rp[2]
      end
      out[#out + 1] = { winid = win, cfg = cfg }
    end
  end
  return out
end

local function subwin_of(winid)
  local subs = subwins_of(winid)
  return subs[1] and subs[1].winid, subs[1] and subs[1].cfg
end

local function trimmed(bufnr)
  return vim.tbl_map(function(l)
    return (l:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

describe("ui.popup", function()
  it("overlays at its anchor point without occupying layout rows", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.popup,
            props = {},
            children = {
              { comp = ui.label, props = { text = "alpha" } },
              { comp = ui.label, props = { text = "beta beta" } },
            },
          },
          { comp = ui.label, props = { text = "tail" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 6, row = 2, col = 4 })

    -- ZERO footprint: tail sits directly under head, no row reserved
    assert.same({ "head", "tail", "", "", "", "" }, trimmed(handle.bufnr))

    local sub, cfg = subwin_of(handle.winid)
    assert.is_not_nil(sub)
    -- anchored below head, same left edge, sized to its content
    assert.equal(1, cfg.row)
    assert.equal(0, cfg.col)
    assert.equal(9, cfg.width) -- "beta beta"
    assert.equal(2, cfg.height)
    -- overlay: never focusable, and in the reserved zindex band above any
    -- nesting depth (root default 50, subwindow levels 51, 52, ...)
    assert.falsy(cfg.focusable)
    assert.is_true(cfg.zindex >= 150)

    -- the float shows the popup's OWN buffer, painted by the same host
    local pbuf = vim.api.nvim_win_get_buf(sub)
    assert.is_true(pbuf ~= handle.bufnr)
    assert.same({ "alpha", "beta beta" }, trimmed(pbuf))

    handle.unmount()
  end)

  it("appears and disappears with conditional rendering", function()
    local function App(_, props)
      local children = {
        { comp = ui.label, props = { text = "field" } },
      }
      if props.open then
        children[#children + 1] = {
          comp = ui.popup,
          props = {},
          children = { { comp = ui.label, props = { text = "option" } } },
        }
      end
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, { open = false }, { width = 12, height = 4 })
    assert.is_nil(subwin_of(handle.winid))

    handle.set_props({ open = true })
    local sub = subwin_of(handle.winid)
    assert.is_not_nil(sub)
    assert.same({ "option" }, trimmed(vim.api.nvim_win_get_buf(sub)))

    handle.set_props({ open = false })
    assert.is_nil(subwin_of(handle.winid))
    -- the popup's buffer is retired with its float
    assert.falsy(vim.api.nvim_win_is_valid(sub))

    handle.unmount()
  end)

  it("flips above the anchor when there is no room below", function()
    local options = {}
    for i = 1, 6 do
      options[#options + 1] = { comp = ui.label, props = { text = "o" .. i } }
    end
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "field" } },
          { comp = ui.popup, props = {}, children = options },
        },
      }
    end
    -- editor is vim.o.lines - cmdheight rows; park the mount near the bottom
    -- so 6 rows don't fit below the anchor
    local eh = vim.o.lines - vim.o.cmdheight
    local handle = mount.floating(App, {}, { width = 10, height = 4, row = eh - 5, col = 2 })

    local _, cfg = subwin_of(handle.winid)
    assert.is_not_nil(cfg)
    -- flipped: the popup's bottom edge clears flip_offset (1) rows above the
    -- anchor, i.e. it sits wholly above the field row
    assert.equal(6, cfg.height)
    assert.equal(-6, cfg.row)

    handle.unmount()
  end)

  it("escapes the mount box when the anchor sits on its last row", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "pad" } },
          { comp = ui.label, props = { text = "field" } },
          { comp = ui.popup, props = {}, children = { { comp = ui.label, props = { text = "opt" } } } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2, row = 3, col = 2 })

    local _, cfg = subwin_of(handle.winid)
    assert.is_not_nil(cfg)
    -- the anchor row is one past the mount's 2-row box: the popup shows BELOW
    -- the mount instead of being clipped by it
    assert.equal(2, cfg.row)

    handle.unmount()
  end)

  it("hides when the anchor scrolls out of the root viewport, and returns", function()
    local children = {
      { comp = ui.label, props = { text = "field" } },
      { comp = ui.popup, props = {}, children = { { comp = ui.label, props = { text = "opt" } } } },
    }
    for i = 1, 10 do
      children[#children + 1] = { comp = ui.label, props = { text = "row " .. i } }
    end
    local function App()
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4, mode = "scroll", scroll_y = true })
    assert.is_not_nil(subwin_of(handle.winid))

    local function scroll_to(topline)
      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ topline = topline })
      end)
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
    end

    scroll_to(6) -- the field (row 0) is far above the viewport now
    local sub, cfg = subwin_of(handle.winid)
    assert.is_true(cfg.hide == true)

    scroll_to(1)
    sub, cfg = subwin_of(handle.winid)
    assert.falsy(cfg.hide)
    assert.equal(1, cfg.row)

    handle.unmount()
  end)
end)

describe("subwin.popup_place", function()
  local editor = { w = 80, h = 24 }

  it("places below the anchor when the content fits", function()
    assert.same(
      { row = 5, col = 2, w = 10, h = 3 },
      subwin.popup_place({ row = 5, col = 2 }, { w = 10, h = 3 }, editor)
    )
  end)

  it("flips above (clearing flip_offset rows) when below is too small", function()
    -- below = 24 - 20 = 4, above = 19: flip, bottom edge at row 18
    assert.same(
      { row = 9, col = 0, w = 10, h = 10 },
      subwin.popup_place({ row = 20, col = 0 }, { w = 10, h = 10 }, editor)
    )
    -- a taller anchoring widget clears more rows
    assert.same(
      { row = 7, col = 0, w = 10, h = 10 },
      subwin.popup_place({ row = 20, col = 0 }, { w = 10, h = 10 }, editor, 3)
    )
  end)

  it("shrinks to the larger side when the content fits neither", function()
    -- flipped and shrunk to the 19 rows above
    assert.same(
      { row = 0, col = 0, w = 10, h = 19 },
      subwin.popup_place({ row = 20, col = 0 }, { w = 10, h = 30 }, editor)
    )
    -- below is the larger side: stay below, shrink to it
    assert.same(
      { row = 10, col = 0, w = 10, h = 14 },
      subwin.popup_place({ row = 10, col = 0 }, { w = 10, h = 30 }, editor)
    )
  end)

  it("slides left only as far as the editor edge requires", function()
    assert.same(
      { row = 5, col = 70, w = 10, h = 2 },
      subwin.popup_place({ row = 5, col = 75 }, { w = 10, h = 2 }, editor)
    )
    -- wider than the whole editor: clamp to it, pin to column 0
    assert.same(
      { row = 5, col = 0, w = 80, h = 2 },
      subwin.popup_place({ row = 5, col = 40 }, { w = 100, h = 2 }, editor)
    )
  end)
end)
