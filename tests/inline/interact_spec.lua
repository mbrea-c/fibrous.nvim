-- Cursor interaction for the inline host (tracker "NEW UI HOST" task 6). The
-- vim cursor drives hover and activation: a hit-map lookup walks the laid-out
-- tree (host.tree, fiber-backed nodes) for the deepest node under the cursor
-- carrying a `role`. Hover paints the node's rect with its hover_hl (own
-- extmark namespace, re-evaluated on CursorMoved and after every flush);
-- <CR>/<Space> (buffer-local, normal mode) activate: button → on_press(),
-- checkbox → on_toggle(not checked).

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Extmark spans with the given hl group, as { row, col, end_col } triples.
local function marks_with(bufnr, hl)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col }
    end
  end
  return out
end

-- Put the cursor at (row, col) [1-based row] in the root float and re-evaluate
-- hover the way live cursor movement does.
local function move_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

local function press(handle, key)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

describe("inline.interact", function()
  it("moving the cursor onto a button hovers it; moving off clears the hover", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "title" } },
          { comp = ui.button, props = { label = "OK", hover_hl = "Search" } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })

    move_cursor(handle, 2, 0) -- the button row
    -- buttons shrink-wrap by default, so the hover hugs "[ OK ]"
    assert.same({ { row = 1, col = 0, end_col = 6 } }, marks_with(handle.bufnr, "Search"))

    move_cursor(handle, 1, 0) -- the label row
    assert.same({}, marks_with(handle.bufnr, "Search"))

    handle.unmount()
  end)

  it("<CR> activates the button under the cursor; inert rows do nothing", function()
    local pressed = 0
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "title" } },
          {
            comp = ui.button,
            props = {
              label = "OK",
              on_press = function()
                pressed = pressed + 1
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 4 })

    move_cursor(handle, 2, 0)
    press(handle, "<CR>")
    assert.equal(1, pressed)

    move_cursor(handle, 1, 0)
    press(handle, "<CR>")
    assert.equal(1, pressed)

    handle.unmount()
  end)

  it("<Space> toggles a checkbox; the re-render keeps the hover under the cursor", function()
    local function App(ctx)
      local checked = ctx.use_state(false)
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.checkbox,
            props = {
              label = "Opt",
              checked = checked.get(),
              hover_hl = "Search",
              on_toggle = function(v)
                checked.set(v)
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })

    move_cursor(handle, 1, 0)
    press(handle, "<Space>")
    assert.equal("[x] Opt   ", lines_of(handle.bufnr)[1])
    -- the flush re-evaluated hover: still highlighted under the cursor,
    -- hugging the checkbox's own cells ("[x] Opt")
    assert.same({ { row = 0, col = 0, end_col = 7 } }, marks_with(handle.bufnr, "Search"))

    press(handle, "<Space>")
    assert.equal("[ ] Opt   ", lines_of(handle.bufnr)[1])

    handle.unmount()
  end)

  it("the hit-map picks the deepest interactive node under the cursor", function()
    local outer_pressed, inner_pressed = 0, 0
    local function App()
      return {
        comp = ui.col,
        props = {
          role = "button", -- a container can be interactive too
          on_press = function()
            outer_pressed = outer_pressed + 1
          end,
        },
        children = {
          { comp = ui.label, props = { text = "head" } },
          {
            comp = ui.button,
            props = {
              label = "in",
              on_press = function()
                inner_pressed = inner_pressed + 1
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 3 })

    move_cursor(handle, 2, 0) -- the inner button row
    press(handle, "<CR>")
    assert.equal(1, inner_pressed)
    assert.equal(0, outer_pressed)

    move_cursor(handle, 1, 0) -- the label row: falls through to the container
    press(handle, "<CR>")
    assert.equal(1, outer_pressed)

    handle.unmount()
  end)

  -- Mouse interaction (tracker "NEW UI HOST" task 10). Neovim's own
  -- mouse=nvi handling already moves the cursor on click (so hover follows
  -- clicks for free); fibrous adds click-to-activate (<LeftRelease>, on by
  -- default) and an opt-in focus-follows-mouse mode (<MouseMove> moves the
  -- cursor — hover and focus stay a single, cursor-positional concept).
  -- The specs drive the maps at the key level (like the <CR> tests above):
  -- synthesizing real clicks via nvim_input_mouse doesn't work headless —
  -- without a UI grid, mouse_find_win can't resolve positions to floats, so
  -- the events never route to the root float. The press→cursor-move half of a
  -- click is Neovim core (mouse=nvi) anyway; ours is what happens on release.
  describe("mouse", function()
    local function ButtonApp(on_press)
      return function()
        return {
          comp = ui.col,
          props = {},
          children = {
            { comp = ui.label, props = { text = "title" } },
            { comp = ui.button, props = { label = "OK", on_press = on_press } },
          },
        }
      end
    end

    it("<LeftRelease> activates like <CR>; inert cells do nothing", function()
      local pressed = 0
      local handle = mount.floating(ButtonApp(function()
        pressed = pressed + 1
      end), {}, { width = 10, height = 4 })

      move_cursor(handle, 2, 2) -- where the click's press parked the cursor
      press(handle, "<LeftRelease>")
      assert.equal(1, pressed)

      move_cursor(handle, 1, 2) -- the title row: nothing interactive
      press(handle, "<LeftRelease>")
      assert.equal(1, pressed)

      handle.unmount()
    end)

    it("mouse = false leaves clicks inert", function()
      local pressed = 0
      local handle = mount.floating(ButtonApp(function()
        pressed = pressed + 1
      end), {}, { width = 10, height = 4, mouse = false })

      move_cursor(handle, 2, 2)
      press(handle, "<LeftRelease>")
      assert.equal(0, pressed)

      handle.unmount()
    end)

    -- Which normal-mode buffer-local maps of `bufnr` mention `needle`?
    local function has_map(bufnr, needle)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if m.lhs:lower():find(needle:lower(), 1, true) then
          return true
        end
      end
      return false
    end

    it("follow = true maps <MouseMove> and owns mousemoveevent for the app's lifetime", function()
      assert.is_false(vim.o.mousemoveevent) -- the default we must restore to
      local handle = mount.floating(ButtonApp(nil), {}, { width = 10, height = 4, mouse = { follow = true } })
      assert.is_true(vim.o.mousemoveevent)
      assert.is_true(has_map(handle.bufnr, "MouseMove"))

      handle.unmount()
      assert.is_false(vim.o.mousemoveevent)
    end)

    it("by default there is no <MouseMove> map and mousemoveevent is untouched", function()
      local handle = mount.floating(ButtonApp(nil), {}, { width = 10, height = 4 })
      assert.is_false(vim.o.mousemoveevent)
      assert.is_false(has_map(handle.bufnr, "MouseMove"))
      handle.unmount()
    end)
  end)

  it("interaction autocmds are cleared on unmount", function()
    local function App()
      return { comp = ui.button, props = { label = "OK" } }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 1 })
    handle.unmount()

    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "CursorMoved" })) do
      assert.is_false((au.group_name or ""):find("FibrousInlineInteract", 1, true) ~= nil)
    end
  end)
end)
