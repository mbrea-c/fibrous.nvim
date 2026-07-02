-- The subwindow manager (tracker "NEW UI HOST" task 4, decision: clipping
-- first). Subwindow leaves (text_input for now; raw_buffer in task 7) are laid
-- out inline like everything else — their border/background even paint in the
-- root buffer — but their CONTENT box is covered by a real, editable float
-- anchored to the root float, so the user gets a native buffer to type into.
--
-- Because relative="win" floats anchor to the window grid, not its scrolled
-- content, the manager subtracts the root's topline offset itself and resyncs
-- on WinScrolled. Occlusion (tracker decision, clipping strategy):
--   partial  — resize the float to its visible rows and re-anchor its own
--              viewport (topline) so the right slice of content shows;
--   full     — hide the float (nvim_win_set_config hide).
-- Known accepted artifact: WinScrolled fires post-redraw, so floats trail the
-- scroll by one frame ("swim"); evaluating that is the point of this spike.

local M = {}

---@class SubwinManager
---@field sync fun()      reconcile floats against host.subwins and reposition them
---@field teardown fun()  destroy all floats/buffers and the autocmds

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
  ---@type table<table, { bufnr: integer, winid: integer, node: table }>
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
    -- must stay visible); fine while unfocused — focus semantics are task 7.
    local clipped = vis_top - y0
    vim.api.nvim_win_call(entry.winid, function()
      vim.fn.winrestview({ topline = clipped + 1, lnum = clipped + 1, col = 0, leftcol = 0 })
    end)
  end

  local function destroy(entry)
    if vim.api.nvim_win_is_valid(entry.winid) then
      pcall(vim.api.nvim_win_close, entry.winid, true)
    end
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
    end
  end

  -- Reconcile floats against the host's last flush: create for new subwindow
  -- leaves (seeding props.value once — the buffer is the source of truth
  -- after), reposition everything, destroy floats whose leaf is gone.
  local function sync()
    local seen = {}
    for _, node in ipairs(host.subwins or {}) do
      local inst = node.fiber and node.fiber.instance
      if inst then
        seen[inst] = true
        local entry = floats[inst]
        if not entry then
          local bufnr = vim.api.nvim_create_buf(false, true)
          local value = (node.props or {}).value
          if value and value ~= "" then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(value, "\n", { plain = true }))
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
          vim.wo[winid].wrap = false
          entry = { bufnr = bufnr, winid = winid, node = node }
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

  return {
    sync = sync,
    teardown = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      for _, entry in pairs(floats) do
        destroy(entry)
      end
      floats = {}
    end,
  }
end

return M
