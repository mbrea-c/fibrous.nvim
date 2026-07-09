-- Visual-mode selection guard for fibrous canvas buffers (requests.md: "moving
-- the cursor all the way to the right ($) in visual mode scrolls the window one
-- cell to the right"). A canvas line is laid out to the window width; in Visual
-- mode `$` puts the cursor on the trailing NEWLINE — one cell past the last
-- char — which is off-screen for a full-width line, so nvim scrolls one column
-- right to reveal it. fibrous guards canvas buffers with `selection=old` (the
-- cursor can't be positioned past end-of-line), scoped to Visual mode via an
-- idempotent reconciler so the global option never leaks into other buffers.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("visual-mode selection guard", function()
  local orig_selection
  before_each(function()
    orig_selection = vim.go.selection
  end)
  after_each(function()
    feed("<Esc>") -- leave Visual so the reconciler restores
    vim.go.selection = orig_selection
  end)

  -- THE regression guard: if this ever fails, the visual-$ right-scroll is back.
  -- Headless can't sidescroll (memory: headless-no-redraw-scroll), so we assert
  -- the PROXIMATE cause — the cursor column — which IS reliable headless: a
  -- cursor at col > window-width is exactly what forces the one-cell scroll.
  it("Visual $ stays on the last char of a full-width canvas line (no right-scroll)", function()
    local W = 20
    local function App()
      return { comp = ui.label, props = { text = string.rep("x", W) } }
    end
    local handle = mount.floating(App, {}, { width = W, height = 4, mode = "scroll" })
    vim.api.nvim_set_current_win(handle.winid)

    feed("0v$")
    -- 1-indexed: W = last char (on-screen); W+1 = the trailing newline
    -- (off-screen, forces the right-scroll). Must be W.
    local col = vim.fn.col(".")
    feed("<Esc>")
    assert.equal(W, col, "cursor ran onto the off-screen newline — visual-$ right-scroll regressed")
    handle.unmount()
  end)

  -- The same guard must hold INSIDE a container (its own canvas buffer/window),
  -- at every nesting level — the whole reason we could drop the per-container
  -- column reserve.
  it("Visual $ also stays on the last char inside a full-width container", function()
    local W = 20
    local cont_win
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.container,
            props = { grow = 1, scroll_x = false, on_create = function(_, w) cont_win = w end },
            children = { { comp = ui.label, props = { text = string.rep("x", W) } } },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = W, height = 6, mode = "fixed" })
    assert.is_true(type(cont_win) == "number", "container window not created")
    vim.api.nvim_set_current_win(cont_win)

    feed("0v$")
    local col = vim.fn.col(".")
    feed("<Esc>")
    assert.equal(W, col, "container visual-$ ran onto the off-screen newline")
    handle.unmount()
  end)
end)

describe("visual-mode selection reconciler", function()
  local visualsel = require("fibrous.inline.visualsel")
  local orig, base_win
  before_each(function()
    orig = vim.go.selection
    vim.go.selection = "exclusive" -- the user's global (worst case: past-line allowed)
    base_win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    feed("<Esc>")
    visualsel.restore()
    vim.go.selection = orig
    -- drop any extra windows a test opened, back to the base
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= base_win and vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end)

  local function canvas_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 20), string.rep("y", 20) })
    visualsel.mark(buf)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  it("sets selection=old only while Visual in a canvas buffer, then restores", function()
    canvas_buf()
    assert.equal("exclusive", vim.go.selection) -- normal mode: untouched
    feed("v")
    assert.equal("old", vim.go.selection) -- Visual in a canvas → overridden
    feed("l")
    assert.equal("old", vim.go.selection) -- stays while Visual
    feed("<Esc>")
    assert.equal("exclusive", vim.go.selection) -- restored on leaving Visual
  end)

  it("never touches selection in a NON-canvas buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(buf) -- deliberately NOT marked
    feed("v$")
    assert.equal("exclusive", vim.go.selection)
    feed("<Esc>")
    assert.equal("exclusive", vim.go.selection)
  end)

  -- The leak guard: every way in and out of Visual must leave the global back
  -- where the user had it. If a path strands "old", this catches it.
  it("never leaks the global across a matrix of enter/exit paths", function()
    canvas_buf()
    for _, enter in ipairs({ "v", "V", "<C-v>", "v$", "vj" }) do
      for _, exit in ipairs({ "<Esc>", "<C-c>", "y" }) do
        visualsel.restore()
        vim.go.selection = "exclusive"
        feed("gg0" .. enter)
        feed(exit)
        feed("<Esc>") -- guarantee normal mode regardless of the exit
        assert.equal(
          "exclusive",
          vim.go.selection,
          ("selection leaked after enter=%q exit=%q"):format(enter, exit)
        )
      end
    end
  end)

  it("restores when focus moves to a NON-canvas window while Visual (WinEnter)", function()
    -- NB switching windows does NOT exit Visual in nvim (mode stays "v"); the
    -- invariant flips because the CURRENT BUFFER is no longer a canvas, and the
    -- WinEnter reconcile catches it.
    canvas_buf()
    vim.cmd("split")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other, vim.api.nvim_create_buf(false, true)) -- other = non-canvas
    vim.api.nvim_set_current_win(base_win)
    feed("v")
    assert.equal("old", vim.go.selection)
    vim.api.nvim_set_current_win(other) -- focus a non-canvas window
    assert.equal("exclusive", vim.go.selection, "focusing a non-canvas window must restore selection")
  end)

  it("restores when the buffer is switched out from under Visual (BufEnter)", function()
    canvas_buf()
    feed("v")
    assert.equal("old", vim.go.selection)
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain) -- non-canvas: invariant flips false
    assert.equal("exclusive", vim.go.selection)
  end)

  it("restore() is a hard backstop for a teardown mid-selection", function()
    canvas_buf()
    feed("v")
    assert.equal("old", vim.go.selection)
    visualsel.restore() -- simulate unmount/teardown while still in Visual
    assert.equal("exclusive", vim.go.selection)
  end)
end)
