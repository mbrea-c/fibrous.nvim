-- Visual-mode selection guard for fibrous canvas buffers.
--
-- A canvas line is laid out to exactly the window width. In Visual mode `$`
-- (and l / <End> / …) put the cursor ON the trailing newline — one cell PAST the
-- last character — and for a full-width line that cell is off-screen, so nvim
-- scrolls one column right to reveal it (the requests.md visual-$ bug). A leftcol
-- pin can't win that fight: the cursor genuinely needs the off-screen column, so
-- a reset just re-scrolls.
--
-- The cure is `selection=old` ("the cursor cannot be positioned past the end of
-- the line"), which keeps the cursor on the last char (on-screen) — for EVERY
-- visual motion, not just `$`. But `selection` is a GLOBAL option (it cannot be
-- made buffer/window-local — nvim rejects a buf/win scope outright), so it must
-- be set ONLY while it matters and never leak into the user's other buffers.
--
-- So rather than a fragile set-here / restore-there pair (miss the restore once
-- and the global is stranded), we maintain an INVARIANT with an idempotent
-- reconciler:
--
--   selection == "old"  <=>  (mode is Visual/Select AND the current buffer is a
--                             fibrous canvas)
--
-- The invariant depends on BOTH the mode and the buffer, so it is reconciled on
-- both mode transitions (ModeChanged) and focus/buffer transitions
-- (Win/BufEnter/Leave). Every relevant event re-derives the correct state, so a
-- single missed event self-heals on the next one — the override can't get
-- stranded. VimLeavePre is the final backstop.

local M = {}

-- The user's `selection` while we are overriding it; nil when we are not — so we
-- only ever SAVE from the user's own value and RESTORE to it, never to "old".
local saved = nil

local function is_visual(mode)
  -- charwise/linewise/blockwise Visual (v V ^V) + the Select-mode trio (s S ^S)
  return mode:sub(1, 1):match("[vV\22sS\19]") ~= nil
end

local function reconcile()
  local buf = vim.api.nvim_get_current_buf()
  local want_old = is_visual(vim.api.nvim_get_mode().mode) and vim.b[buf].fibrous_canvas == true
  if want_old and saved == nil then
    saved = vim.go.selection
    vim.go.selection = "old"
  elseif not want_old and saved ~= nil then
    vim.go.selection = saved
    saved = nil
  end
end

local registered = false
local function ensure_registered()
  if registered then
    return
  end
  registered = true
  local group = vim.api.nvim_create_augroup("FibrousVisualSelection", { clear = true })
  vim.api.nvim_create_autocmd({ "ModeChanged", "WinEnter", "WinLeave", "BufEnter", "BufLeave" }, {
    group = group,
    callback = reconcile,
  })
  -- Never carry the override out of the session.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.restore()
    end,
  })
end

-- Flag `bufnr` as a fibrous canvas so the reconciler guards Visual mode in it.
-- Idempotent; lazily wires the (single, session-wide) reconciler autocmds.
---@param bufnr integer
function M.mark(bufnr)
  ensure_registered()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].fibrous_canvas = true
  end
end

-- Force the invariant back to "not overriding" (restores the user's selection if
-- we currently hold it). Idempotent — a teardown / test backstop.
function M.restore()
  if saved ~= nil then
    vim.go.selection = saved
    saved = nil
  end
end

return M
