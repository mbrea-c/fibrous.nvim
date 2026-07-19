-- Subwindow placement inside a BORDERED floating mount.
--
-- Editor-anchored subwindows take their origin from the root float's position,
-- but nvim_win_get_position reports a float's OUTER corner (border included)
-- while the content coordinates added to it are relative to the TEXT area. A
-- bordered root therefore has to contribute its border thickness, or every
-- subwindow under it lands one row up and one column left — overlapping the
-- content rendered above it.
--
-- Pane-backed mounts are unaffected: they anchor relative="win" to an inert
-- backing pane and take the get_origin() branch instead.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function subwin_of(handle)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.w[win].fibrous_anchor == handle.winid then
			return win
		end
	end
end

--- Two labels, then the input: the input sits at content row 2.
local function App()
	return {
		comp = ui.col,
		props = {},
		children = {
			{ comp = ui.label, props = { text = "row zero" } },
			{ comp = ui.label, props = { text = "row one" } },
			{ comp = ui.text_input, props = { value = "", height = 3 } },
		},
	}
end

local INPUT_CONTENT_ROW = 2

--- Mount, reveal the input (render="focus" hides it until focused) and return
--- the root and input configs.
local function placed(border)
	local handle = mount.floating(App, {}, { width = 40, height = 12, border = border, mode = "scroll" })
	local sub = subwin_of(handle)
	vim.api.nvim_set_current_win(sub)
	local root_cfg = vim.api.nvim_win_get_config(handle.winid)
	local sub_cfg = vim.api.nvim_win_get_config(sub)
	handle.unmount()
	return root_cfg, sub_cfg
end

describe("subwindow origin under a bordered floating mount", function()
	it("places the input at the text-area origin when the root has no border", function()
		local root, sub = placed("none")
		assert.equal(root.row + INPUT_CONTENT_ROW, sub.row)
		assert.equal(root.col, sub.col)
	end)

	it("offsets by the border when the root HAS one", function()
		local root, sub = placed("rounded")
		assert.equal(root.row + 1 + INPUT_CONTENT_ROW, sub.row)
		assert.equal(root.col + 1, sub.col)
	end)

	-- nvim allows asymmetric borders, so a flat +1 on both axes would be wrong:
	-- this one has left/right edges but no top or bottom.
	it("insets per axis, not a flat one cell", function()
		local root, sub = placed({ "", "", "", "│", "", "", "", "│" })
		assert.equal(root.row + INPUT_CONTENT_ROW, sub.row)
		assert.equal(root.col + 1, sub.col)
	end)
end)
