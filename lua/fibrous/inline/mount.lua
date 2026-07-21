-- Mount targets for the inline host (tracker "NEW UI HOST" task 3):
--
--   floating(component)  an editor-relative float IS the app window.
--   split(component)     a native split pane provides geometry only (it holds
--                        a throwaway scratch buffer); a relative="win" float
--                        covers it edge to edge. Resizes resync the float and
--                        relayout; closing the pane tears the app down.
--   window(component)    the same covering float, over a window the embedder
--                        already owns.
--   buffer(component)    the host buffer goes straight INTO an existing
--                        window, with no covering float at all.
--
-- The first three put the host buffer in a ROOT FLOAT. That was once stated as
-- an invariant ("rendering straight into a host window would let a resize
-- clobber widgets before we get to relayout, and subwindows need resize sync
-- anyway"), and M.buffer is the measured retraction of it: under a real UI a
-- resize relayouts correctly with no float to resync, at a third of the
-- redraw bytes and one fewer window. See design-buffer-mount.md for the
-- numbers and for what a buffer mount costs instead (it must reproduce
-- style="minimal" by hand, and put the embedder's buffer back on teardown).
--
-- `opts.mode` picks the root constraint mode (tracker decision, the two core
-- use-cases): "fixed" (default) lays out at the window height — app-style UIs;
-- "scroll" lays out at nil height so the buffer grows with content and the
-- window is a natively-scrolling viewport — website-style UIs.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local subwin = require("fibrous.inline.subwin")
local interact = require("fibrous.inline.interact")
local targets = require("fibrous.targets")

local M = {}

---@class InlineAppHandle
---@field winid integer   the root float
---@field bufnr integer   the host buffer it displays
---@field set_props fun(new_props: table)
---@field relayout fun()  resync geometry + re-flush at the current size
---@field focus fun()
---@field unmount fun()

-- Open the root float over `bufnr`. style="minimal" clears number/cursorline/
-- fillchars noise; wrap must be off besides — canvas lines are exactly the
-- layout width, and a stray wrap would double rows and break rect math.
---@param bufnr integer
---@param cfg table  nvim_open_win config
---@return integer winid
local function open_root_float(bufnr, cfg)
	cfg = vim.tbl_extend("keep", cfg, { style = "minimal", zindex = 50, focusable = true })
	local winid = vim.api.nvim_open_win(bufnr, false, cfg)
	vim.wo[winid].wrap = false
	return winid
end

-- Pin the root's view on the locked axes. A fixed-mode root has nothing to
-- scroll to at all (the canvas IS the viewport), and even a scroll-mode root
-- has no horizontal content to reveal (its canvas lays out at exactly the
-- viewport width) — but nvim happily scrolls any window until its last line
-- hits the top, or sideways off its floats. Wired BEFORE subwin.attach —
-- autocmds run in definition order, so the manager's own WinScrolled resync
-- sees the restored view and the floats never swim.
---@param winid integer  the root float
---@param group integer
---@param axes { x: boolean, y: boolean }  which axes to PIN
---@return fun() restore  pin the view NOW (call it after a relayout too)
local function pin_view(winid, group, axes)
	-- A resize hands the cursor no margin to push the view around with: nvim
	-- shrinking the window would otherwise scroll the root to keep the cursor
	-- (plus the user's global 'scrolloff') on screen, and that resize-time
	-- scroll delivers no WinScrolled the handler below can catch — the panel
	-- stayed scrolled until a manual scroll. sync() re-pins directly besides.
	-- Only the pinned axes: a y-scrollable root keeps the user's 'scrolloff'.
	if axes.y then
		vim.wo[winid].scrolloff = 0
	end
	if axes.x then
		vim.wo[winid].sidescrolloff = 0
	end

	local pending = false
	local function restore()
		pending = false
		if not vim.api.nvim_win_is_valid(winid) then
			return
		end
		vim.api.nvim_win_call(winid, function()
			local v = vim.fn.winsaveview()
			local fix = {}
			if axes.y and v.topline ~= 1 then
				fix.topline = 1
			end
			if axes.x and (v.leftcol or 0) ~= 0 then
				fix.leftcol = 0
			end
			if next(fix) then
				vim.fn.winrestview(fix)
			end
		end)
	end
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		pattern = tostring(winid),
		callback = function()
			-- DEFERRED, not inline: a view change made inside the WinScrolled
			-- autocmd is invisible to nvim's per-window scroll checkpoint (it
			-- never re-triggers the event), so an inline restore leaves the
			-- checkpoint at the SCROLLED topline — and the next wheel notch
			-- landing on that same topline fires no event at all, sticking the
			-- root scrolled. Restored on the main loop, the restore is itself
			-- an observed scroll: the checkpoint follows, every notch fires.
			if not pending then
				pending = true
				vim.schedule(restore)
			end
		end,
	})
	return restore
end

-- Which root axes are LOCKED, from the mount opts. `mode` sets the defaults:
-- "fixed" pins both (the canvas is the viewport), "scroll" frees the
-- vertical axis only — a scroll-mode root lays its canvas out at exactly the
-- viewport width, so a horizontal scroll can never reveal content, it only
-- drags the page off its floats (requests.md: the perijove page could be
-- dragged sideways). opts.scroll_x / opts.scroll_y override either axis,
-- mirroring the container subwindow props of the same names.
---@param opts { mode?: string, scroll_x?: boolean, scroll_y?: boolean }
---@return { x: boolean, y: boolean } pinned
local function pinned_axes(opts)
	local sx = opts.scroll_x
	if sx == nil then
		sx = false
	end
	local sy = opts.scroll_y
	if sy == nil then
		sy = opts.mode == "scroll"
	end
	return { x = not sx, y = not sy }
end

-- Shared mount plumbing: create the root, wire coalesced resize sync (one
-- relayout per event-loop tick, as in mount/window_host.lua) plus lifecycle
-- autocmds, and build the handle. Callers supply the geometry logic:
--   sync()        re-apply window geometry, then host.relayout()
--   on_teardown() close this target's windows (buffer deletion is the host's)
--   on_unmount() the embedder's notification, fired once after cleanup —
--                teardown can start on nvim's side (:q on the pane or the
--                root float), and whoever mounted the app must hear about it
--   release_root() let go of the root WINDOW, before the host buffer dies.
--                Default: close it, which is right for every float root. A
--                buffer mount passes its own (put the previous buffer back)
--                because the window is the embedder's, not ours.
---@return InlineAppHandle handle, fun() teardown
local function wire(component, props, host, winid, group, attachments, sync, on_teardown, on_unmount, release_root)
	local root = runtime.create_root(component, props, { host = host })
	root:render()

	-- Register this mount with the global target registry (fibrous.targets): its
	-- provider hands out the interactive elements currently visible in its root
	-- window PLUS every subwindow (the subwin manager's collect_targets resolves
	-- container/mirror coordinates), for flash.nvim-style jump-to-widget.
	-- Deregistered on teardown.
	local target_token = targets.register(function()
		local out = targets.extract(host.root_target, winid)
		for _, attachment in ipairs(attachments) do
			if attachment.collect_targets then
				vim.list_extend(out, attachment.collect_targets())
			end
		end
		return out
	end)

	local unmounted = false
	local function teardown()
		if unmounted then
			return
		end
		unmounted = true
		targets.unregister(target_token)
		pcall(vim.api.nvim_del_augroup_by_id, group)
		for _, attachment in ipairs(attachments) do
			attachment.teardown()
		end
		-- ORDER IS LOAD-BEARING for a buffer mount: root:unmount() deletes the
		-- host buffer, and deleting a buffer while a REAL window still displays
		-- it takes that window down too. So the root is released first, and a
		-- buffer mount uses that moment to put the embedder's buffer back. A
		-- float root is closed here anyway, so it never noticed the ordering.
		if release_root then
			release_root()
		elseif vim.api.nvim_win_is_valid(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
		root:unmount()
		on_teardown()
		if on_unmount then
			pcall(on_unmount)
		end
	end

	local relayout_pending = false
	local function schedule_relayout()
		if relayout_pending then
			return
		end
		relayout_pending = true
		vim.schedule(function()
			relayout_pending = false
			if not unmounted and vim.api.nvim_win_is_valid(winid) then
				sync()
			end
		end)
	end
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = schedule_relayout,
	})

	-- A user :q on the root float kills the app, not just the window.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(winid),
		callback = function()
			vim.schedule(teardown)
		end,
	})

	---@type InlineAppHandle
	local handle = {
		winid = winid,
		bufnr = host.bufnr,
		set_props = function(new_props)
			root:set_props(new_props)
		end,
		relayout = function()
			if not unmounted then
				sync()
			end
		end,
		focus = function()
			if vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_set_current_win(winid)
			end
		end,
		unmount = teardown,
	}
	return handle, teardown
end

---@class InlineFloatingOpts
---@field width? integer    default 60% of columns
---@field height? integer   default 60% of lines
---@field row? integer      default centered
---@field col? integer      default centered
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"
---@field scroll_x? boolean  free the root's horizontal axis; default false (a scroll-mode canvas lays out at the viewport width, so x-scroll only drags the page off its floats)
---@field scroll_y? boolean  free the root's vertical axis; default follows mode ("scroll" frees it, "fixed" pins it)
---@field mouse? InlineMouseOpts|false  { activate?, follow? }; false disables mouse maps
---@field keys? string[]  normal-mode keys routed to a component's on_key handler (fired for the component under the cursor)
---@field zindex? integer   root float zindex (default 50, nvim's float default); subwindow levels stack root+1
---@field border? string|string[]  nvim_open_win border for the root float
---@field on_unmount? fun()  fired once after teardown, whoever initiated it (handle.unmount or :q on the app's windows)
---@field backdrop? boolean|integer  dim the editor behind the app: a full-screen, non-focusable float one z-level below the root (FibrousBackdrop + winblend; a number IS the blend, true = 60). NB nvim's compositor can't blend floats through a winblend float: normal windows behind the backdrop DIM, floats behind it (pane-anchored fibrous apps included) are hidden outright — the intended modal effect. Needs termguicolors to blend rather than block.

-- Mount `component` as a standalone floating application.
---@param component Component
---@param props? table
---@param opts? InlineFloatingOpts
---@return InlineAppHandle
function M.floating(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"
	local zindex = opts.zindex or 50

	-- Explicit opts pin the geometry; defaults track the editor size (VimResized
	-- re-derives them through this same function).
	local function geom()
		local width = opts.width or math.floor(vim.o.columns * 0.6)
		local height = opts.height or math.floor(vim.o.lines * 0.6)
		return {
			width = width,
			height = height,
			row = opts.row or math.floor((vim.o.lines - height) / 2),
			col = opts.col or math.floor((vim.o.columns - width) / 2),
		}
	end

	local g = geom()
	local manager, interaction -- need the root winid, so attached below
	local host = inline_host.new({
		get_size = function()
			local cur = geom()
			return { width = cur.width, height = not scroll and cur.height or nil }
		end,
		on_flush = function(damage)
			if manager then
				-- nil damage = the canvas didn't change: nothing under the floats
				-- to re-extract. Explicit if, NOT `damage == nil and false or
				-- damage` — that expression can never yield false, and silently
				-- forced a full re-extraction of every widget per clean frame.
				if damage == nil then
					damage = false
				end
				manager.sync(damage)
				interaction.reanchor(damage)
				interaction.update()
			end
		end,
	})
	-- The backdrop: one full-editor, non-focusable scratch float one z-level
	-- below the root, covering everything behind the app. Its whole lifecycle
	-- rides the mount's: resized in sync(), closed as an attachment teardown.
	-- NB the compositor can't blend floats through a winblend float — lower
	-- floats (pane-anchored fibrous apps included) are HIDDEN outright while
	-- normal windows dim. Obscuring the page furniture is the intended modal
	-- effect (decided over the alternative — backdrop below the furniture,
	-- which left it visible but undimmed).
	local backdrop_win
	if opts.backdrop then
		local blend = type(opts.backdrop) == "number" and opts.backdrop or 60
		vim.api.nvim_set_hl(0, "FibrousBackdrop", { bg = "#000000", default = true })
		local backdrop_bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[backdrop_bufnr].bufhidden = "wipe"
		backdrop_win = vim.api.nvim_open_win(backdrop_bufnr, false, {
			relative = "editor",
			row = 0,
			col = 0,
			width = vim.o.columns,
			height = vim.o.lines,
			style = "minimal",
			focusable = false,
			zindex = zindex - 1,
		})
		vim.wo[backdrop_win].winhighlight = "Normal:FibrousBackdrop"
		vim.wo[backdrop_win].winblend = blend
	end

	local winid = open_root_float(host.bufnr, {
		relative = "editor",
		row = g.row,
		col = g.col,
		width = g.width,
		height = g.height,
		zindex = zindex,
		border = opts.border,
	})
	local group = vim.api.nvim_create_augroup("FibrousInlineFloat_" .. winid, { clear = true })
	local axes = pinned_axes(opts)
	local pin_restore
	if axes.x or axes.y then
		pin_restore = pin_view(winid, group, axes)
	end
	manager = subwin.attach(host, winid, { mouse = opts.mouse, zindex = zindex + 1, keys = opts.keys })
	interaction = interact.attach(host, winid, opts.mouse, manager, nil, opts.keys, opts.anchor)

	local function sync()
		local cur = geom()
		vim.api.nvim_win_set_config(winid, {
			relative = "editor",
			row = cur.row,
			col = cur.col,
			width = cur.width,
			height = cur.height,
		})
		if backdrop_win and vim.api.nvim_win_is_valid(backdrop_win) then
			vim.api.nvim_win_set_config(backdrop_win, {
				relative = "editor",
				row = 0,
				col = 0,
				width = vim.o.columns,
				height = vim.o.lines,
			})
		end
		host.relayout()
		-- Re-pin after the resize: nvim may have scrolled the root to chase the
		-- cursor when the window shrank (no WinScrolled to catch it — see pin_view).
		if pin_restore then
			pin_restore()
		end
	end

	local close_backdrop = {
		teardown = function()
			if backdrop_win and vim.api.nvim_win_is_valid(backdrop_win) then
				pcall(vim.api.nvim_win_close, backdrop_win, true)
			end
		end,
	}
	local handle = wire(
		component,
		props,
		host,
		winid,
		group,
		{ manager, interaction, close_backdrop },
		sync,
		function() end,
		opts.on_unmount
	)
	return handle
end

---@class InlineSplitOpts
---@field split? SplitOpts   direction/position/size of the host pane; default vertical/left/40
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"
---@field scroll_x? boolean  free the root's horizontal axis; default false (a scroll-mode canvas lays out at the viewport width, so x-scroll only drags the page off its floats)
---@field scroll_y? boolean  free the root's vertical axis; default follows mode ("scroll" frees it, "fixed" pins it)
---@field mouse? InlineMouseOpts|false  { activate?, follow? }; false disables mouse maps
---@field keys? string[]  normal-mode keys routed to a component's on_key handler (fired for the component under the cursor)
---@field zindex? integer   root float zindex (default 10 — see M.window)
---@field on_unmount? fun()  fired once after teardown, whoever initiated it (handle.unmount or :q on the app's windows)
---@field render? "float"|"buffer"  how the pane is drawn: "float" (default) covers it with a root float; "buffer" renders into the pane itself (M.buffer)

-- Open a native split pane and return its winid. The pane holds a throwaway
-- scratch buffer; the root float over it does the real drawing.
---@param split SplitOpts
---@return integer host_winid
local function open_host_pane(split)
	local direction = split.direction or "vertical"
	local position = split.position or (direction == "vertical" and "left" or "top")
	local vertical = direction == "vertical"
	local anchor = (position == "left" or position == "top") and "topleft" or "botright"
	vim.cmd(anchor .. " " .. (vertical and "vsplit" or "split"))

	local host_winid = vim.api.nvim_get_current_win()
	local pane_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[pane_bufnr].bufhidden = "wipe"
	vim.api.nvim_win_set_buf(host_winid, pane_bufnr)

	local size = split.size or 40
	if vertical then
		vim.api.nvim_win_set_width(host_winid, size)
	else
		vim.api.nvim_win_set_height(host_winid, size)
	end
	return host_winid
end

---@class InlineSplitHandle : InlineAppHandle
---@field host_winid integer  the native split pane the float is anchored to

-- Mount `component` over a native split pane.
---@param component Component
---@param props? table
---@param opts? InlineSplitOpts
---@return InlineSplitHandle
function M.split(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"
	local origin_winid = vim.api.nvim_get_current_win()
	local host_winid = open_host_pane(opts.split or {})
	vim.api.nvim_set_current_win(origin_winid)

	local target = opts.render == "buffer" and M.buffer or M.window
	local handle =
		target(component, props, {
			winid = host_winid,
			mode = opts.mode,
			scroll_x = opts.scroll_x,
			scroll_y = opts.scroll_y,
			mouse = opts.mouse,
			zindex = opts.zindex,
			keys = opts.keys,
			on_unmount = opts.on_unmount,
			own_window = true,
		})

	return handle
end

---@class InlineWindowMountOpts
---@field winid integer which window to mount on
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"
---@field scroll_x? boolean  free the root's horizontal axis; default false (a scroll-mode canvas lays out at the viewport width, so x-scroll only drags the page off its floats)
---@field scroll_y? boolean  free the root's vertical axis; default follows mode ("scroll" frees it, "fixed" pins it)
---@field mouse? InlineMouseOpts|false  { activate?, follow? }; false disables mouse maps
---@field keys? string[]  normal-mode keys routed to a component's on_key handler (fired for the component under the cursor)
---@field zindex? integer  root float zindex; default 10. Pane-anchored apps are page furniture — the whole stack (root + subwindow levels, +1 each) stays below nvim's float default (50), so genuine floats (float-mounted fibrous apps, other plugins' popups) always render above them.
---@field on_unmount? fun()  fired once after teardown, whoever initiated it (handle.unmount or :q on the app's windows)
---@field own_window? boolean  teardown closes the mounted-on window. M.split sets it (the pane is fibrous's own creation); default false — the window belongs to the embedder, who reacts through on_unmount

-- Mount `component` over a native split pane.
---@param component Component
---@param props? table
---@param opts? InlineWindowMountOpts
---@return InlineSplitHandle
function M.window(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"
	local zindex = opts.zindex or 10
	-- Resolve winid = 0 ("current window") to a concrete id NOW: it is read
	-- again long after mount (geometry syncs, WinClosed pattern, validity
	-- guards), when the current window may be the root float itself.
	local host_winid = opts.winid
	if host_winid == 0 or host_winid == nil then
		host_winid = vim.api.nvim_get_current_win()
	end

	local function pane_size()
		return {
			width = vim.api.nvim_win_get_width(host_winid),
			height = vim.api.nvim_win_get_height(host_winid),
		}
	end

	local g = pane_size()
	local manager, interaction -- need the root winid, so attached below
	local host = inline_host.new({
		get_size = function()
			local cur = pane_size()
			return { width = cur.width, height = not scroll and cur.height or nil }
		end,
		on_flush = function(damage)
			if manager then
				-- nil damage = the canvas didn't change: nothing under the floats
				-- to re-extract. Explicit if, NOT `damage == nil and false or
				-- damage` — that expression can never yield false, and silently
				-- forced a full re-extraction of every widget per clean frame.
				if damage == nil then
					damage = false
				end
				manager.sync(damage)
				interaction.reanchor(damage)
				interaction.update()
			end
		end,
	})
	local winid = open_root_float(host.bufnr, {
		relative = "win",
		win = host_winid,
		row = 0,
		col = 0,
		width = g.width,
		height = g.height,
		zindex = zindex,
	})
	local group = vim.api.nvim_create_augroup("FibrousInlineSplit_" .. host_winid, { clear = true })
	local axes = pinned_axes(opts)
	local pin_restore
	if axes.x or axes.y then
		pin_restore = pin_view(winid, group, axes)
	end
	-- host_winid: <C-w> anywhere in the app (root or nested floats) acts on
	-- the backing pane, the app's ONE real window in the layout.
	-- anchor_winid: subwindow floats anchor relative="win" to the pane: inert
	-- (no cursor, no buffer edits), so the whole-float-redraw pathology can't
	-- trigger, and nvim moves the floats with the pane ATOMICALLY on layout
	-- changes (see subwin reposition's anchoring note).
	manager = subwin.attach(host, winid, {
		mouse = opts.mouse,
		zindex = zindex + 1,
		keys = opts.keys,
		host_winid = host_winid,
		anchor_winid = host_winid,
	})
	interaction = interact.attach(host, winid, opts.mouse, manager, nil, opts.keys, opts.anchor)

	-- The pane is reachable by <C-w>-navigation (floats are not part of the
	-- window layout), but it is a blank scratch buffer behind the float:
	-- forward any focus it receives into the app.
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			if vim.api.nvim_get_current_win() == host_winid and vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_set_current_win(winid)
			end
		end,
	})

	local function sync()
		if not vim.api.nvim_win_is_valid(host_winid) then
			return
		end
		local cur = pane_size()
		vim.api.nvim_win_set_config(winid, {
			relative = "win",
			win = host_winid,
			row = 0,
			col = 0,
			width = cur.width,
			height = cur.height,
		})
		host.relayout()
		-- Re-pin after the resize (see the floating sync + pin_view).
		if pin_restore then
			pin_restore()
		end
	end

	local handle, teardown = wire(component, props, host, winid, group, { manager, interaction }, sync, function()
		if opts.own_window and vim.api.nvim_win_is_valid(host_winid) then
			pcall(vim.api.nvim_win_close, host_winid, true)
		end
	end, opts.on_unmount)

	-- Closing the pane (:q, <C-w>q) unmounts the whole app; deferred because
	-- windows can't be closed from inside WinClosed.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(host_winid),
		callback = function()
			vim.schedule(teardown)
		end,
	})

	handle.host_winid = host_winid
	return handle
end

---@class InlineBufferMountOpts
---@field winid? integer which window to render into; default the current one
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"
---@field scroll_x? boolean  free the root's horizontal axis; default false
---@field scroll_y? boolean  free the root's vertical axis; default follows mode
---@field mouse? InlineMouseOpts|false  { activate?, follow? }; false disables mouse maps
---@field keys? string[]  normal-mode keys routed to a component's on_key handler
---@field zindex? integer  subwindow float zindex; default 10, as for M.window (page furniture, below nvim's float default). There is no root float here, so this is the base the subwindow levels stack from.
---@field on_unmount? fun()  fired once after teardown, whoever initiated it
---@field own_window? boolean  teardown closes the rendered-into window. M.split sets it; default false

-- The window options a root float gets free from style="minimal". A buffer
-- mount renders into an ORDINARY window, where that is not a thing you can ask
-- for, so it is reproduced here option by option. `wrap` is the load-bearing
-- one: canvas lines are exactly the layout width, and a stray wrap would
-- double rows and break every rect.
---@param winid integer
---@return table saved  the previous values, to restore on unmount
local function apply_minimal(winid)
	local wo = vim.wo[winid]
	local saved = {}
	for opt, value in pairs({
		wrap = false,
		number = false,
		relativenumber = false,
		cursorline = false,
		cursorcolumn = false,
		spell = false,
		list = false,
		foldenable = false,
		signcolumn = "no",
		foldcolumn = "0",
		colorcolumn = "",
		statuscolumn = "",
	}) do
		saved[opt] = wo[opt]
		wo[opt] = value
	end
	return saved
end

-- What a buffer mount shows when its host buffer is displayed in more than one
-- window. One buffer, one canvas: there is no way to draw the app in both.
-- Subwindow floats anchor to a single window, the two viewports would fight
-- over the same lines, and nothing can be rendered per-window because the
-- CONTENT is shared. So the app says so, centered, instead of drawing a
-- half-working UI in both. Closing the extra window restores the real UI.
local MULTIWIN_MESSAGE = "(cannot render fibrous buffer in two windows at once)"

-- Wrap `component` so the mount can swap the whole tree for that message.
-- Done as a component rather than by writing to the buffer directly, so the
-- message goes through normal layout (centering, resize) and so the real
-- tree's subwindow floats are torn down by the ordinary reconcile.
-- Greedy word wrap, so the message survives a pane narrower than its 51
-- columns (a sidebar routinely is). Words longer than the width are left
-- alone: truncating them would be worse than one overlong row.
---@param text string
---@param width integer
---@return string[]
local function wrap_words(text, width)
	local lines, cur = {}, ""
	for word in text:gmatch("%S+") do
		if cur == "" then
			cur = word
		elseif #cur + 1 + #word <= width then
			cur = cur .. " " .. word
		else
			lines[#lines + 1] = cur
			cur = word
		end
	end
	if cur ~= "" then
		lines[#lines + 1] = cur
	end
	return lines
end

---@param component Component
---@param get_width fun(): integer  the render-time width to center within
---@return Component gate, fun(): { block: fun(b: boolean), rewrap: fun() }
local function multiwin_gate(component, get_width)
	local components = require("fibrous.inline.components")
	local controls
	local function Gate(ctx, props)
		local blocked = ctx.use_state(false)
		-- Bumped on resize while blocked: the message is wrapped at render
		-- time, and a relayout alone re-runs layout WITHOUT re-rendering
		-- components, so without this the wrap would stay at the old width.
		local nonce = ctx.use_state(0)
		controls = {
			block = blocked.set,
			rewrap = function()
				if blocked.get() then
					nonce.set(nonce.get() + 1)
				end
			end,
		}
		if not blocked.get() then
			return { comp = component, props = props }
		end
		-- One centered label per wrapped line, rather than a paragraph: the
		-- layout engine has no text-align (the `align` prop is border TITLES),
		-- and align_self can only centre a node NARROWER than its container,
		-- which a wrapped paragraph never is — it fills the width and its text
		-- sits left. Each line here is its own node, so each one centres.
		local width = math.max(get_width() - 2, 1)
		local children = {}
		for _, line in ipairs(wrap_words(MULTIWIN_MESSAGE, width)) do
			children[#children + 1] = {
				comp = components.label,
				props = { text = line, align_self = "center", style = { text_hl = "WarningMsg" } },
			}
		end
		return {
			comp = components.col,
			props = { grow = 1, justify = "center", style = { padding = { x = 1 } } },
			children = children,
		}
	end
	return Gate, function()
		return controls
	end
end

-- Mount `component` INTO an existing window: the host buffer is shown in the
-- window itself, with no covering float. Measured against M.window (see
-- design-buffer-mount.md): identical steady-state draw cost, ~2.7x cheaper
-- resize, one fewer window in the layout.
--
-- Note what this does NOT do: the host still creates and owns its buffer, so
-- this takes over a WINDOW rather than rendering into a buffer you hand it.
-- The embedder's buffer is put back on unmount.
---@param component Component
---@param props? table
---@param opts? InlineBufferMountOpts
---@return InlineSplitHandle
function M.buffer(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"
	local zindex = opts.zindex or 10
	-- Resolved NOW, for the same reason M.window does: read again long after
	-- mount, when the current window may be somebody else's.
	local winid = opts.winid
	if winid == 0 or winid == nil then
		winid = vim.api.nvim_get_current_win()
	end
	local prev_bufnr = vim.api.nvim_win_get_buf(winid)

	local function win_size()
		return {
			width = vim.api.nvim_win_get_width(winid),
			height = vim.api.nvim_win_get_height(winid),
		}
	end

	local manager, interaction -- need the host buffer in place, so attached below
	local host = inline_host.new({
		get_size = function()
			local cur = win_size()
			return { width = cur.width, height = not scroll and cur.height or nil }
		end,
		on_flush = function(damage)
			if manager then
				-- see the identical note in M.floating: explicit if, not `and/or`
				if damage == nil then
					damage = false
				end
				manager.sync(damage)
				interaction.reanchor(damage)
				interaction.update()
			end
		end,
	})

	-- THE difference from M.window: no float, the window shows the host buffer.
	vim.api.nvim_win_set_buf(winid, host.bufnr)
	local saved_wo = apply_minimal(winid)

	local group = vim.api.nvim_create_augroup("FibrousInlineBuffer_" .. winid, { clear = true })
	local axes = pinned_axes(opts)
	local pin_restore
	if axes.x or axes.y then
		pin_restore = pin_view(winid, group, axes)
	end
	-- host_winid: <C-w> from a subwindow acts on this window, which here IS the
	-- app's one real window in the layout.
	-- anchor_winid: deliberately NOT set, so subwindow floats anchor
	-- relative="editor". A pane mount can anchor to its backing pane because
	-- that pane is inert; this window is the opposite (it holds the cursor and
	-- the canvas), which is precisely the case subwin.attach warns against.
	-- The spike measured win-anchoring here as byte-identical, but that is an
	-- absence in one scene, and editor anchoring is what the floating mount
	-- already does with a cursor-bearing root.
	manager = subwin.attach(host, winid, {
		mouse = opts.mouse,
		zindex = zindex + 1,
		keys = opts.keys,
		host_winid = winid,
		-- The window shows the host buffer on Normal; map the sub-buffer floats'
		-- NormalFloat onto Normal too so the whole app reads as one background
		-- (a floating mount omits this and keeps NormalFloat, reading as an
		-- overlay). See SubwinAttachOpts.float_normal.
		float_normal = "Normal",
	})
	interaction = interact.attach(host, winid, opts.mouse, manager, nil, opts.keys, opts.anchor)

	-- Forward-declared: sync() closes over it, but it only exists once the
	-- gate is built below (which needs `winid`, resolved above).
	local get_controls

	local function sync()
		if not vim.api.nvim_win_is_valid(winid) then
			return
		end
		-- No window config to re-apply: the window IS the geometry. Resizing it
		-- is the whole event, and get_size reads the new size on the next flush.
		host.relayout()
		if pin_restore then
			pin_restore()
		end
		-- The multi-window message is wrapped at RENDER time, and a relayout
		-- does not re-render components, so it needs telling about the width.
		local controls = get_controls()
		if controls then
			controls.rewrap()
		end
	end

	local function release_root()
		if opts.own_window then
			if vim.api.nvim_win_is_valid(winid) then
				pcall(vim.api.nvim_win_close, winid, true)
			end
			return
		end
		if not vim.api.nvim_win_is_valid(winid) then
			return
		end
		for opt, value in pairs(saved_wo) do
			pcall(function()
				vim.wo[winid][opt] = value
			end)
		end
		-- Put the embedder's buffer back. If it is gone (wiped while we were
		-- mounted), leave the window on a fresh empty buffer rather than
		-- letting the host buffer's deletion close it.
		local restore = vim.api.nvim_buf_is_valid(prev_bufnr) and prev_bufnr or vim.api.nvim_create_buf(true, false)
		pcall(vim.api.nvim_win_set_buf, winid, restore)
	end

	local gate
	gate, get_controls = multiwin_gate(component, function()
		return vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_width(winid) or 40
	end)
	local handle = wire(
		gate,
		props,
		host,
		winid,
		group,
		{ manager, interaction },
		sync,
		function() end,
		opts.on_unmount,
		release_root
	)

	-- Watch for the host buffer being shown in a second window. Scheduled:
	-- these fire mid-command (a :split has not finished wiring its window when
	-- WinNew arrives), and the state change re-renders.
	local function recheck()
		local controls = get_controls()
		if not controls or not vim.api.nvim_buf_is_valid(host.bufnr) then
			return
		end
		local showing = 0
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) == host.bufnr then
				showing = showing + 1
			end
		end
		controls.block(showing > 1)
	end
	vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter", "BufWinLeave" }, {
		group = group,
		callback = function()
			vim.schedule(recheck)
		end,
	})

	handle.host_winid = winid
	handle.prev_bufnr = prev_bufnr
	return handle
end

return M
