local M = { native_markdown = require("fibrous._native_defaults") }

---@param opts? { native_markdown?: boolean }
function M.setup(opts)
  opts = opts or {}
  if opts.native_markdown ~= nil then
    assert(type(opts.native_markdown) == "boolean", "fibrous: native_markdown must be boolean")
    M.native_markdown = opts.native_markdown
  end
end

return M
