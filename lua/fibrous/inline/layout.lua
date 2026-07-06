-- The pure two-pass layout engine for the inline host (tracker "NEW UI HOST"):
-- bottom-up `measure` under a width constraint, top-down `layout` assigning
-- rects. Pure Lua over plain node tables — no buffers, no windows — so it unit
-- tests fast and the host can call it on every commit.
--
-- Node (input):  { kind = "text"|.., props?, text?, children? }
-- Annotations (output):
--   node.size    measured margin-box { w, h } (intrinsic under the constraint)
--   node.rect    assigned border-box { x, y, w, h } (absolute, 0-indexed)
--   node.content rect inset by border+padding (where content/children go)
--   node.lines   (text nodes) final display lines, wrapped to the final width
--
-- Root constraint modes (tracker decision): height = nil is scroll mode — the
-- root's height is its content height and the buffer scrolls natively; a fixed
-- height is app mode.

local box = require("fibrous.inline.box")
local spans = require("fibrous.inline.spans")
local width = require("fibrous.inline.width")

local M = {}

local char_width, str_width = width.char, width.str

local CONTAINERS = { col = true, row = true }

local measure, layout -- forward declarations (containers recurse)

-- Iterate the UTF-8 characters of `s`.
local function chars(s)
	return s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- Emit `word` (starting at source byte `ws`) in display-width chunks of at
-- most `max_w`, returning the final (unemitted) chunk, its width and its
-- source offset — it becomes the current line, so following words can share
-- it. `po` (optional) collects one piece list per emitted line, for span
-- attribution.
---@return string remainder, integer remainder_width, integer remainder_src
local function hard_break(word, ws, max_w, out, po)
	local chunk, w, cs = "", 0, ws
	for ch in chars(word) do
		local cw = char_width(ch)
		if w + cw > max_w and chunk ~= "" then
			out[#out + 1] = chunk
			if po then
				po[#po + 1] = { { s = cs, text = chunk } }
			end
			cs = cs + #chunk
			chunk, w = "", 0
		end
		chunk, w = chunk .. ch, w + cw
	end
	return chunk, w, cs
end

-- Greedy word-wrap of one logical line into display lines of width <= max_w.
-- Words wider than max_w are hard-broken. When `po` is given, every output
-- line gets a parallel list of source pieces ({ s = byte offset within the
-- full text, text = chunk }); `base` is the logical line's offset in it. A
-- join space points at the first byte of the gap it replaced, so it takes
-- that gap's span hl.
local function wrap_line(logical, base, max_w, out, po)
	local line, lw = "", 0
	local pieces = po and {}
	local any = false
	for ws, word in logical:gmatch("()(%S+)") do
		any = true
		local abs = base + ws - 1
		local ww = str_width(word)
		if ww > max_w then
			if line ~= "" then
				out[#out + 1] = line
				if po then
					po[#po + 1] = pieces
				end
			end
			local cs
			line, lw, cs = hard_break(word, abs, max_w, out, po)
			if po then
				pieces = { { s = cs, text = line } }
			end
		elseif line == "" then
			line, lw = word, ww
			if po then
				pieces = { { s = abs, text = word } }
			end
		elseif lw + 1 + ww <= max_w then
			if po then
				local prev = pieces[#pieces]
				pieces[#pieces + 1] = { s = prev.s + #prev.text, text = " " }
				pieces[#pieces + 1] = { s = abs, text = word }
			end
			line, lw = line .. " " .. word, lw + 1 + ww
		else
			out[#out + 1] = line
			if po then
				po[#po + 1] = pieces
				pieces = { { s = abs, text = word } }
			end
			line, lw = word, ww
		end
	end
	if any then
		out[#out + 1] = line
		if po then
			po[#po + 1] = pieces
		end
	else
		out[#out + 1] = "" -- blank logical line = paragraph break, preserved
		if po then
			po[#po + 1] = {}
		end
	end
end

-- Wrap `text`; when `ranges` is given (span-list text), also return the
-- per-line hl runs attributing the output back to the spans.
---@param text string
---@param ranges SpanRange[]|nil
---@param max_w integer
---@return string[] lines, SpanRun[][]|nil line_runs
local function wrap_text(text, ranges, max_w)
	local out = {}
	local po = ranges and {}
	local base = 1
	for _, logical in ipairs(vim.split(text, "\n", { plain = true })) do
		wrap_line(logical, base, max_w, out, po)
		base = base + #logical + 1
	end
	if not po then
		return out, nil
	end
	local runs = {}
	for i, pieces in ipairs(po) do
		runs[i] = spans.runs(pieces, ranges)
	end
	return out, runs
end

-- Character-level wrap: break each logical line into display-width chunks at ANY
-- character boundary, keeping ALL whitespace (so a code line keeps its
-- indentation and inner spacing — unlike word wrap, which tokenizes on %S+ and
-- drops leading/collapses inner whitespace). Spans re-attribute like wrap_text;
-- continuation rows start at column 0 (no hanging indent). A single char wider
-- than max_w degrades to its own overflowing row, as hard_break does.
---@param text string
---@param ranges SpanRange[]|nil
---@param max_w integer
---@return string[] lines, SpanRun[][]|nil line_runs
local function wrap_text_char(text, ranges, max_w)
	local out = {}
	local po = ranges and {}
	local base = 1
	for _, logical in ipairs(vim.split(text, "\n", { plain = true })) do
		if logical == "" then
			out[#out + 1] = "" -- blank line preserved (paragraph break)
			if po then
				po[#po + 1] = {}
			end
		else
			local chunk, w, cs = "", 0, base
			for ch in chars(logical) do
				local cw = char_width(ch)
				if w + cw > max_w and chunk ~= "" then
					out[#out + 1] = chunk
					if po then
						po[#po + 1] = { { s = cs, text = chunk } }
					end
					cs = cs + #chunk
					chunk, w = "", 0
				end
				chunk, w = chunk .. ch, w + cw
			end
			out[#out + 1] = chunk
			if po then
				po[#po + 1] = { { s = cs, text = chunk } }
			end
		end
		base = base + #logical + 1
	end
	if not po then
		return out, nil
	end
	local runs = {}
	for i, pieces in ipairs(po) do
		runs[i] = spans.runs(pieces, ranges)
	end
	return out, runs
end

-- Dispatch by wrap mode: "char" = character wrap (whitespace-preserving); any
-- other truthy value = word wrap.
---@param mode boolean|string
---@return string[] lines, SpanRun[][]|nil line_runs
local function wrap_by(mode, text, ranges, max_w)
	if mode == "char" then
		return wrap_text_char(text, ranges, max_w)
	end
	return wrap_text(text, ranges, max_w)
end

-- Split nowrap `text` at newlines; with `ranges`, attribute each line whole.
---@return string[] lines, SpanRun[][]|nil line_runs
local function split_text(text, ranges)
	local lines = vim.split(text, "\n", { plain = true })
	if not ranges then
		return lines, nil
	end
	local runs, base = {}, 1
	for i, l in ipairs(lines) do
		runs[i] = spans.runs({ { s = base, text = l } }, ranges)
		base = base + #l + 1
	end
	return lines, runs
end

---@param lines string[]
---@return integer
local function max_line_width(lines)
	local w = 0
	for _, l in ipairs(lines) do
		w = math.max(w, str_width(l))
	end
	return w
end

-- Bottom-up pass: resolve the box model and compute node.size — the intrinsic
-- margin-box size under an available-width constraint. Wrapping text reflows
-- here, so heights already reflect the constrained width.
--
-- Memoization (`node._memo`, opt-in, set by the inline host on nodes REUSED
-- from the previous flush): a reused node is byte-identical input — same
-- props, text, style, children objects — so under the same constraint its
-- whole subtree's sizes (and wrapped lines) are already right. Raw trees
-- never carry the flag and always compute.
---@param node table
---@param avail_w integer  available margin-box width
function measure(node, avail_w)
	if node._memo and node._mw == avail_w then
		return
	end
	local props = node.props or {}
	-- A host-built node carries its state-resolved style ("Style rework") — its
	-- box parts already went through box.lua. Raw trees resolve from props.
	local rs = node.style_resolved
	node.box = rs and { margin = rs.margin, padding = rs.padding, border = rs.border } or box.resolve(props)
	local r = node.box
	-- min/max_width/height are border-box bounds, like width/height. max_width
	-- also tightens the measuring constraint, so wrapping text reflows under it.
	-- An explicit width REPLACES the constraint outright: the subtree measures
	-- (and text wraps) at the width the node will actually get, whatever the
	-- parent had left — the position pass only re-wraps col-stretched text, so
	-- a nested row measured over-wide would keep its size and paint clipped.
	-- (It also makes the wrap memo stable inside rows, where the remaining-
	-- width constraint shifts with siblings.)
	local eff_avail = avail_w
	if props.width then
		eff_avail = props.width + r.margin.left + r.margin.right
	elseif props.max_width then
		eff_avail = math.min(eff_avail, props.max_width + r.margin.left + r.margin.right)
	end
	local content_avail = math.max(eff_avail - box.h_outer(r), 1)

	if node.kind == "text" and node.fill then
		-- Width-generated content: the fill fn runs in the position pass once the
		-- content box is final. Measure as one row that seeks full width (w = 0 so
		-- it never dictates the layout width; stretch/grow give it the box).
		node.lines, node.line_runs = { "" }, nil
		node.content_size = { w = 0, h = 1 }
	elseif node.kind == "text" then
		-- Span-list text ("Style rework" S4) flattens once; the ranges are
		-- re-applied to every (re)wrap so node.line_runs tracks node.lines.
		local text, ranges = node.text or "", nil
		if type(text) == "table" then
			text, ranges = spans.flatten(text)
		end
		node._text, node._ranges = text, ranges
		if props.wrap then
			node.lines, node.line_runs = wrap_by(props.wrap, text, ranges, content_avail)
			node._wrap_w = content_avail
		else
			node.lines, node.line_runs = split_text(text, ranges)
		end
		node.content_size = { w = max_line_width(node.lines), h = #node.lines }
		-- An AUTO-sized container boundary sizes itself to its INNER tree,
		-- measured here under the same constraint (the host lays the inner
		-- tree out for real once this leaf's content box is final). A VIEWPORT
		-- container (explicit height, or grow) never measures its content:
		-- its size doesn't depend on it, and the measure would run at this
		-- pass's available width — inside a row that differs from the final
		-- laid-out width, so every flush would re-measure (re-WRAP) the whole
		-- inner tree twice with flip-flopping widths, defeating the subtree
		-- memo. (Viewport containers take their width from stretch/an explicit
		-- width prop.)
		if node.subwin == "container" and node.inner and not props.height and not props.grow then
			measure(node.inner, content_avail)
			node.content_size = { w = node.inner.size.w, h = node.inner.size.h }
		end
	elseif CONTAINERS[node.kind] then
		local children = node.children or {}
		local gap = props.gap or 0
		local gaps = gap * math.max(#children - 1, 0)
		local main_sum, cross_max = 0, 0
		if node.kind == "col" then
			for _, child in ipairs(children) do
				measure(child, content_avail)
				main_sum = main_sum + child.size.h
				cross_max = math.max(cross_max, child.size.w)
			end
			node.content_size = { w = cross_max, h = main_sum + gaps }
		else
			-- Row: each child is measured against the width still unclaimed, so a
			-- wrapping child after fixed siblings wraps to what is actually left.
			local remaining = content_avail
			for i, child in ipairs(children) do
				measure(child, math.max(remaining, 1))
				remaining = remaining - child.size.w - (i < #children and gap or 0)
				main_sum = main_sum + child.size.w
				cross_max = math.max(cross_max, child.size.h)
			end
			node.content_size = { w = main_sum + gaps, h = cross_max }
		end
	else
		error("fibrous: unknown layout node kind '" .. tostring(node.kind) .. "'")
	end

	-- Explicit width/height props are border-box sizes (box-sizing: border-box).
	local cs = node.content_size
	node.size = {
		w = props.width and (props.width + r.margin.left + r.margin.right) or (cs.w + box.h_outer(r)),
		h = props.height and (props.height + r.margin.top + r.margin.bottom) or (cs.h + box.v_outer(r)),
	}

	-- A border title floors the intrinsic width so it fits between the corners;
	-- an explicit width wins (the renderer crops the title instead).
	local title = r.border.title
	if title and not props.width then
		local min_w = str_width(title.text) + r.border.sides.left + r.border.sides.right
		node.size.w = math.max(node.size.w, min_w + r.margin.left + r.margin.right)
	end

	-- Clamp the measured size to the min/max bounds (min wins, as in CSS).
	local mh = r.margin.left + r.margin.right
	local mv = r.margin.top + r.margin.bottom
	if props.max_width then
		node.size.w = math.min(node.size.w, props.max_width + mh)
	end
	if props.min_width then
		node.size.w = math.max(node.size.w, props.min_width + mh)
	end
	if props.max_height then
		node.size.h = math.min(node.size.h, props.max_height + mv)
	end
	if props.min_height then
		node.size.h = math.max(node.size.h, props.min_height + mv)
	end
	node._mw = avail_w
end

-- Top-down pass: assign the node's margin-box to (x, y, w, h) and derive its
-- border-box `rect` and `content` box. Wrapped text whose final content width
-- differs from the width it was measured against reflows once more.
---@param node table
---@param x integer  margin-box origin column (0-indexed)
---@param y integer  margin-box origin row (0-indexed)
-- Place a container's children inside its content box.
--
-- Main axis: non-grow children take their measured size; children with a
-- `grow` weight split the leftover space flex-basis-0 style (floor shares,
-- remainder to the last grow child). When nothing grows, `justify` positions
-- the run: "start" (default) | "center" | "end" | "space-between". In scroll
-- mode a col's content height equals the measured sum, so leftover is 0 and
-- both mechanisms are naturally inert.
--
-- Cross axis: `align` = "stretch" (default) | "start" | "center" | "end";
-- stretch hands each child the full cross extent unless the child fixed its
-- own cross size explicitly (explicit size wins, as in CSS). A child's
-- `align_self` overrides the container's `align` for that child alone.
-- A grow child's min/max main-axis bound, as a margin-box size (the props are
-- border-box, like width/height).
---@param child table
---@param key "min_width"|"max_width"|"min_height"|"max_height"
---@param horizontal boolean
---@return integer|nil
local function main_bound(child, key, horizontal)
	local v = (child.props or {})[key]
	if not v then
		return nil
	end
	local m = child.box.margin
	return v + (horizontal and (m.left + m.right) or (m.top + m.bottom))
end

---@param node table
local function layout_children(node)
	local props = node.props or {}
	local children = node.children or {}
	local gap = props.gap or 0
	local horizontal = node.kind == "row"
	local c = node.content
	local main_avail = horizontal and c.w or c.h
	local cross_avail = horizontal and c.h or c.w
	local align = props.align or "stretch"

	-- Leftover main-axis space after gaps and non-grow children.
	local fixed = gap * math.max(#children - 1, 0)
	local grow_total = 0
	for _, child in ipairs(children) do
		local g = (child.props or {}).grow or 0
		if g > 0 then
			grow_total = grow_total + g
		else
			fixed = fixed + (horizontal and child.size.w or child.size.h)
		end
	end
	local leftover = math.max(main_avail - fixed, 0)

	-- Resolve the grow children's main sizes, flexbox-style: split the pool by
	-- weight (floor shares, remainder to the last), clamp violations to their
	-- min/max bound and FREEZE them — their space leaves the pool and the rest
	-- re-shares. When space is short only min floors freeze (a capped sibling
	-- can still absorb the re-share); when long only max caps do.
	local grow_main
	if grow_total > 0 then
		grow_main = {}
		local min_key = horizontal and "min_width" or "min_height"
		local max_key = horizontal and "max_width" or "max_height"
		local frozen = {}
		local pool, weight = leftover, grow_total
		repeat
			local last
			for i, child in ipairs(children) do
				local g = (child.props or {}).grow or 0
				if g > 0 and not frozen[i] then
					last = i
				end
			end
			if not last then
				break
			end
			local shares, clamped = {}, {}
			local dist, violation = 0, 0
			for i, child in ipairs(children) do
				local g = (child.props or {}).grow or 0
				if g > 0 and not frozen[i] then
					local share = i == last and pool - dist or math.floor(pool * g / weight)
					dist = dist + share
					local v = math.max(share, 0)
					local mx = main_bound(child, max_key, horizontal)
					if mx and v > mx then
						v = mx
					end
					local mn = main_bound(child, min_key, horizontal)
					if mn and v < mn then
						v = mn
					end
					shares[i], clamped[i] = share, v
					violation = violation + (v - share)
				end
			end
			local changed = false
			for i, share in pairs(shares) do
				local freeze = (violation > 0 and clamped[i] > share)
					or (violation < 0 and clamped[i] < share)
					or (violation == 0 and clamped[i] ~= share)
				if freeze then
					frozen[i] = true
					grow_main[i] = clamped[i]
					pool = pool - clamped[i]
					weight = weight - ((children[i].props or {}).grow or 0)
					changed = true
				end
			end
			if not changed then
				for i in pairs(shares) do
					grow_main[i] = clamped[i]
				end
			end
		until not changed
	end

	-- Main-axis run offset and inter-child spacing from justify (only when no
	-- child grows — grow consumes the leftover instead).
	local offset, spacing = 0, 0
	if grow_total == 0 and leftover > 0 then
		local justify = props.justify or "start"
		if justify == "center" then
			offset = math.floor(leftover / 2)
		elseif justify == "end" then
			offset = leftover
		elseif justify == "space-between" and #children > 1 then
			spacing = leftover / (#children - 1) -- fractional; floored per position
		end
	end

	local pos = (horizontal and c.x or c.y) + offset
	local acc_spacing = 0
	for i, child in ipairs(children) do
		local g = (child.props or {}).grow or 0
		local main
		if g > 0 then
			main = grow_main[i]
		else
			main = horizontal and child.size.w or child.size.h
		end

		local child_props = child.props or {}
		-- The child's CROSS-axis explicit size: height in a row, width in a col.
		-- Written as an if (not `horizontal and child_props.height or
		-- child_props.width`) because that Lua idiom falls through to width whenever
		-- height is nil — so a fixed-WIDTH row child (its MAIN size) was wrongly read
		-- as having an explicit cross size and skipped the stretch (a bordered
		-- fixed-width sidebar stopping at its content height instead of filling the row).
		local explicit_cross
		if horizontal then
			explicit_cross = child_props.height
		else
			explicit_cross = child_props.width
		end
		local child_cross = horizontal and child.size.h or child.size.w
		local child_align = child_props.align_self or align
		local cross_size, cross_off
		if child_align == "stretch" and not explicit_cross then
			-- max_width/height cap the stretch (min needs no handling here: the
			-- measure clamp already floored child.size, and stretch only widens).
			local mx = child_props[horizontal and "max_height" or "max_width"]
			if mx then
				local m = child.box.margin
				mx = mx + (horizontal and (m.top + m.bottom) or (m.left + m.right))
			end
			cross_size, cross_off = math.min(cross_avail, mx or cross_avail), 0
		elseif child_align == "center" then
			cross_size = math.min(child_cross, cross_avail)
			cross_off = math.floor((cross_avail - cross_size) / 2)
		elseif child_align == "end" then
			cross_size = math.min(child_cross, cross_avail)
			cross_off = cross_avail - cross_size
		else -- "start", or stretch with an explicit cross size
			cross_size, cross_off = math.min(child_cross, cross_avail), 0
		end

		if horizontal then
			layout(child, pos, c.y + cross_off, main, cross_size)
		else
			layout(child, c.x + cross_off, pos, cross_size, main)
		end
		acc_spacing = acc_spacing + spacing
		pos = pos + main + gap + math.floor(acc_spacing + 0.5) - math.floor(acc_spacing - spacing + 0.5)
	end
end

---@param w integer  assigned margin-box width
---@param h integer  assigned margin-box height
function layout(node, x, y, w, h)
	-- Memoized skip (see measure): a reused node assigned the same margin box
	-- keeps its whole subtree's rects. When a sibling's size change shifts it,
	-- the args differ and the subtree re-positions normally — the memo makes
	-- the position pass O(changed), not O(tree). The four args pack into one
	-- number (one hash slot per node, one compare) — exact for values under
	-- 2^13, which covers any real canvas; anything bigger just never memoizes.
	local lkey
	if x >= 0 and y >= 0 and w >= 0 and h >= 0 and x < 8192 and y < 8192 and w < 8192 and h < 8192 then
		lkey = ((x * 8192 + y) * 8192 + w) * 8192 + h
	end
	if node._memo and lkey and node._lkey == lkey then
		return
	end
	node._lkey = lkey
	local r = node.box
	node.rect = {
		x = x + r.margin.left,
		y = y + r.margin.top,
		w = w - r.margin.left - r.margin.right,
		h = h - r.margin.top - r.margin.bottom,
	}
	node.content = {
		x = node.rect.x + r.border.sides.left + r.padding.left,
		y = node.rect.y + r.border.sides.top + r.padding.top,
		w = node.rect.w - box.h_inner(r),
		h = node.rect.h - box.v_inner(r),
	}

	if node.kind == "text" and node.fill then
		-- Generate the row from the now-final content width (nowrap: the fill fn
		-- returns exactly that many cells). Runs every layout, so a resize re-fills.
		local text, ranges = node.fill(math.max(node.content.w, 0))
		if type(text) == "table" then
			text, ranges = spans.flatten(text)
		end
		node.lines, node.line_runs = split_text(text, ranges)
	elseif node.kind == "text" and (node.props or {}).wrap and node.content.w ~= node._wrap_w then
		node.lines, node.line_runs = wrap_by((node.props or {}).wrap, node._text, node._ranges, math.max(node.content.w, 1))
		node._wrap_w = node.content.w
	elseif CONTAINERS[node.kind] then
		layout_children(node)
	end
end

---@class ComputeOpts
---@field width integer    root margin-box width (the viewport width)
---@field height? integer  fixed root height (app mode); nil = content height (scroll mode)

-- Run both passes over `tree`. The root always fills `opts.width`.
---@param tree table
---@param opts ComputeOpts
---@return table tree  the same tree, annotated
function M.compute(tree, opts)
	measure(tree, opts.width)
	layout(tree, 0, 0, opts.width, opts.height or tree.size.h)
	return tree
end

return M
