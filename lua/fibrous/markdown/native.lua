-- Optional retained Markdown renderer. Loading Fibrous does not load this module.
local M = {}
local loaded, library, failure

local function load()
  if loaded then
    return library, failure
  end
  loaded = true
  if not jit then
    failure = "LuaJIT is required"
    return nil, failure
  end
  local paths = vim.api.nvim_get_runtime_file("lib/libfibrous_markdown_native.*", false)
  -- The source tree also works when package.path, rather than runtimepath, is set.
  local source = debug.getinfo(1, "S").source:sub(2)
  local root = source:match("^(.*)/lua/fibrous/markdown/native.lua$")
  if #paths == 0 and root then
    for _, ext in ipairs({ "so", "dylib", "dll" }) do
      paths[#paths + 1] = root .. "/lib/libfibrous_markdown_native." .. ext
    end
  end
  for _, path in ipairs(paths) do
    local ok, entry = pcall(package.loadlib, path, "luaopen_fibrous_markdown_native")
    if ok and entry then
      local success, result = pcall(entry)
      if success and type(result) == "table" and result.abi_version == 1 and type(result.compile) == "function" then
        library = result
        return library
      end
    end
  end
  failure = "native module unavailable or incompatible"
  return nil, failure
end

-- Internal eligibility guard: do not accelerate arbitrary UI layout with the
-- Markdown-specific algorithm. In particular, a virtual transcript is not one
-- retained document and must stay on the viewport-aware Lua path.
local function eligible(tree)
  return tree and tree.props and tree.props._markdown == true
end

---@param host InlineHost
---@param opts InlineHostOpts
function M.install(host, opts)
  host.markdown_backend = "lua"
  local commit, teardown = host.commit, host.teardown
  local attempted, installed
  host.teardown = function(...)
    attempted = nil
    local result = teardown(...)
    -- Release the optional renderer's retained snapshot even when the caller
    -- keeps a closed mount handle. Do not change ordinary Lua teardown/GC.
    local target = host.root_target
    target.tree, target.canvas, target.visible_band = nil, nil, nil
    target.prev_lines, target.prev_hl_rows = nil, nil
    target.canvas_lines, target.subwins, host.canvas_lines = {}, {}, {}
    return result
  end
  host.commit = function(...)
    local result = commit(...)
    if installed or opts.get_size().height or not eligible(host.tree) or attempted == host.tree then
      return result
    end
    attempted = host.tree
    local lib, reason = load()
    if lib then
      local ok, err = pcall(function()
        require("fibrous.markdown.native_adapter").attach(host, opts.get_size, opts.on_flush, lib, eligible)
      end)
      if ok then
        installed, attempted = true, nil
        return result
      end
      reason = tostring(err)
    end
    host.markdown_fallback = reason
    return result
  end
end

-- Test seam for missing/incompatible library paths, not a runtime configuration API.
function M._reset_loader()
  loaded, library, failure = nil, nil, nil
end

return M
