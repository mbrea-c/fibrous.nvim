-- Bootstrap for running the fibrous examples in an isolated Neovim.
--
-- Launch a clean Neovim with only this plugin on the runtime path:
--   nvim --clean -u examples/init.lua
-- then list and run examples interactively:
--   :Examples            -- list them
--   :Example counter     -- run one (Tab-completes)
--
-- Or straight from the shell (see the Makefile):
--   make example EX=counter
--
-- `--clean` loads no user config/plugins/shada; `-u examples/init.lua` then puts
-- just our `lua/` on package.path, matching the fully-isolated environment the
-- test suite uses.

-- Resolve the repo root from this file's own location, so it works regardless of
-- the directory Neovim was started in.
local src = debug.getinfo(1, "S").source:sub(2)
local examples_dir = vim.fn.fnamemodify(src, ":p:h")
local root = vim.fn.fnamemodify(examples_dir, ":h")

package.path = table.concat({
	root .. "/lua/?.lua",
	root .. "/lua/?/init.lua",
	root .. "/?.lua",
	package.path,
}, ";")

-- name → module. Order is the listing/completion order.
local ORDER = { "hello", "counter", "form", "sidebar", "panel", "inline_scroll", "inline_fullscreen" }
local DESCRIPTIONS = {
	hello = "static floating panel",
	counter = "use_state + use_effect; buttons + external keymaps",
	form = "uncontrolled text_input with live mirror",
	sidebar = "split mount (mount_split), cursor-driven selection list",
	panel = "ACP-shaped flex layout + custom hook + checkbox plan",
	inline_scroll = "website-style scroll mode: wrapped sections, clipped input floats, focus traversal",
	inline_fullscreen = "the scroll-mode demo mounted fullscreen over the current window",
}

---@type table|nil  the currently running example's handle
local current

local function stop()
	if current and current.unmount then
		pcall(current.unmount)
	end
	current = nil
end

local function run(name)
	name = (name and name ~= "") and name or "hello"
	if not DESCRIPTIONS[name] then
		vim.notify("fibrous: unknown example '" .. name .. "'. Try :Examples", vim.log.levels.ERROR)
		return
	end
	stop()
	current = require("examples." .. name).run()
end

vim.api.nvim_create_user_command("Example", function(o)
	run(o.args)
end, {
	nargs = "?",
	complete = function()
		return ORDER
	end,
	desc = "Run a fibrous example",
})

vim.api.nvim_create_user_command("Examples", function()
	local lines = { "fibrous examples — run with :Example <name>" }
	for _, n in ipairs(ORDER) do
		lines[#lines + 1] = ("  %-9s %s"):format(n, DESCRIPTIONS[n])
	end
	vim.notify(table.concat(lines, "\n"))
end, { desc = "List fibrous examples" })

-- If launched as `make example EX=<name>`, run it straight away.
if vim.g.fibrous_example and vim.g.fibrous_example ~= "" then
	vim.schedule(function()
		run(vim.g.fibrous_example)
	end)
else
	vim.schedule(function()
		vim.notify("fibrous examples loaded. :Examples to list, :Example <name> to run.")
	end)
end
