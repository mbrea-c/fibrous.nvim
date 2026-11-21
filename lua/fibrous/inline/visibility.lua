-- Experimental content_visibility="auto" for an append-ordered vertical list.
-- Offscreen items reserve native buffer rows. Only the viewport band has fibers,
-- cell grids, highlight marks and source geometry. Coordinates here are 0-based rows.
local Layout = require("fibrous.inline.layout")
local Render = require("fibrous.inline.render")
-- LuaJIT uses global unpack; Lua 5.2+ provides table.unpack instead.
---@diagnostic disable-next-line: deprecated
local unpack_anchor = table.unpack or unpack
---@class InlineVisibility
---@field estimate integer
---@field gap integer
---@field overscan? integer
---@field count integer
---@field first integer
---@field last integer
---@field heights table<integer, integer>
---@field sums table<integer, integer>
---@field top integer
---@field height integer
---@field tail boolean
---@field win? integer
---@field group? integer
---@field pending? boolean
---@field revision any
---@field saved_anchor? integer[]
---@field notify? fun()
local M = {}
M.__index = M

---@param opts? { estimate?: integer, gap?: integer, overscan?: integer, tail?: boolean }
---@return InlineVisibility
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({
		estimate = opts.estimate or 3,
		gap = opts.gap or 0,
		overscan = opts.overscan,
		height = 24,
		top = 0,
		tail = opts.tail == true,
		count = 0,
		heights = {},
		sums = {},
	}, M)
	assert(
		self.estimate >= 1
			and self.estimate % 1 == 0
			and self.gap >= 0
			and self.gap % 1 == 0
			and (not self.overscan or self.overscan >= 1 and self.overscan % 1 == 0),
		"invalid viewport geometry"
	)
	return self
end

-- Sparse Fenwick tree of corrections to estimated heights. Appending an item
-- never reallocates an index proportional to the length of the transcript.
function M:measure(i, height)
	assert(i >= 1 and i <= 2 ^ 30 and i % 1 == 0, "invalid canonical item index")
	assert(height >= 0 and height % 1 == 0, "invalid item height")
	local stride = height > 0 and height + self.gap or 0
	local prior = self.heights[i] or self.estimate + self.gap
	if stride == prior then
		return
	end
	self.heights[i] = stride
	local delta = stride - prior
	while i <= 2 ^ 30 do
		self.sums[i] = (self.sums[i] or 0) + delta
		i = i + bit.band(i, -i)
	end
end

function M:offset(n)
	assert(n >= 0 and n <= 2 ^ 30 and n % 1 == 0, "invalid canonical item count")
	local sum = n * (self.estimate + self.gap)
	while n > 0 do
		sum = sum + (self.sums[n] or 0)
		n = n - bit.band(n, -n)
	end
	return sum
end

function M:item(row)
	local lo, hi = 1, self.count
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if self:offset(mid) <= row then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

-- Filtering can make a previously zero-height item visible. Carry the current
-- semantic anchor across the change, and lazily remeasure the new population.
function M:invalidate()
	if self.win and vim.api.nvim_win_is_valid(self.win) and self.count > 0 then
		local view = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
		local top, cursor = self:item(view.topline - 1), self:item(view.lnum - 1)
		self.saved_anchor =
			{ top, view.topline - 1 - self:offset(top - 1), cursor, view.lnum - 1 - self:offset(cursor - 1) }
		self.top = (top - 1) * (self.estimate + self.gap)
	end
	self.heights, self.sums = {}, {}
end

function M:range(count)
	assert(count >= 0 and count <= 2 ^ 30 and count % 1 == 0, "invalid item count")
	self.count = count
	local total = math.max(0, self:offset(count) - self.gap)
	local top = self.tail and math.max(0, total - self.height) or math.min(self.top, math.max(0, total - 1))
	local pad = self.overscan or (2 * self.height)
	local first = self:item(math.max(0, top - pad))
	local last = count == 0 and 0 or self:item(top + self.height + pad - 1)
	self.first, self.last = first, last
	return first, last
end

function M:refresh()
	if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
		return
	end
	local view = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
	local height = vim.api.nvim_win_get_height(self.win)
	local total = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(self.win))
	self.top, self.height, self.tail = view.topline - 1, height, view.topline + height - 1 >= total
	local guard = self.overscan and math.floor(self.overscan / 2) or height
	local lo = self:item(math.max(0, self.top - guard))
	local hi = self:item(self.top + height + guard - 1)
	if self.count > 0 and self.notify and (lo < self.first or hi > self.last) then
		self.notify()
	end
end

-- Materialize a canonical item before callers resolve its source locations.
---@param index integer  one-based canonical item index
function M:reveal(index)
	if not self.win or index < 1 or index > self.count then
		return
	end
	local row = math.min(self:offset(index - 1) + 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(self.win)))
	vim.api.nvim_win_call(self.win, function()
		vim.fn.winrestview({ lnum = row, topline = row, col = 0 })
	end)
	self:refresh()
end

function M:schedule()
	if self.pending or not self.win then
		return
	end
	self.pending = true
	vim.schedule(function()
		self.pending = false
		self:refresh()
	end)
end

function M:bind(win)
	self.win = win
	self.group = vim.api.nvim_create_augroup("FibrousVisibility" .. win, { clear = true })
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = self.group,
		pattern = tostring(win),
		callback = function()
			self:refresh()
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = self.group,
		pattern = tostring(win),
		callback = function()
			self:schedule()
		end,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = self.group,
		buffer = vim.api.nvim_win_get_buf(win),
		callback = function()
			self:schedule()
		end,
	})
	if self.tail then
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), 0 })
	end
	self:schedule()
end

function M:close()
	if self.group then
		vim.api.nvim_del_augroup_by_id(self.group)
	end
	self.group, self.win, self.notify = nil, nil, nil
end

---@param ctx table
---@param count integer
---@param revision any
---@return integer first, integer last  inclusive canonical indices
function M:use_range(ctx, count, revision)
	if self.revision ~= revision or count < self.count then
		self:invalidate()
	end
	self.revision = revision
	local tick = ctx.use_state(0)
	tick.get()
	ctx.use_effect(function()
		self.notify = function()
			tick.set(tick.get() + 1)
		end
		return function()
			self.notify = nil
		end
	end, { self })
	return self:range(count)
end

local function blanks(count)
	local lines = {}
	for i = 1, count do
		lines[i] = ""
	end
	return lines
end

local function same_marks(a, b)
	if a == b then
		return true
	end
	if #a ~= #b then
		return false
	end
	for i, m in ipairs(a) do
		local n = b[i]
		if m.start_col ~= n.start_col or m.end_col ~= n.end_col or m.hl ~= n.hl then
			return false
		end
	end
	return true
end

function M:flush(target, tree, list, width, ns)
	local props = list.props
	local buf = target.bufnr
	local old = target.visible_band
	if
		old
		and tree == target.tree
		and old.count == self.count
		and old.width == width
		and old.first == self.first
		and old.last == self.last
	then
		return
	end
	local view, anchor, inside, cursor, cursor_inside
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		view = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
		anchor = self:item(view.topline - 1)
		inside = view.topline - 1 - self:offset(anchor - 1)
		cursor = self:item(view.lnum - 1)
		cursor_inside = view.lnum - 1 - self:offset(cursor - 1)
		if self.saved_anchor then
			anchor, inside, cursor, cursor_inside = unpack_anchor(self.saved_anchor)
			self.saved_anchor = nil
		end
	end

	local before = self:offset(self.first - 1)
	Layout.compute(tree, { width = width, origin_y = before })
	local by_index = {}
	for j, index in ipairs(props.sequences) do
		by_index[index] = list.children[j].size.h
	end
	for index = self.first, self.last do
		self:measure(index, by_index[index] or 0)
	end
	local band, dirty = Render.paint_band(tree, width, tree.size.h, before, old and old.band)
	local lines, rows = {}, {}
	if dirty then
		for i = 1, #old.lines do
			lines[i], rows[i] = old.lines[i], old.rows[i]
		end
		for _, y in ipairs(dirty) do
			local i = y - before + 1
			lines[i], rows[i] = band.grid:line(i), band.grid:row_spans(i)
		end
	else
		lines = band.grid:lines()
		for i = 1, #lines do
			rows[i] = band.grid:row_spans(i)
		end
	end
	local after = self:offset(self.count) - self:offset(self.last)
	local total = math.max(1, before + #lines + after)
	local current = vim.api.nvim_buf_line_count(buf)
	vim.bo[buf].modifiable = true
	if not old and target.prev_lines then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		current = 1
	end
	if old and old.before ~= before then
		local n = math.min(#old.lines, current - old.before)
		if n > 0 then
			vim.api.nvim_buf_clear_namespace(buf, ns, old.before, old.before + n)
			vim.api.nvim_buf_set_lines(buf, old.before, old.before + n, false, blanks(n))
		end
	end
	if total > current then
		if total - current > 10000 then
			local block_size = 4096
			local block = blanks(block_size)
			for row = current, total - 1, block_size do
				local count = math.min(block_size, total - row)
				local batch = count == block_size and block or blanks(count)
				vim.api.nvim_buf_set_lines(buf, row, row, false, batch)
			end
		else
			vim.api.nvim_buf_set_lines(buf, current, current, false, blanks(total - current))
		end
	elseif total < current then
		vim.api.nvim_buf_clear_namespace(buf, ns, total, -1)
		vim.api.nvim_buf_set_lines(buf, total, -1, false, {})
	end
	local aligned = old and old.before == before
	local extent = math.min(total - before, math.max(#lines, aligned and #old.lines or 0))
	local first, last
	for i = 1, extent do
		if not aligned or lines[i] ~= old.lines[i] or (lines[i] and not same_marks(rows[i], old.rows[i])) then
			first, last = first or i, i
		end
	end
	if first then
		local patch = {}
		for i = first, last do
			patch[#patch + 1] = lines[i] or ""
		end
		vim.api.nvim_buf_clear_namespace(buf, ns, before + first - 1, before + last)
		vim.api.nvim_buf_set_lines(buf, before + first - 1, before + last, false, patch)
		for i = first, last do
			for _, mark in ipairs(rows[i] or {}) do
				vim.api.nvim_buf_set_extmark(
					buf,
					ns,
					before + i - 1,
					mark.start_col,
					{ end_col = mark.end_col, hl_group = mark.hl }
				)
			end
		end
	end
	vim.bo[buf].modifiable = false
	target.visible_band = {
		before = before,
		lines = lines,
		rows = rows,
		band = band,
		count = self.count,
		width = width,
		first = self.first,
		last = self.last,
	}
	target.canvas_lines = setmetatable({}, {
		__index = function(_, i)
			return lines[i - before]
		end,
	})
	target.prev_lines = target.canvas_lines
	target.prev_hl_rows = setmetatable({}, {
		__index = function(_, i)
			return rows[i - before]
		end,
	})
	if view then
		local function restored(i, offset)
			return math.max(
				1,
				math.min(
					total,
					self:offset(i - 1)
						+ math.max(0, math.min(offset, (self.heights[i] or (self.estimate + self.gap)) - 1))
						+ 1
				)
			)
		end
		view.topline, view.lnum = restored(anchor, inside), restored(cursor, cursor_inside)
		vim.api.nvim_win_call(self.win, function()
			local current_view = vim.fn.winsaveview()
			if
				view.topline ~= current_view.topline
				or view.lnum ~= current_view.lnum
				or view.col ~= current_view.col
				or view.leftcol ~= current_view.leftcol
			then
				vim.fn.winrestview(view)
			end
		end)
		self:schedule()
	end
	if not old or old.before ~= before or total ~= current then
		return { top = 0, bot = total - 1 }
	end
	if first then
		return { top = before + first - 1, bot = before + last - 1 }
	end
end

return M
