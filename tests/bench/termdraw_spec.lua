-- The terminal-draw harness (fibrous.bench.termdraw) drives a child nvim in a
-- real pty and counts the BYTES it writes to the terminal per redraw — the
-- "one layer down" measure that the buffer-write metric can't see (it counts
-- what fibrous writes to the buffer; this counts what nvim's TUI then pushes at
-- the terminal, highlight repaints and escape overhead included — the real
-- ssh+tmux cost). These pin the mechanism: a moving workload draws bytes, a
-- no-op draws far fewer, and a highlight-only churn (invisible to the buffer
-- metric) still shows up here.

local termdraw = require("fibrous.bench.termdraw")

describe("bench.termdraw", function()
  it("counts terminal bytes: a moving workload draws, a no-op barely does", function()
    local moving = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[
        _G.FRAME = function(i)
          vim.api.nvim_buf_set_lines(0, 0, -1, false, { (tostring(i % 10)):rep(38) })
        end
      ]],
    })
    local static = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[ _G.FRAME = function() end ]],
    })
    assert.is_true(moving.bytes > 0, "a changing line must produce terminal output")
    assert.is_true(moving.frames == 15)
    assert.is_true(static.bytes < moving.bytes, "an idle frame draws less than a moving one")
  end)

  it("sees a highlight-only redraw that the buffer-write metric cannot", function()
    -- No buffer write at all — only a group's colour flips — yet the terminal
    -- repaints the cells using it. This is the flicker the cells/op metric misses.
    local hl = termdraw.measure({
      cols = 40,
      rows = 8,
      frames = 15,
      init = [[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { ("X"):rep(38) })
        vim.api.nvim_set_hl(0, "Grp", { fg = "#00ff00" })
        vim.api.nvim_buf_add_highlight(0, 0, "Grp", 0, 0, -1)
        _G.FRAME = function(i)
          vim.api.nvim_set_hl(0, "Grp", { fg = i % 2 == 0 and "#00ff00" or "#ff0000" })
        end
      ]],
    })
    assert.is_true(hl.bytes > 0, "a highlight-only change still costs terminal draw")
  end)

  it("a still container float adds ~no per-frame draw under an animating sibling", function()
    -- Regression guard for the reposition idempotence fix. A component animating
    -- somewhere in the tree flushes the ROOT every frame; a still container's
    -- float must NOT be reconfigured/re-scrolled (each of those REDRAWS it) — the
    -- ssh+tmux transcript flicker that scaled with transcript size. The guard is
    -- self-calibrating: the SAME 30 static rows, once inline and once inside a
    -- container float, under the SAME moving-dot sibling. The delta is purely the
    -- float's per-frame overhead — it must stay near zero (was ~800 B/frame before
    -- the fix, 0 after). A generous 200 B/frame bound tolerates pty noise while
    -- catching any return of the per-frame float redraw.
    local PRE = [[
      local mount = require("fibrous.inline.mount")
      local ui = require("fibrous.inline.components")
      local function rows(n)
        local k = {}
        for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
        return k
      end
      local set
      local function Dot(ctx) local s = ctx.use_state(0); set = s.set
        local W = 40; local pos = s.get() % W
        return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
    ]]
    local function per_frame(body)
      return termdraw.measure({
        rtp = { vim.fn.getcwd() },
        cols = 60,
        rows = 20,
        frames = 30,
        init = PRE .. body,
      }).per_frame
    end

    -- 30 static rows laid out inline, the dot animating above them
    local inline = per_frame([[
      local function App() return { comp = ui.col, props = {}, children =
        vim.list_extend({ { comp = Dot } }, rows(30)) } end
      mount.floating(App, {}, { width = 50, height = 16 })
      _G.FRAME = function(i) set(i) end
    ]])
    -- the SAME rows inside a container (a subwindow float), same dot above
    local floated = per_frame([[
      local function App() return { comp = ui.col, props = {}, children = {
        { comp = Dot },
        { comp = ui.container, props = { height = 12, scroll_x = false }, children = rows(30) },
      } } end
      mount.floating(App, {}, { width = 50, height = 16 })
      _G.FRAME = function(i) set(i) end
    ]])

    assert.is_true(
      floated - inline < 200,
      ("still container float overhead too high: %.0f B/frame (inline %.0f, floated %.0f)"):format(
        floated - inline,
        inline,
        floated
      )
    )
  end)

  it("a FOCUSED root under continuous animation doesn't redraw per frame from the cursor anchor", function()
    -- Regression guard for the reanchor idempotence fix (requests.md flicker-
    -- frenzy that returns only when the ROOT float is focused — not a
    -- subcontainer). A component animating anywhere flushes the root every
    -- frame; while the root is the live pointer, reanchor runs to hold the
    -- cursor's entry — but if that entry hasn't MOVED it must write NO view
    -- (a winrestview marks the window for redraw, repainting the whole float
    -- = the ssh+tmux flicker). Self-calibrating: the SAME focused scene, cursor
    -- parked on a static row, dot animating above it, once with the anchor on
    -- and once with `anchor = false` (which never reanchors — the floor). The
    -- delta is purely the anchor's per-frame overhead; it must stay near zero.
    local PRE = [[
      local mount = require("fibrous.inline.mount")
      local ui = require("fibrous.inline.components")
      local function rows(n)
        local k = {}
        for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
        return k
      end
      local set
      local function Dot(ctx) local s = ctx.use_state(0); set = s.set
        local W = 40; local pos = s.get() % W
        return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
      local function App() return { comp = ui.col, props = {}, children =
        vim.list_extend({ { comp = Dot } }, rows(30)) } end
    ]]
    local function per_frame(anchor)
      return termdraw.measure({
        rtp = { vim.fn.getcwd() },
        cols = 60,
        rows = 20,
        frames = 30,
        init = PRE .. ([[
          local handle = mount.floating(App, {}, { width = 50, height = 16, mode = "scroll", anchor = %s })
          handle.focus()
          -- park the cursor on a static entry so the anchor pins it; the dot
          -- above animates every frame, flushing the root but never moving row 12
          vim.api.nvim_win_set_cursor(handle.winid, { 12, 0 })
          _G.FRAME = function(i) set(i) end
        ]]):format(tostring(anchor)),
      }).per_frame
    end

    local anchored = per_frame(true)
    local unanchored = per_frame(false)

    assert.is_true(
      anchored - unanchored < 200,
      ("focused-root anchor overhead too high: %.0f B/frame (anchored %.0f, unanchored %.0f)"):format(
        anchored - unanchored,
        anchored,
        unanchored
      )
    )
  end)

  it("hjkl over a container mirror draws ~nothing extra per keystroke", function()
    -- Regression guard for the requests.md full-redraw bug, motion half: with
    -- the root focused, each CursorMoved over a container's mirror drove hover
    -- by WRITING the container float's cursor — and a cursor write into a float
    -- recomposites it whole (~800 B per j/k on a transcript-sized float). Hover
    -- is now driven as data (interact.update_at); the float's cursor is never
    -- touched. Self-calibrating: the SAME ten j's, once over plain inline rows
    -- (the floor — pure cursor-move cost) and once over a container's mirror.
    local PRE = [[
      local mount = require("fibrous.inline.mount")
      local ui = require("fibrous.inline.components")
      local function rows(n)
        local k = {}
        for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
        return k
      end
    ]]
    local function per_key(body)
      local res = termdraw.drive({
        rtp = { vim.fn.getcwd() },
        cols = 60,
        rows = 20,
        init = PRE .. body,
        steps = { { label = "keys", send = ("j"):rep(10), wait_ms = 1200 } },
      })
      return res.steps[1].bytes / 10
    end

    local inline = per_key([[
      local function App() return { comp = ui.col, props = {}, children = rows(16) } end
      local handle = mount.floating(App, {}, { width = 50, height = 16, mode = "scroll" })
      handle.focus()
      vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 })
    ]])
    local mirrored = per_key([[
      local function App() return { comp = ui.col, props = {}, children = {
        { comp = ui.label, props = { text = "header" } },
        { comp = ui.container, props = { height = 14, scroll_x = false }, children = rows(30) },
      } } end
      local handle = mount.floating(App, {}, { width = 50, height = 16, mode = "scroll" })
      handle.focus()
      vim.api.nvim_win_set_cursor(handle.winid, { 3, 0 })
    ]])

    assert.is_true(
      mirrored - inline < 200,
      ("hjkl over a mirror costs too much: %.0f B/keystroke (inline %.0f, mirrored %.0f)"):format(
        mirrored - inline,
        inline,
        mirrored
      )
    )
  end)

  it("streaming into a container stays append-only under a parked cursor", function()
    -- The streaming half of the same bug: each appended row re-mirrored EVERY
    -- box row via set_text, and rewriting the line the current window's cursor
    -- sits on — in the same tick the covering float changes — makes nvim
    -- recomposite the whole float (~950 B/append with the cursor parked over
    -- the transcript, vs ~100 append-only). The mirror repaint is now
    -- row-diffed. Self-calibrating: the SAME streaming scene, cursor parked
    -- once on the mirror and once on the header row above it (the floor).
    local PRE = [[
      local mount = require("fibrous.inline.mount")
      local ui = require("fibrous.inline.components")
      local function rows(n)
        local k = {}
        for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
        return k
      end
      local set
      local function App(ctx)
        local st = ctx.use_state(3)
        set = st.set
        return { comp = ui.col, props = {}, children = {
          { comp = ui.label, props = { text = "header" } },
          { comp = ui.container, props = { height = 16, scroll_x = false }, children = rows(st.get()) },
        } }
      end
    ]]
    local function per_append(cur_row)
      local res = termdraw.drive({
        rtp = { vim.fn.getcwd() },
        cols = 60,
        rows = 24,
        init = PRE .. ([[
          local handle = mount.floating(App, {}, { width = 50, height = 20, mode = "scroll" })
          handle.focus()
          vim.api.nvim_win_set_cursor(handle.winid, { %d, 0 })
          local n = 3
          local t = vim.uv.new_timer()
          t:start(200, 80, vim.schedule_wrap(function()
            n = n + 1
            set(n)
            if n >= 13 then t:stop() end
          end))
        ]]):format(cur_row),
        steps = { { label = "stream", wait_ms = 1800 } },
      })
      return res.steps[1].bytes / 10
    end

    local parked_off = per_append(1) -- header row: cursor line never re-mirrored
    local parked_on = per_append(3) -- over the mirror: the bug's posture

    assert.is_true(
      parked_on - parked_off < 200,
      ("streaming under a parked cursor costs too much: %.0f B/append (off-mirror %.0f, on-mirror %.0f)"):format(
        parked_on - parked_off,
        parked_off,
        parked_on
      )
    )
  end)

  it("an UNFOCUSED surface holds its view without redrawing per frame", function()
    -- The companion guard for unfocused anchoring (requests.md: "if transcript
    -- is not focused, there's no anchoring … we should still anchor buffers that
    -- aren't focused"). An unfocused scroll surface pins its view (topline) across
    -- relayout, but an animating leaf inside it must NOT trigger a winrestview per
    -- frame — that would invalidate and repaint the whole float (the flicker).
    -- Self-calibrating: same unfocused, scrolled scene, dot animating on-screen,
    -- once with the anchor on and once with `anchor = false` (the floor).
    local PRE = [[
      local mount = require("fibrous.inline.mount")
      local ui = require("fibrous.inline.components")
      local function rows(n)
        local k = {}
        for i = 1, n do k[i] = { comp = ui.label, props = { text = ("static row %d — lorem ipsum"):format(i) } } end
        return k
      end
      local W = 40
      local set
      local function Dot(ctx) local s = ctx.use_state(0); set = s.set
        local pos = s.get() % W
        return { comp = ui.label, props = { text = ("."):rep(pos) .. "o" .. ("."):rep(W - 1 - pos) } } end
      local function App() return { comp = ui.col, props = {}, children =
        vim.list_extend(rows(30), { { comp = Dot } }) } end
    ]]
    local function per_frame(anchor)
      return termdraw.measure({
        rtp = { vim.fn.getcwd() },
        cols = 60,
        rows = 20,
        frames = 30,
        init = PRE .. ([[
          -- mount but DO NOT focus: the original window stays current, so the
          -- surface is UNFOCUSED. Scroll it so a static row sits at the top, the
          -- dot animating on-screen near the bottom; capture on WinScrolled.
          local handle = mount.floating(App, {}, { width = 50, height = 8, mode = "scroll", anchor = %s })
          vim.api.nvim_win_call(handle.winid, function() vim.fn.winrestview({ topline = 24 }) end)
          vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(handle.winid) })
          _G.FRAME = function(i) set(i) end
        ]]):format(tostring(anchor)),
      }).per_frame
    end

    local anchored = per_frame(true)
    local unanchored = per_frame(false)

    assert.is_true(
      anchored - unanchored < 200,
      ("unfocused anchor overhead too high: %.0f B/frame (anchored %.0f, unanchored %.0f)"):format(
        anchored - unanchored,
        anchored,
        unanchored
      )
    )
  end)
end)
