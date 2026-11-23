-- Fg runs over background fills: the canvas keeps ONE hl per cell, so a
-- styled run painted over a fill replaces the fill's group. hlmix composes
-- the two — the run's attributes over the fill's background — instead of
-- letting a fg-only group punch a window-bg hole in the surface (weave's
-- user bubble: the tinted ❯ marker, @markup.* spans and the painted border
-- all dropped the bubble bg).

local mount = require("fibrous.inline.mount")

local col = { __host = "col" }
local text = { __host = "text" }

local function marks_of(bufnr)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
		out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
	end
	return out
end

local function resolved(name)
	return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- The first mark whose group resolves to `want` (attr subset match).
local function mark_resolving(bufnr, want)
	for _, m in ipairs(marks_of(bufnr)) do
		local r = resolved(m.hl)
		local ok = true
		for k, v in pairs(want) do
			if r[k] ~= v then
				ok = false
				break
			end
		end
		if ok then
			return m
		end
	end
	return nil
end

describe("inline.hlmix composition", function()
	local fill_bg = 0x333344
	local fg_red = 0xff0000
	before_each(function()
		vim.api.nvim_set_hl(0, "TestFill", { bg = fill_bg })
		vim.api.nvim_set_hl(0, "TestFg", { fg = fg_red, italic = true })
		vim.api.nvim_set_hl(0, "TestChip", { fg = 0x00ff00, bg = 0x222222 })
	end)

	it("a fg-only run inside a fill keeps the fill's background", function()
		local function App()
			return {
				comp = col,
				props = { style = { hl = "TestFill" } },
				children = { { comp = text, props = { text = "hi", style = { text_hl = "TestFg" } } } },
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 2 })
		local m = mark_resolving(handle.bufnr, { bg = fill_bg, fg = fg_red, italic = true })
		assert.is_not_nil(m, "no composed mark: " .. vim.inspect(marks_of(handle.bufnr)))
		handle.unmount()
	end)

	it("a run with its own background keeps its group untouched", function()
		local function App()
			return {
				comp = col,
				props = { style = { hl = "TestFill" } },
				children = { { comp = text, props = { text = "chip", style = { text_hl = "TestChip" } } } },
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 2 })
		local found
		for _, m in ipairs(marks_of(handle.bufnr)) do
			if m.hl == "TestChip" then
				found = m
			end
		end
		assert.is_not_nil(found, "the chip's own group must survive")
		handle.unmount()
	end)

	it("a painted border keeps the fill behind it", function()
		local function App()
			return {
				comp = col,
				props = { style = { hl = "TestFill", border = "rounded", border_hl = "TestFg" } },
				children = { { comp = text, props = { text = "x" } } },
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 4 })
		local m = mark_resolving(handle.bufnr, { bg = fill_bg, fg = fg_red })
		assert.is_not_nil(m, "border cells lost the fill: " .. vim.inspect(marks_of(handle.bufnr)))
		handle.unmount()
	end)

	it("adds a newly opaque fill underneath an existing foreground run", function()
		vim.api.nvim_set_hl(0, "TestClearFill", {})
		local mark_hl = require("fibrous.inline.hlmix").mix("TestClearFill", "TestFg")
		assert.is_nil(resolved(mark_hl).bg)
		vim.api.nvim_set_hl(0, "TestClearFill", { bg = fill_bg })
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "hlmix_test" })
		local updated = vim.wait(250, function() return resolved(mark_hl).bg == fill_bg end)
		assert.is_true(updated)
		assert.is_nil(resolved("TestFg").bg)
	end)

	it("updates an existing mark after other ColorScheme callbacks restore its colors", function()
		local function App()
			return {
				comp = col,
				props = { style = { hl = "TestFill" } },
				children = { { comp = text, props = { text = "draft", style = { text_hl = "TestFg" } } } },
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 2 })
		local mark = mark_resolving(handle.bufnr, { bg = fill_bg, fg = fg_red })
		assert.is_not_nil(mark)
		vim.api.nvim_set_hl(0, "TestFill", {})
		vim.api.nvim_set_hl(0, "TestFg", {})
		vim.api.nvim_create_autocmd("ColorScheme", {
			pattern = "hlmix_test",
			once = true,
			callback = function()
				vim.api.nvim_set_hl(0, "TestFill", { bg = 0x223344 })
				vim.api.nvim_set_hl(0, "TestFg", { fg = 0x99aabb, bold = true })
			end,
		})
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "hlmix_test" })
		local updated = vim.wait(250, function()
			local hl = resolved(mark.hl)
			return hl.bg == 0x223344 and hl.fg == 0x99aabb and hl.bold
		end)
		handle.unmount()
		assert.is_true(updated, "the existing extmark must pick up the final fill and text colors")
	end)

	it("an incremental repaint composes like the full paint", function()
		local setter
		local function App(ctx)
			local s = ctx.use_state("one")
			setter = s
			return {
				comp = col,
				props = { style = { hl = "TestFill" } },
				children = {
					{ comp = text, props = { text = "head" } },
					{ comp = text, props = { text = s.get(), style = { text_hl = "TestFg" } } },
				},
			}
		end
		local handle = mount.floating(App, {}, { width = 10, height = 3 })
		setter.set("two!")
		local m = mark_resolving(handle.bufnr, { bg = fill_bg, fg = fg_red, italic = true })
		assert.is_not_nil(m, "repaint dropped the composition: " .. vim.inspect(marks_of(handle.bufnr)))
		handle.unmount()
	end)
end)
