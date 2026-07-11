-- fibrous.targets: a global registry of the interactive elements currently on
-- screen, across every mount and window/float — pure geometry, shaped to feed
-- flash.nvim's custom matcher ({ winid, pos = {row, col}, end_pos, kind, role }).
-- Phase 1 covers role-carrying elements in a mount's ROOT buffer.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local targets = require("fibrous.targets")

local function App()
  return {
    comp = ui.col,
    props = { gap = 1 },
    children = {
      { comp = ui.label, props = { text = "not interactive" } },
      { comp = ui.button, props = { label = "Click me", on_press = function() end } },
      { comp = ui.checkbox, props = { label = "toggle", checked = false, on_toggle = function() end } },
    },
  }
end

describe("fibrous.targets", function()
  it("returns root-level interactive elements as flash-shaped geometry", function()
    local before = #targets.targets()
    local handle = mount.floating(App, {}, { width = 30, height = 8 })

    local list = targets.targets({ winid = handle.winid })
    local kinds = vim.tbl_map(function(t)
      return t.kind
    end, list)
    -- the button and checkbox are targets; the plain label is not
    assert.is_true(vim.tbl_contains(kinds, "button"), "button is a target")
    assert.is_true(vim.tbl_contains(kinds, "checkbox"), "checkbox is a target")
    assert.equal(2, #list)

    -- each is well-shaped: winid + 1-based row / 0-based col + end_pos
    for _, t in ipairs(list) do
      assert.equal(handle.winid, t.winid)
      assert.equal("number", type(t.pos[1]))
      assert.equal("number", type(t.pos[2]))
      assert.is_true(t.pos[1] >= 1) -- row is 1-based
      assert.equal("number", type(t.end_pos[1]))
      assert.equal("number", type(t.end_pos[2]))
    end

    handle.unmount()
    -- the mount deregisters on unmount: back to the pre-mount count
    assert.equal(before, #targets.targets())
  end)

  it("filters by kind and by predicate", function()
    local handle = mount.floating(App, {}, { width = 30, height = 8 })

    local buttons = targets.targets({ winid = handle.winid, kinds = { "button" } })
    assert.equal(1, #buttons)
    assert.equal("button", buttons[1].kind)

    local checks = targets.targets({
      winid = handle.winid,
      predicate = function(t)
        return t.role == "checkbox"
      end,
    })
    assert.equal(1, #checks)
    assert.equal("checkbox", checks[1].kind)

    handle.unmount()
  end)

  it("finds role elements inside a VISIBLE container float, in the float's window", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = { height = 4, render = "always" }, -- always shown as a live float
            children = {
              { comp = ui.button, props = { label = "inside", on_press = function() end } },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 30, height = 8 })
    vim.wait(50, function()
      return false
    end)
    local list = targets.targets({ kinds = { "button" } })
    assert.equal(1, #list)
    -- resolved to the container FLOAT, not the root window
    assert.is_true(list[1].winid ~= handle.winid, "target is in the container float")
    assert.is_true(vim.api.nvim_win_is_valid(list[1].winid))
    handle.unmount()
  end)

  it("resolves a MIRRORED editable widget (render='focus', unfocused) to the parent cell", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "head" } },
          -- render="focus" + unfocused: the input mirrors into the parent rather
          -- than showing a live float, so its target is a ROOT-window cell
          { comp = ui.text_input, props = { value = "edit me", height = 1, render = "focus" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 30, height = 6 })
    vim.wait(50, function()
      return false
    end)
    local list = targets.targets({ winid = handle.winid, kinds = { "text_input" } })
    assert.equal(1, #list)
    assert.equal(handle.winid, list[1].winid) -- resolved via the mirror to the root
    -- lands on the input's mirrored row (the "head" label is row 1, input row 2)
    assert.is_true(list[1].pos[1] >= 2)
    handle.unmount()
  end)

  it("includes editable widgets (text_input) as targets", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.text_input, props = { value = "hi", height = 1 } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 20, height = 4 })
    vim.wait(50, function()
      return false
    end)
    local list = targets.targets({ kinds = { "text_input" } })
    assert.equal(1, #list)
    handle.unmount()
  end)

  it("includes interactive spans (links) as targets, one per logical span", function()
    local function App()
      return {
        comp = ui.paragraph,
        props = {
          text = {
            "see ",
            { "the link", on_click = function() end, role = "link" },
            " now",
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 30, height = 3 })

    local links = targets.targets({ winid = handle.winid, kinds = { "link" } })
    assert.equal(1, #links)
    assert.equal("link", links[1].kind)
    assert.equal("link", links[1].role)
    assert.equal(handle.winid, links[1].winid)
    -- single-line, anchored at the span's first cell ("the link" after "see ")
    assert.equal(links[1].pos[1], links[1].end_pos[1])
    assert.equal(4, links[1].pos[2])

    handle.unmount()
  end)

  it("emits ONE target for a link that wrapped across lines", function()
    local function App()
      return {
        comp = ui.paragraph,
        props = {
          text = { { "aaaa bbbb", on_click = function() end, role = "link" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 4, height = 3 })
    local links = targets.targets({ winid = handle.winid, kinds = { "link" } })
    assert.equal(1, #links)
    handle.unmount()
  end)

  it("only returns elements visible in the window's viewport", function()
    -- a tall column in a short scroll-mode float: buttons past the bottom of the
    -- viewport are NOT returned (flash only labels what's on screen)
    local function Tall()
      local kids = {}
      for i = 1, 40 do
        kids[i] = { comp = ui.button, props = { label = "b" .. i, on_press = function() end } }
      end
      return { comp = ui.col, props = {}, children = kids }
    end
    local handle = mount.floating(Tall, {}, { width = 20, height = 5, mode = "scroll" })
    local list = targets.targets({ winid = handle.winid })
    -- only the handful of rows in the 5-high viewport, not all 40
    assert.is_true(#list > 0)
    assert.is_true(#list < 40, "off-screen buttons are excluded (" .. #list .. ")")
    handle.unmount()
  end)
end)
