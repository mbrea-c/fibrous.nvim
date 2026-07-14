-- Headless test runner. Invoked as:
--   nvim --headless -u NONE -i NONE -l tests/run.lua [path/to/file_spec.lua]
--
-- With no argument, discovers and runs every tests/**/*_spec.lua. With a path
-- argument, runs only that spec file (useful for focused TDD).
--
-- Exits non-zero if any test fails, so `make test` / CI can gate on it.

local root = vim.fn.getcwd()

-- Only our own lua/ goes on the module path; nothing else is loaded, so test
-- failures can never be confused with a stray plugin or user config.
-- Neovim's runtimepath loader beats package.path, so a fibrous installed in
-- the running nvim (e.g. a nix vim-pack-dir) would silently shadow the
-- working tree under test. Prepend the tree so the suite tests THIS checkout.
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  package.path,
}, ";")

local harness = require("tests.harness")
harness.expose()

local arg_file = _G.arg and _G.arg[1]
local specs
if arg_file and arg_file ~= "" then
  specs = { vim.fn.fnamemodify(arg_file, ":p") }
else
  specs = vim.fn.glob(root .. "/tests/**/*_spec.lua", false, true)
end

table.sort(specs)

if #specs == 0 then
  io.write("no spec files found\n")
  vim.cmd("cquit 1")
end

for _, spec in ipairs(specs) do
  local chunk, load_err = loadfile(spec)
  if not chunk then
    io.write(("ERROR loading %s: %s\n"):format(spec, load_err))
    vim.cmd("cquit 1")
  end
  local ok, err = pcall(chunk)
  if not ok then
    io.write(("ERROR running %s: %s\n"):format(spec, tostring(err)))
    vim.cmd("cquit 1")
  end
end

local results = harness.run()
-- cquit sets the editor exit code; -l otherwise exits 0 even on failures.
vim.cmd("cquit " .. (results.failed == 0 and 0 or 1))
