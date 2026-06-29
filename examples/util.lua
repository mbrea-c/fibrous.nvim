-- Tiny helpers shared by the examples. Not part of the library — just glue so
-- each demo can wire global keymaps and have them cleaned up on unmount.

local M = {}

-- Attach global keymaps to a live app handle, returning the handle with its
-- `unmount` wrapped so the maps are removed when the example closes. `maps` is a
-- list of { mode, lhs, rhs, opts? }.
---@param handle table
---@param maps table[]
---@return table handle
function M.bind(handle, maps)
  for _, m in ipairs(maps) do
    vim.keymap.set(m[1], m[2], m[3], m[4] or {})
  end
  local orig = handle.unmount
  handle.unmount = function()
    for _, m in ipairs(maps) do
      pcall(vim.keymap.del, m[1], m[2])
    end
    if orig then
      orig()
    end
  end
  return handle
end

return M
