-- Compose a foreground run's highlight with the background FILL it paints
-- over. The canvas keeps ONE hl per cell, so a styled run painted over a
-- fill REPLACES the fill's group — and a fg-only group (a tinted marker, a
-- @markup.* span, a painted border) dropped the fill's background, punching
-- a window-bg hole in the surface. mix() answers the group to paint instead:
-- the run's own group when it carries a background of its own (a button chip
-- on a hover row stays a chip), else a derived group with the run's
-- attributes over the fill's bg. Derivations are cached per (fill, over)
-- pair and re-derived on ColorScheme (a scheme switch clears them and may
-- change either side's resolution).

local M = {}

local decided = {} -- decided[fill][over] -> group name to paint (may be `over`)
local owned = {} -- derived name -> { fill = ..., over = ... }, for re-derivation

---@param name string  the derived group to (re)define
---@param fill string
---@param over string
---@return string paint  the group the caller should paint with
local function derive(name, fill, over)
	local o = vim.api.nvim_get_hl(0, { name = over, link = false })
	if o.bg or o.ctermbg then
		-- the run owns its background: repoint the derived group at it so any
		-- stale extmark from a previous derivation still reads right
		vim.api.nvim_set_hl(0, name, { link = over })
		return over
	end
	local f = vim.api.nvim_get_hl(0, { name = fill, link = false })
	if not (f.bg or f.ctermbg) then
		vim.api.nvim_set_hl(0, name, { link = over })
		return over -- the fill contributes no bg either; nothing to compose
	end
	o.link = nil
	o.bg = f.bg
	o.ctermbg = f.ctermbg
	vim.api.nvim_set_hl(0, name, o)
	return name
end

--- The group to paint run `over` with inside fill `fill`. nil-safe on both
--- sides: no run hl keeps the cell's fill, no fill keeps the run.
---@param fill string|nil  the innermost background fill under the cell
---@param over string|nil  the run's own highlight group
---@return string|nil
function M.mix(fill, over)
	if not over then
		return nil
	end
	if not fill or fill == over then
		return over
	end
	local per = decided[fill]
	if per == nil then
		per = {}
		decided[fill] = per
	end
	local hit = per[over]
	if hit then
		return hit
	end
	local name = ("FibrousMix_" .. fill .. "_" .. over):gsub("[^%w_]", "_")
	owned[name] = { fill = fill, over = over }
	local paint = derive(name, fill, over)
	per[over] = paint
	return paint
end

-- A scheme switch invalidates every decision (either side may have gained or
-- lost a bg) and clears our derived groups; forget the memos and rebuild the
-- groups so extmarks already in buffers keep reading right until repaint.
local function refresh()
	decided = {}
	for name, pair in pairs(owned) do
		derive(name, pair.fill, pair.over)
	end
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("FibrousHlMix", { clear = true }),
	callback = refresh,
})

return M
