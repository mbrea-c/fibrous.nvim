-- The tree painter (tracker "NEW UI HOST" task 2): walks a tree annotated by
-- layout.compute and paints it onto a Canvas. Per node, in order: background
-- (props.hl over the border box), border (per-side chars, corners only where
-- both adjacent sides exist), then content — text clipped to the content box,
-- container children recursively (children paint over their parent).

local Canvas = require("fibrous.inline.canvas")

local width = require("fibrous.inline.width")
local char_width, str_width = width.char, width.str

local M = {}

local CONTAINERS = { col = true, row = true }

-- Crop `str` to at most `max_w` display cells.
---@param str string
---@param max_w integer
---@return string
local function crop(str, max_w)
	if str_width(str) <= max_w then
		return str
	end
	local out, w = {}, 0
	for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local cw = char_width(ch)
		if w + cw > max_w then
			break
		end
		out[#out + 1] = ch
		w = w + cw
	end
	return table.concat(out)
end

---@param c Canvas
---@param rect { x: integer, y: integer, w: integer, h: integer }
---@param b Border
---@param hl_override string|nil  style `border_hl` — recolors without touching the spec
local function draw_border(c, rect, b, hl_override)
	local s = b.sides
	if s.top + s.right + s.bottom + s.left == 0 then
		return
	end
	-- hl = false is a TRANSPARENT border: cells painted with no hl of their own
	-- keep the node's background fill (Canvas:put leaves the cell hl in place).
	local hl = hl_override
	if hl == nil then
		hl = b.hl
	end
	if hl == nil then
		hl = "FibrousBorder"
	elseif hl == false then
		hl = nil
	end
	local x0, y0 = rect.x, rect.y
	local x1, y1 = rect.x + rect.w - 1, rect.y + rect.h - 1

	-- Edges via direct put (bounds-safe) with the char width computed once —
	-- border cells are a large share of all painted cells (task 8 bench).
	if s.top == 1 then
		local ch, cw = b.chars.top, char_width(b.chars.top)
		for x = x0 + s.left, x1 - s.right do
			c:put(x, y0, ch, hl, cw)
		end
	end
	if s.bottom == 1 then
		local ch, cw = b.chars.bottom, char_width(b.chars.bottom)
		for x = x0 + s.left, x1 - s.right do
			c:put(x, y1, ch, hl, cw)
		end
	end
	if s.left == 1 then
		local ch, cw = b.chars.left, char_width(b.chars.left)
		for y = y0 + s.top, y1 - s.bottom do
			c:put(x0, y, ch, hl, cw)
		end
	end
	if s.right == 1 then
		local ch, cw = b.chars.right, char_width(b.chars.right)
		for y = y0 + s.top, y1 - s.bottom do
			c:put(x1, y, ch, hl, cw)
		end
	end

	-- Corners only where both adjacent sides exist.
	if s.top == 1 and s.left == 1 then
		c:put(x0, y0, b.chars.tl, hl, char_width(b.chars.tl))
	end
	if s.top == 1 and s.right == 1 then
		c:put(x1, y0, b.chars.tr, hl, char_width(b.chars.tr))
	end
	if s.bottom == 1 and s.left == 1 then
		c:put(x0, y1, b.chars.bl, hl, char_width(b.chars.bl))
	end
	if s.bottom == 1 and s.right == 1 then
		c:put(x1, y1, b.chars.br, hl, char_width(b.chars.br))
	end

	-- Title, painted over its edge (between the corners) after the edge chars.
	local t = b.title
	if t and s[t.pos] == 1 then
		local span_w = rect.w - s.left - s.right
		local text = crop(t.text, math.max(span_w, 0))
		if text ~= "" then
			local x = x0 + s.left
			local tw = str_width(text)
			if t.align == "center" then
				x = x + math.floor((span_w - tw) / 2)
			elseif t.align == "right" then
				x = x + span_w - tw
			end
			c:text(x, t.pos == "top" and y0 or y1, text, t.hl or hl)
		end
	end
end

---@param c Canvas
---@param node table  a node annotated by layout.compute
local function visit(c, node)
	local rect = node.rect
	-- What this node has painted on the canvas — the incremental painter
	-- (M.update) compares against it to decide whether a subtree can be
	-- skipped. Recorded even for degenerate rects, so the baseline exists.
	-- `_prev` (build bookkeeping M.update normally consumes) is dropped here
	-- too: a full paint that skips M.update must not leave old node objects
	-- chained alive frame over frame.
	node._prect = rect
	node._prev = nil
	if rect.w <= 0 or rect.h <= 0 then
		return
	end
	local props = node.props or {}
	-- Host-built nodes carry a state-resolved style; raw trees style from props.
	local rs = node.style_resolved
	local bg = rs and rs.hl or props.hl
	local text_hl = rs and rs.text_hl or props.text_hl

	if bg then
		c:hl_rect(rect, bg)
	end
	draw_border(c, rect, node.box.border, rs and rs.border_hl)

	if node.kind == "text" then
		local content = node.content
		for i, line in ipairs(node.lines) do
			if i > content.h then
				break
			end
			local y = content.y + i - 1
			local runs = node.line_runs and node.line_runs[i]
			if runs then
				-- Span-list text: paint per attribution run, hl-less runs falling
				-- back to the node's text_hl.
				local x, remaining = content.x, content.w
				for _, run in ipairs(runs) do
					if remaining <= 0 then
						break
					end
					local chunk = crop(run.text, remaining)
					c:text(x, y, chunk, run.hl or text_hl)
					local cw = str_width(chunk)
					x, remaining = x + cw, remaining - cw
				end
			else
				c:text(content.x, y, crop(line, content.w), text_hl)
			end
		end
	elseif CONTAINERS[node.kind] then
		for _, child in ipairs(node.children or {}) do
			visit(c, child)
		end
	end
end

-- Paint a laid-out tree onto a fresh (w × h) canvas.
---@param tree table  annotated by layout.compute
---@param w integer   canvas width (the root margin-box width)
---@param h integer   canvas height
---@return Canvas
function M.paint(tree, w, h)
	local c = Canvas.new(w, h)
	visit(c, tree)
	return c
end

---@param a { x: integer, y: integer, w: integer, h: integer }
---@param b { x: integer, y: integer, w: integer, h: integer }|nil
local function rects_equal(a, b)
	return b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

local SIDES = { "top", "right", "bottom", "left" }
local CORNERS = { "tl", "tr", "bl", "br" }

---@param a Border
---@param b Border
local function border_equal(a, b)
	if a.hl ~= b.hl then
		return false
	end
	for _, k in ipairs(SIDES) do
		if a.sides[k] ~= b.sides[k] or a.chars[k] ~= b.chars[k] then
			return false
		end
	end
	for _, k in ipairs(CORNERS) do
		if a.chars[k] ~= b.chars[k] then
			return false
		end
	end
	local at, bt = a.title, b.title
	if at == nil or bt == nil then
		return at == bt
	end
	return at.text == bt.text and at.hl == bt.hl and at.align == bt.align and at.pos == bt.pos
end

local function bg_of(node)
	local rs = node.style_resolved
	return rs and rs.hl or (node.props or {}).hl
end

-- Everything a CONTAINER paints itself — background fill and border — is
-- unchanged between its previous incarnation and this rebuild, and no child
-- was LOST. Removals matter because a lost child's cells are only ever
-- blanked by a wholesale repaint of the parent's rect; children that stayed
-- (however many joined them) each blank their own old area when they change
-- or move, so every stale cell is accounted for.
---@param node table  the rebuilt container, laid out this frame
---@param prev table  its previous incarnation (`_prev`, stashed by the build)
local function chrome_equal(node, prev)
	if #(node.children or {}) < #(prev.children or {}) then
		return false
	end
	if bg_of(node) ~= bg_of(prev) then
		return false
	end
	local rs, prs = node.style_resolved, prev.style_resolved
	if (rs and rs.border_hl) ~= (prs and prs.border_hl) then
		return false
	end
	return border_equal(node.box.border, prev.box.border)
end

-- The node paints no cells of its own: no background fill, no border side.
-- Only such a container may treat pure downward growth as "already right" —
-- with any chrome, growth moves the bottom/right edges and stretches the fill.
---@param node table
local function no_chrome(node)
	if bg_of(node) then
		return false
	end
	local s = node.box.border.sides
	return s.top + s.right + s.bottom + s.left == 0
end

---@return { x: integer, y: integer, w: integer, h: integer }  a ∩ b (w/h 0 when disjoint)
local function intersect(a, b)
	local x0, y0 = math.max(a.x, b.x), math.max(a.y, b.y)
	local x1 = math.min(a.x + a.w, b.x + b.w)
	local y1 = math.min(a.y + a.h, b.y + b.h)
	return { x = x0, y = y0, w = math.max(x1 - x0, 0), h = math.max(y1 - y0, 0) }
end

-- Incremental repaint of `tree` onto the SAME canvas its previous frame was
-- painted on. Per node, in document order:
--   * reused node (`_memo`) painted at the same rect  → skip the subtree
--     (identical objects, identical spot: every cell is already right);
--   * fresh node whose own visual is intact at its predecessor's rect →
--     descend (only some descendant changed). Two ways to know the visual is
--     intact: the fiber didn't render at all (`_keep`), or it did — a list
--     component committing a new children array — but the container paints
--     the same chrome around a superset of its children (chrome_equal
--     against `_prev`), the case that keeps ONE changed entry in a long
--     list from repainting all of them. A chrome-less container may also
--     GROW downward in place (append-at-tail onto a grown canvas);
--   * anything else → repaint root: its old and new areas are blanked,
--     ancestor backgrounds restored over them, then the subtree painted
--     exactly like a full paint would.
-- Repaint roots are collected first and applied blank-all-then-paint-all, so
-- one root's vacated area can't clobber another's fresh paint. Sibling rects
-- never overlap (the box model has no negative margins), which is what makes
-- "the cells under an unchanged node are already right" sound.
--
-- Returns the 0-based rows that changed (sorted, unique) so the host can
-- patch its retained line/span arrays instead of re-extracting the canvas.
---@param c Canvas
---@param tree table  annotated by layout.compute
---@return integer[] dirty_rows
function M.update(c, tree)
	---@type { node: table, bgs: { rect: table, hl: string }[], old: table|nil }[]
	local roots = {}

	local function walk(node, bgs)
		local rect = node.rect
		if node._memo then
			if rects_equal(rect, node._prect) then
				return -- untouched subtree in its old spot
			end
			roots[#roots + 1] = { node = node, bgs = bgs, old = node._prect }
			return
		end
		-- fresh node: consume the build-time bookkeeping either way
		local old = node._old_rect
		node._old_rect = nil
		local prev = node._prev
		node._prev = nil
		-- own visual intact: the fiber didn't render (_keep), or it did but
		-- repainted the same chrome around a superset of the children
		local intact = node._keep or (prev ~= nil and CONTAINERS[node.kind] and chrome_equal(node, prev))
		-- ...and every cell it stands for is already right: same rect, or (for
		-- a chrome-less container) the rect only grew downward onto virgin rows
		local fits = rects_equal(rect, old)
		if intact and not fits and old and CONTAINERS[node.kind] then
			fits = rect.x == old.x and rect.y == old.y and rect.w == old.w and rect.h > old.h and no_chrome(node)
		end
		if intact and fits then
			node._keep = nil
			node._prect = rect -- predecessor's paint of this box still stands
			local bg = bg_of(node)
			if bg then
				bgs = vim.list_extend({ { rect = rect, hl = bg } }, bgs)
			end
			for _, child in ipairs(node.children or {}) do
				walk(child, bgs)
			end
			return
		end
		node._keep = nil
		roots[#roots + 1] = { node = node, bgs = bgs, old = old }
	end
	walk(tree, {})

	-- Phase 1: blank every root's old and new area (stale cells, wherever the
	-- next phase doesn't repaint them, must read as empty)...
	local rows = {}
	local function mark_rows(rect)
		for y = math.max(rect.y, 0), math.min(rect.y + rect.h, c.h) - 1 do
			rows[y] = true
		end
	end
	for _, r in ipairs(roots) do
		c:blank_rect(r.node.rect)
		mark_rows(r.node.rect)
		if r.old and not rects_equal(r.old, r.node.rect) then
			c:blank_rect(r.old)
			mark_rows(r.old)
		end
	end
	-- ...phase 2: restore what the (unrepainted) ancestors had contributed to
	-- those cells — their background fills...
	for _, r in ipairs(roots) do
		for i = #r.bgs, 1, -1 do -- outermost background first
			local bg = r.bgs[i]
			c:hl_rect(intersect(bg.rect, r.node.rect), bg.hl)
			if r.old then
				c:hl_rect(intersect(bg.rect, r.old), bg.hl)
			end
		end
	end
	-- ...phase 3: paint each changed subtree, exactly as a full paint would.
	for _, r in ipairs(roots) do
		visit(c, r.node)
	end

	local out = {}
	for y in pairs(rows) do
		out[#out + 1] = y
	end
	table.sort(out)
	return out
end

return M
