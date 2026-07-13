-- Mirror integrity across structural MOVES (keyed lists). A moved entry
-- restores the canvas under its old box before painting at the new one; in
-- a downward shift, entry N's old box overlaps entry N-1's NEW box, so the
-- restores must all run BEFORE any mirror paints (the same reason destroys
-- run first in sync) — interleaved per-entry, N's restore lands on top of
-- the mirror N-1 painted moments earlier in the same sync.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function make_buf(text)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
	return bufnr
end

local function canvas(handle)
	return table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
end

-- A keyed list of labelled raw_buffer mirrors driven by set().
local function list_app()
	local set
	local function App(ctx)
		local st = ctx.use_state({})
		set = st.set
		local children = {}
		for _, it in ipairs(st.get()) do
			children[#children + 1] = {
				comp = ui.col,
				key = it.key,
				props = {},
				children = {
					{ comp = ui.label, props = { text = "== " .. it.key } },
					{ comp = ui.raw_buffer, props = { bufnr = it.bufnr, render = "focus" } },
				},
			}
		end
		return { comp = ui.col, props = { gap = 1 }, children = children }
	end
	local handle = mount.floating(App, {}, { width = 30, height = 20 })
	return handle, function(items)
		set(items)
		vim.wait(50) -- let the coalesced mirror repaints land
	end
end

describe("inline.subwin mirror moves", function()
	it("a keyed prepend keeps every moved mirror's text", function()
		local a, b = { key = "A", bufnr = make_buf("AAAA text") }, { key = "B", bufnr = make_buf("BBBB text") }
		local handle, set = list_app()
		set({ a, b })
		assert.truthy(canvas(handle):find("AAAA text", 1, true))
		assert.truthy(canvas(handle):find("BBBB text", 1, true))

		set({ { key = "C", bufnr = make_buf("CCCC text") }, a, b })
		local text = canvas(handle)
		assert.truthy(text:find("CCCC text", 1, true), "the new mirror paints")
		assert.truthy(text:find("AAAA text", 1, true), "A moved down: mirror survives")
		assert.truthy(text:find("BBBB text", 1, true), "B moved down: mirror survives")
		handle.unmount()
	end)

	it("swapping two entries keeps both mirrors, in the new order", function()
		local a, b = { key = "A", bufnr = make_buf("AAAA text") }, { key = "B", bufnr = make_buf("BBBB text") }
		local handle, set = list_app()
		set({ a, b })

		set({ b, a })
		local text = canvas(handle)
		local pb, pa = text:find("BBBB text", 1, true), text:find("AAAA text", 1, true)
		assert.truthy(pb, "B moved up: mirror survives")
		assert.truthy(pa, "A moved down: mirror survives")
		assert.truthy(pb < pa, "the order swapped")
		handle.unmount()
	end)

	it("consecutive prepends keep converging on a correct canvas", function()
		local a = { key = "A", bufnr = make_buf("AAAA text") }
		local handle, set = list_app()
		set({ a })
		local items = { a }
		for _, key in ipairs({ "B", "C", "D" }) do
			table.insert(items, 1, { key = key, bufnr = make_buf(key:rep(4) .. " text") })
			set(vim.list_slice(items))
		end
		local text = canvas(handle)
		for _, needle in ipairs({ "AAAA text", "BBBB text", "CCCC text", "DDDD text" }) do
			assert.truthy(text:find(needle, 1, true), needle .. " present")
		end
		handle.unmount()
	end)
end)
