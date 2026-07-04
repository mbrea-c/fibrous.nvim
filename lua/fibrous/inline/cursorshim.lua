-- The guicursor shim. nvim renders an OBSCURED cursor — one whose screen
-- cell is covered by a higher-zindex float — with the REPLACE-mode guicursor
-- entry: ui_flush() substitutes mode_change("replace") when
-- ui_cursor_is_behind_floatwin() (src/nvim/ui.c), and the default r entry is
-- hor20, an underscore. render="always" subwindows put the gliding root
-- cursor in exactly that state, so while any such widget is live we append
-- ",r-cr:block": the glide cursor stays a normal block, and the text mirror
-- guarantees the character under it is the real one.
--
-- Contract (kept deliberately conservative — this is a GLOBAL user option):
--   * refcounted: many mounts/widgets share one appended suffix, lifted when
--     the last holder releases;
--   * guicursor == "" means the user disabled cursor shaping entirely —
--     acquire is inert, we never switch shaping on for them;
--   * release restores the saved value ONLY if guicursor still is exactly
--     what we set; any change made while held (user, plugin) wins;
--   * cost while held: real replace/cmdline-replace mode shows a block
--     instead of the user's r shape. Rare, cosmetic, documented.

local M = {}

local SUFFIX = ",r-cr:block"

local count = 0
local saved, applied = nil, nil

function M.acquire()
  count = count + 1
  if count > 1 or applied ~= nil then
    return
  end
  local cur = vim.o.guicursor
  if cur == "" then
    return -- shaping disabled; stay inert (count still tracks the hold)
  end
  saved = cur
  applied = cur .. SUFFIX
  vim.o.guicursor = applied
end

function M.release()
  if count == 0 then
    return
  end
  count = count - 1
  if count > 0 then
    return
  end
  if applied and vim.o.guicursor == applied then
    vim.o.guicursor = saved
  end
  saved, applied = nil, nil
end

return M
