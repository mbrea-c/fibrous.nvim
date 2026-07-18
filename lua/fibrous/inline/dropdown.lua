-- Pure state helpers for ui.dropdown (see components.lua). The component owns
-- the reactive state and the buffer wiring; everything decidable from plain
-- values lives here, testable without a mount.

local M = {}

-- Filter `options` against the typed text: empty text shows everything (the
-- freshly-focused dropdown), otherwise fuzzy-matched best-first. The default
-- for the component's `filter` prop.
---@param options string[]
---@param text string
---@return string[]
function M.filter(options, text)
  if text == "" then
    return vim.list_slice(options)
  end
  return vim.fn.matchfuzzy(options, text)
end

-- First visible row of the popup's window over `n` filtered options: top-
-- anchored until the selection walks past `max` rows, then slides just far
-- enough to keep the selection on the last visible row (the selection is
-- always in view, so the popup never needs internal scroll).
---@param n integer
---@param sel integer
---@param max integer
---@return integer lo 1-based
function M.window(n, sel, max)
  if n <= max or sel <= max then
    return 1
  end
  return math.min(sel - max + 1, n - max + 1)
end

-- The value an unfocus commits: the selected option when the popup is open
-- (`chosen`); otherwise the typed text survives only under free_text, or when
-- it exactly names an option anyway. nil = revert to the last committed value
-- (strict select, the default).
---@param typed string
---@param chosen string|nil
---@param free_text boolean|nil
---@param options string[]|nil
---@return string|nil
function M.blur_value(typed, chosen, free_text, options)
  if chosen then
    return chosen
  end
  if free_text then
    return typed
  end
  for _, o in ipairs(options or {}) do
    if o == typed then
      return typed
    end
  end
  return nil
end

---@param list string[]
---@param v string
---@return integer|nil
function M.index_of(list, v)
  for i, o in ipairs(list) do
    if o == v then
      return i
    end
  end
  return nil
end

return M
