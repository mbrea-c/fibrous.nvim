-- The subwindow manager (tracker "NEW UI HOST" tasks 4 + 7). Subwindow leaves
-- (text_input, raw_buffer) are laid out inline like everything else — their
-- border/background even paint in the root buffer — but their CONTENT box is
-- covered by a real float anchored to the root float, so the user gets a
-- native buffer to type into (text_input: an owned scratch buffer seeded from
-- props.value; raw_buffer: a caller-provided, UNOWNED props.bufnr, or an owned
-- scratch one without it).
--
-- Because relative="win" floats anchor to the window grid, not its scrolled
-- content, the manager subtracts the root's topline offset itself and resyncs
-- on WinScrolled. Occlusion (tracker decision, clipping strategy; the 4b eval
-- verdict: no visible swim, clipping stays):
--   partial  — resize the float to its visible rows and re-anchor its own
--              viewport (topline) so the right slice of content shows;
--   full     — hide the float (nvim_win_set_config hide).
--
-- Focus traversal (task 7): native cursor motions are the primary navigation.
--   in   moving the root cursor into a subwindow's content box focuses its
--        float at the corresponding cell (CursorMoved on the root buffer);
--   out  h/j/k/l at the float buffer's edge step into the root buffer adjacent
--        to the widget (keeping the cursor's row/col alignment); <C-w>-h/j/k/l
--        exit unconditionally; <C-d>/<C-u> always hand focus AND the motion to
--        the root — page motions are never trapped. Exits whose target falls
--        outside the root buffer are no-ops (staying put beats the root
--        clamping the cursor straight back into the widget).
--
-- text_input wiring: buffer edits report through props.on_change(value)
-- (TextChanged/TextChangedI); <CR> — normal or insert mode — calls
-- props.on_submit(value) when given, otherwise insert-mode <CR> falls through
-- to a plain newline. Handlers are read from the latest committed props at
-- fire time.

local width = require("fibrous.inline.width")

local M = {}

---@class SubwinManager
---@field sync fun()      reconcile floats against host.subwins and reposition them
---@field teardown fun()  destroy all floats/buffers and the autocmds

---@param bufnr integer
---@return string
local function buf_value(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Attach a manager to `host` (an InlineHost) whose buffer is shown in the
-- root float `root_winid`. The mount target calls this once, wires
-- `host.on_flush` to `sync`, and calls `teardown` on unmount.
---@param host InlineHost
---@param root_winid integer
---@return SubwinManager
function M.attach(host, root_winid)
  local group = vim.api.nvim_create_augroup("FibrousInlineSubwin_" .. root_winid, { clear = true })

  -- One float per live subwindow leaf, keyed by the fiber's host instance
  -- (stable across commits — the reconciler reuses it when the type matches).
  ---@type table<table, { bufnr: integer, winid: integer, node: table, owned: boolean, maps: table[] }>
  local floats = {}

  -- Place `entry`'s float over the visible slice of its content box, given the
  -- root's current scroll position.
  local function reposition(entry)
    if not (vim.api.nvim_win_is_valid(root_winid) and vim.api.nvim_win_is_valid(entry.winid)) then
      return
    end
    local c = entry.node.content
    local top_off = vim.fn.line("w0", root_winid) - 1
    local view_h = vim.api.nvim_win_get_height(root_winid)
    local y0 = c.y - top_off
    local y1 = y0 + c.h - 1
    local vis_top, vis_bot = math.max(y0, 0), math.min(y1, view_h - 1)

    if vis_bot < vis_top or c.w <= 0 then
      vim.api.nvim_win_set_config(entry.winid, { hide = true })
      return
    end

    vim.api.nvim_win_set_config(entry.winid, {
      relative = "win",
      win = root_winid,
      row = vis_top,
      col = c.x,
      width = c.w,
      height = vis_bot - vis_top + 1,
      hide = false,
    })
    -- Clipped at the top: scroll the float's own viewport so the slice below
    -- the occlusion edge is what shows. The cursor is dragged along (topline
    -- must stay visible) — but NEVER while the float is focused: a resync in
    -- the middle of typing (on_change → re-render → flush → here) would yank
    -- the cursor to col 0 between keystrokes.
    if entry.winid ~= vim.api.nvim_get_current_win() then
      local clipped = vis_top - y0
      vim.api.nvim_win_call(entry.winid, function()
        vim.fn.winrestview({ topline = clipped + 1, lnum = clipped + 1, col = 0, leftcol = 0 })
      end)
    end
  end

  -- Move the root cursor to buffer cell (row, x) [0-indexed] and focus the
  -- root. No-op when the target is outside the root buffer — an edge motion
  -- with nowhere to go stays put rather than letting the root clamp the
  -- cursor back inside the widget (which would immediately re-enter it).
  local function exit_to(row, x)
    if not vim.api.nvim_win_is_valid(root_winid) then
      return
    end
    if row < 0 or x < 0 or row >= vim.api.nvim_buf_line_count(host.bufnr) then
      return
    end
    local line = vim.api.nvim_buf_get_lines(host.bufnr, row, row + 1, false)[1] or ""
    if x >= width.str(line) then
      return
    end
    vim.api.nvim_set_current_win(root_winid)
    vim.api.nvim_win_set_cursor(root_winid, { row + 1, width.cell_to_byte(line, x) })
  end

  -- Focus `entry`'s float, placing its cursor at root-buffer cell (row, x)
  -- translated into the float's content (clamped to its lines).
  local function enter(entry, row, x)
    if not vim.api.nvim_win_is_valid(entry.winid) then
      return
    end
    local c = entry.node.content
    local lnum = math.min(math.max(row - c.y + 1, 1), vim.api.nvim_buf_line_count(entry.bufnr))
    local line = vim.api.nvim_buf_get_lines(entry.bufnr, lnum - 1, lnum, false)[1] or ""
    vim.api.nvim_set_current_win(entry.winid)
    vim.api.nvim_win_set_cursor(entry.winid, { lnum, width.cell_to_byte(line, math.max(x - c.x, 0)) })
  end

  -- The float cursor's (pos, display cell) — cells because the root target of
  -- a vertical exit must keep the cursor's visual column, not its byte one.
  local function float_cursor(entry)
    local pos = vim.api.nvim_win_get_cursor(entry.winid)
    local line = vim.api.nvim_buf_get_lines(entry.bufnr, pos[1] - 1, pos[1], false)[1] or ""
    return pos, width.str(line:sub(1, pos[2]))
  end

  -- Is the float cursor at the buffer edge `dir` would cross?
  local function at_edge(entry, dir)
    local pos = vim.api.nvim_win_get_cursor(entry.winid)
    if dir == "k" then
      return pos[1] == 1
    elseif dir == "j" then
      return pos[1] == vim.api.nvim_buf_line_count(entry.bufnr)
    elseif dir == "h" then
      return pos[2] == 0
    end
    return vim.api.nvim_win_call(entry.winid, function()
      return vim.fn.charcol(".") >= vim.fn.strchars(vim.fn.getline("."))
    end)
  end

  -- Step out of the float in direction `dir`, one cell past the CONTENT box:
  -- with a border that is the border cell itself — symmetric with entry, where
  -- the root cursor crosses the border one keypress at a time. Vertical exits
  -- keep the column, horizontal exits keep the row.
  local function exit_dir(entry, dir)
    local pos, cell = float_cursor(entry)
    local c = entry.node.content
    if dir == "k" then
      exit_to(c.y - 1, c.x + cell)
    elseif dir == "j" then
      exit_to(c.y + c.h, c.x + cell)
    elseif dir == "h" then
      exit_to(c.y + (pos[1] - 1), c.x - 1)
    else
      exit_to(c.y + (pos[1] - 1), c.x + c.w)
    end
  end

  -- Buffer-local traversal maps. A raw_buffer's buffer may be shown in other
  -- windows too, so every callback falls back to the native motion unless the
  -- float itself is the current window.
  local function map_motions(entry)
    local function map(modes, lhs, fn)
      vim.keymap.set(modes, lhs, fn, { buffer = entry.bufnr, nowait = true, desc = "fibrous: subwin traversal" })
      for _, mode in ipairs(type(modes) == "table" and modes or { modes }) do
        entry.maps[#entry.maps + 1] = { mode, lhs }
      end
    end
    entry.map = map

    for _, key in ipairs({ "h", "j", "k", "l" }) do
      map("n", key, function()
        if vim.api.nvim_get_current_win() == entry.winid and at_edge(entry, key) then
          exit_dir(entry, key)
        else
          vim.cmd("normal! " .. vim.v.count1 .. key)
        end
      end)
      map("n", "<C-w>" .. key, function()
        if vim.api.nvim_get_current_win() == entry.winid then
          exit_dir(entry, key)
        else
          vim.cmd(vim.v.count1 .. "wincmd " .. key)
        end
      end)
    end
    for _, key in ipairs({ "<C-d>", "<C-u>" }) do
      map("n", key, function()
        if vim.api.nvim_get_current_win() == entry.winid and vim.api.nvim_win_is_valid(root_winid) then
          vim.api.nvim_set_current_win(root_winid)
        end
        vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(key, true, false, true))
      end)
    end
  end

  -- text_input change/submit wiring. Handlers come off entry.node.props at
  -- fire time — sync() refreshes entry.node every flush, so this is always
  -- the latest committed component.
  --
  -- Change detection is nvim_buf_attach, not TextChanged/TextChangedI: those
  -- are main-loop events that never fire while a feedkeys batch is being
  -- processed. on_lines runs under textlock, so the handler (which typically
  -- re-renders, writing the host buffer) is deferred to the main loop,
  -- coalesced so a burst of edits reports once, with the final value.
  local function wire_input(entry)
    local pending = false
    vim.api.nvim_buf_attach(entry.bufnr, false, {
      on_lines = function()
        if entry.dead then
          return true -- detach
        end
        if pending then
          return
        end
        pending = true
        vim.schedule(function()
          pending = false
          if entry.dead or not vim.api.nvim_buf_is_valid(entry.bufnr) then
            return
          end
          local props = entry.node.props or {}
          if props.on_change then
            props.on_change(buf_value(entry.bufnr))
          end
        end)
      end,
    })
    entry.map({ "n", "i" }, "<CR>", function()
      local props = entry.node.props or {}
      if props.on_submit then
        props.on_submit(buf_value(entry.bufnr))
      elseif vim.api.nvim_get_mode().mode:find("i") then
        -- No submit handler: a plain newline. "i" puts it BEFORE whatever is
        -- still in the typeahead, "n" (noremap) keeps it from recursing here.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
      end
    end)
  end

  -- Focus styling ("Style rework" S2): the float gaining/losing the cursor
  -- applies the node's `_focus` style override through host state + relayout
  -- (focus changes are rare — always the structural path, no fast path).
  local function set_focus(entry, on)
    local node = entry.node
    if entry.dead or not node.fiber or not (node.style and node.style.focus) then
      return
    end
    host.set_state(node.fiber, "focus", on)
    host.relayout()
  end

  -- WinEnter/WinLeave fire for any window showing the buffer (a raw_buffer's
  -- may be open elsewhere), so both check that OUR float is the one involved.
  local function wire_focus(entry)
    vim.api.nvim_create_autocmd("WinEnter", {
      group = group,
      buffer = entry.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() == entry.winid then
          set_focus(entry, true)
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = entry.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() == entry.winid then
          set_focus(entry, false)
        end
      end,
    })
  end

  local function create(node)
    local props = node.props or {}
    local bufnr, owned
    if node.subwin == "raw_buffer" and props.bufnr then
      bufnr, owned = props.bufnr, false
    else
      bufnr, owned = vim.api.nvim_create_buf(false, true), true
      if node.subwin == "text_input" and props.value and props.value ~= "" then
        -- seeded once — the buffer is the source of truth after
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(props.value, "\n", { plain = true }))
      end
    end
    local winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "win",
      win = root_winid,
      row = 0,
      col = 0,
      width = math.max(node.content.w, 1),
      height = math.max(node.content.h, 1),
      style = "minimal",
      zindex = 60, -- above the root float's 50
      hide = true, -- reposition below decides visibility
    })
    -- text_input never wraps (rect math); raw_buffer is the native-wrapping
    -- escape hatch and wraps unless told not to.
    vim.wo[winid].wrap = node.subwin == "raw_buffer" and props.wrap ~= false

    local entry = { bufnr = bufnr, winid = winid, node = node, owned = owned, maps = {} }
    map_motions(entry)
    wire_focus(entry)
    if node.subwin == "text_input" then
      wire_input(entry)
    end
    return entry
  end

  local function destroy(entry)
    entry.dead = true -- detaches the on_lines watcher on its next callback
    if vim.api.nvim_win_is_valid(entry.winid) then
      pcall(vim.api.nvim_win_close, entry.winid, true)
    end
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then
      return
    end
    if entry.owned then
      pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
    else
      -- unowned (caller's raw_buffer): leave the buffer alive, take only our
      -- keymaps and autocmds off it
      for _, m in ipairs(entry.maps) do
        pcall(vim.keymap.del, m[1], m[2], { buffer = entry.bufnr })
      end
      pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = entry.bufnr })
    end
  end

  -- Reconcile floats against the host's last flush: create for new subwindow
  -- leaves, reposition everything, destroy floats whose leaf is gone.
  local function sync()
    local seen = {}
    for _, node in ipairs(host.subwins or {}) do
      local inst = node.fiber and node.fiber.instance
      if inst then
        seen[inst] = true
        local entry = floats[inst]
        if not entry then
          entry = create(node)
          floats[inst] = entry
        end
        entry.node = node
        reposition(entry)
      end
    end
    for inst, entry in pairs(floats) do
      if not seen[inst] then
        destroy(entry)
        floats[inst] = nil
      end
    end
  end

  -- Live scroll resync. Deliberately synchronous and uncoalesced — WinScrolled
  -- already fires at most once per redraw, and any deferral widens the swim.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    pattern = tostring(root_winid),
    callback = sync,
  })

  -- A user :q on a subwindow float kills the whole app, exactly like :q on
  -- the root — a lone widget window closing has no sensible half-open state.
  -- Closing the ROOT float cascades into the mount target's teardown; our own
  -- destroys set entry.dead before closing, so they don't rebound here.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      for _, entry in pairs(floats) do
        if entry.winid == closed and not entry.dead then
          -- deferred: windows can't be closed from inside WinClosed
          vim.schedule(function()
            if vim.api.nvim_win_is_valid(root_winid) then
              pcall(vim.api.nvim_win_close, root_winid, true)
            end
          end)
          return
        end
      end
    end,
  })

  -- Traversal IN: the root cursor landing inside a subwindow's content box
  -- focuses its float at that cell. `nested`: the window switch happens from
  -- inside this autocmd, and the WinEnter it fires is what applies the _focus
  -- style — without nesting it would be silently swallowed.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = host.bufnr,
    nested = true,
    callback = function()
      if vim.api.nvim_get_current_win() ~= root_winid then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(root_winid)
      local row = pos[1] - 1
      local line = vim.api.nvim_buf_get_lines(host.bufnr, row, row + 1, false)[1] or ""
      local x = width.str(line:sub(1, pos[2])) -- byte col → display cell
      for _, entry in pairs(floats) do
        local c = entry.node.content
        if row >= c.y and row < c.y + c.h and x >= c.x and x < c.x + c.w then
          enter(entry, row, x)
          return
        end
      end
    end,
  })

  return {
    sync = sync,
    teardown = function()
      for _, entry in pairs(floats) do
        destroy(entry) -- before the augroup goes: destroy clears per-buffer autocmds through it
      end
      floats = {}
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  }
end

return M
