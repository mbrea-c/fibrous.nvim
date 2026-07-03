-- Mount targets for the inline host (tracker "NEW UI HOST" task 3). Both put
-- the host buffer in a ROOT FLOAT (tracker decision: always a root float —
-- rendering straight into a host window would let a resize clobber widgets
-- before we get to relayout, and subwindows need resize sync anyway):
--
--   floating(component)  an editor-relative float IS the app window.
--   split(component)     a native split pane provides geometry only (it holds
--                        a throwaway scratch buffer); a relative="win" float
--                        covers it edge to edge. Resizes resync the float and
--                        relayout; closing the pane tears the app down.
--
-- `opts.mode` picks the root constraint mode (tracker decision, the two core
-- use-cases): "fixed" (default) lays out at the window height — app-style UIs;
-- "scroll" lays out at nil height so the buffer grows with content and the
-- window is a natively-scrolling viewport — website-style UIs.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local subwin = require("fibrous.inline.subwin")
local interact = require("fibrous.inline.interact")

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

-- Shared mount plumbing: create the root, wire coalesced resize sync (one
-- relayout per event-loop tick, as in mount/window_host.lua) plus lifecycle
-- autocmds, and build the handle. Callers supply the geometry logic:
--   sync()        re-apply window geometry, then host.relayout()
--   on_teardown() close this target's windows (buffer deletion is the host's)
---@return InlineAppHandle handle, fun() teardown
local function wire(component, props, host, winid, group, attachments, sync, on_teardown)
	local root = runtime.create_root(component, props, { host = host })
	root:render()

	local unmounted = false
	local function teardown()
		if unmounted then
			return
		end
		unmounted = true
		pcall(vim.api.nvim_del_augroup_by_id, group)
		for _, attachment in ipairs(attachments) do
			attachment.teardown()
		end
		if vim.api.nvim_win_is_valid(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
		root:unmount()
		on_teardown()
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

-- Mount `component` as a standalone floating application.
---@param component Component
---@param props? table
---@param opts? InlineFloatingOpts
---@return InlineAppHandle
function M.floating(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"

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
		on_flush = function()
			if manager then
				manager.sync()
				interaction.update()
			end
		end,
	})
	local winid = open_root_float(host.bufnr, {
		relative = "editor",
		row = g.row,
		col = g.col,
		width = g.width,
		height = g.height,
	})
	manager = subwin.attach(host, winid)
	interaction = interact.attach(host, winid)
	local group = vim.api.nvim_create_augroup("FibrousInlineFloat_" .. winid, { clear = true })

	local function sync()
		local cur = geom()
		vim.api.nvim_win_set_config(winid, {
			relative = "editor",
			row = cur.row,
			col = cur.col,
			width = cur.width,
			height = cur.height,
		})
		host.relayout()
	end

	local handle = wire(component, props, host, winid, group, { manager, interaction }, sync, function() end)
	return handle
end

---@class InlineSplitOpts
---@field split? SplitOpts   direction/position/size of the host pane; default vertical/left/40
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"

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

	local handle = M.window(component, props, { winid = host_winid, mode = opts.mode })

	return handle
end

---@class InlineWindowMountOpts
---@field winid integer which window to mount on
---@field mode? "fixed"|"scroll"  root constraint mode; default "fixed"

-- Mount `component` over a native split pane.
---@param component Component
---@param props? table
---@param opts? InlineWindowMountOpts
---@return InlineSplitHandle
function M.window(component, props, opts)
	opts = opts or {}
	local scroll = opts.mode == "scroll"
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
		on_flush = function()
			if manager then
				manager.sync()
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
	})
	manager = subwin.attach(host, winid)
	interaction = interact.attach(host, winid)
	local group = vim.api.nvim_create_augroup("FibrousInlineSplit_" .. host_winid, { clear = true })

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
	end

	local handle, teardown = wire(component, props, host, winid, group, { manager, interaction }, sync, function()
		if vim.api.nvim_win_is_valid(host_winid) then
			pcall(vim.api.nvim_win_close, host_winid, true)
		end
	end)

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

return M
