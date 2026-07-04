-- The guicursor shim. nvim renders the cursor as the REPLACE-mode guicursor
-- shape (default hor20 → an underscore) whenever a higher-zindex float covers
-- its cell: ui_flush() substitutes mode_change("replace") for the obscured
-- cursor (src/nvim/ui.c). With render="always" subwindows the root cursor
-- glides under our floats constantly, so while any such widget is live
-- fibrous appends ",r-cr:block" to guicursor — the glide cursor stays a
-- block, and the text mirror guarantees the character under it is real.
--
-- The shim must never clobber the user's option: refcounted across mounts,
-- inert when shaping is disabled (guicursor == ""), and restore-only-if-
-- untouched when a user or plugin changed guicursor while it was held.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local DEFAULT = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20"

local function AlwaysApp()
  return {
    comp = ui.col,
    props = {},
    children = {
      { comp = ui.text_input, props = { value = "x", height = 1, render = "always" } },
    },
  }
end

-- No render prop: the DEFAULT policy is "focus", which never needs the shim
-- (its floats are hidden while unfocused — nothing for the cursor to sit under).
local function DefaultApp()
  return {
    comp = ui.col,
    props = {},
    children = {
      { comp = ui.text_input, props = { value = "x", height = 1 } },
    },
  }
end

local function NoSubwinApp()
  return {
    comp = ui.col,
    props = {},
    children = { { comp = ui.label, props = { text = "hi" } } },
  }
end

describe("inline.cursorshim", function()
  local saved
  before_each(function()
    saved = vim.o.guicursor
    vim.o.guicursor = DEFAULT
  end)
  after_each(function()
    vim.o.guicursor = saved
  end)

  it("an always-policy subwindow appends the replace-block override; unmount restores", function()
    local handle = mount.floating(AlwaysApp, {}, { width = 8, height = 3 })
    assert.equal(DEFAULT .. ",r-cr:block", vim.o.guicursor)

    handle.unmount()
    assert.equal(DEFAULT, vim.o.guicursor)
  end)

  it("never clobbers a guicursor changed while mounted", function()
    local handle = mount.floating(AlwaysApp, {}, { width = 8, height = 3 })
    vim.o.guicursor = "a:ver25" -- the user wins
    handle.unmount()
    assert.equal("a:ver25", vim.o.guicursor)
  end)

  it("guicursor == '' (shaping disabled) stays untouched", function()
    vim.o.guicursor = ""
    local handle = mount.floating(AlwaysApp, {}, { width = 8, height = 3 })
    assert.equal("", vim.o.guicursor)
    handle.unmount()
    assert.equal("", vim.o.guicursor)
  end)

  it("two mounts share one shim; it lifts after the last unmount", function()
    local h1 = mount.floating(AlwaysApp, {}, { width = 8, height = 3 })
    local h2 = mount.floating(AlwaysApp, {}, { width = 8, height = 3, row = 10, col = 10 })
    assert.equal(DEFAULT .. ",r-cr:block", vim.o.guicursor)

    h1.unmount()
    assert.equal(DEFAULT .. ",r-cr:block", vim.o.guicursor)
    h2.unmount()
    assert.equal(DEFAULT, vim.o.guicursor)
  end)

  it("default-policy (focus) and widget-less apps never touch guicursor", function()
    local h1 = mount.floating(DefaultApp, {}, { width = 8, height = 3 })
    assert.equal(DEFAULT, vim.o.guicursor)
    h1.unmount()

    local h2 = mount.floating(NoSubwinApp, {}, { width = 8, height = 3 })
    assert.equal(DEFAULT, vim.o.guicursor)
    h2.unmount()
    assert.equal(DEFAULT, vim.o.guicursor)
  end)

  it("removing the last always-policy widget from the tree lifts the shim live", function()
    local setter
    local function App(ctx)
      local show = ctx.use_state(true)
      setter = show
      local children = { { comp = ui.label, props = { text = "top" } } }
      if show.get() then
        children[#children + 1] = { comp = ui.text_input, props = { height = 1, render = "always" } }
      end
      return { comp = ui.col, props = {}, children = children }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 4 })
    assert.equal(DEFAULT .. ",r-cr:block", vim.o.guicursor)

    setter.set(false)
    assert.equal(DEFAULT, vim.o.guicursor)

    handle.unmount()
    assert.equal(DEFAULT, vim.o.guicursor)
  end)
end)
