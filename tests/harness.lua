-- A tiny, zero-dependency test harness (busted-flavored) that runs inside
-- headless Neovim with no plugins or user config loaded.
--
-- It deliberately avoids external dependencies (busted/plenary/luassert) so the
-- test environment is fully isolated and reproducible: `nvim -u NONE` loads no
-- config and no plugins, and the only thing on package.path is our own `lua/`.
--
-- Specs use the familiar globals `describe`, `it`, `before_each`,
-- `after_each`, and a small `assert` table. Tests are collected into a tree as
-- the spec files load, then executed depth-first so `before_each`/`after_each`
-- hooks apply to every `it` in their `describe` regardless of declaration order.

local M = {}

---------------------------------------------------------------------------
-- Assertions
---------------------------------------------------------------------------

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function pretty(v)
  return vim.inspect(v)
end

local function fail(msg)
  error({ __assertion = true, message = msg }, 2)
end

-- Callable like Lua's built-in `assert(v, msg)` so source code under test that
-- uses the standard global keeps working, while `assert.equal(...)` etc. provide
-- the spec DSL (this mirrors how luassert behaves).
local assert_t = setmetatable({}, {
  __call = function(_, v, message)
    if not v then
      error(message or "assertion failed!", 2)
    end
    return v
  end,
})

function assert_t.equal(expected, got)
  if expected ~= got then
    fail(("expected %s, got %s"):format(pretty(expected), pretty(got)))
  end
end

function assert_t.same(expected, got)
  if not deep_equal(expected, got) then
    fail(("expected (deep) %s, got %s"):format(pretty(expected), pretty(got)))
  end
end

function assert_t.is_true(v)
  if v ~= true then fail(("expected true, got %s"):format(pretty(v))) end
end

function assert_t.is_false(v)
  if v ~= false then fail(("expected false, got %s"):format(pretty(v))) end
end

function assert_t.truthy(v)
  if not v then fail(("expected truthy, got %s"):format(pretty(v))) end
end

function assert_t.falsy(v)
  if v then fail(("expected falsy, got %s"):format(pretty(v))) end
end

function assert_t.is_nil(v)
  if v ~= nil then fail(("expected nil, got %s"):format(pretty(v))) end
end

function assert_t.is_not_nil(v)
  if v == nil then fail("expected non-nil, got nil") end
end

-- reference (identity) equality, distinct from `equal` for clarity at call site
function assert_t.rawequal(a, b)
  if not rawequal(a, b) then
    fail(("expected same reference: %s vs %s"):format(pretty(a), pretty(b)))
  end
end

function assert_t.has_error(fn, expected_substr)
  local ok, err = pcall(fn)
  if ok then fail("expected function to error, but it did not") end
  if expected_substr then
    local msg = type(err) == "table" and (err.message or pretty(err)) or tostring(err)
    if not msg:find(expected_substr, 1, true) then
      fail(("error %q did not contain %q"):format(msg, expected_substr))
    end
  end
end

function assert_t.has_no_error(fn)
  local ok, err = pcall(fn)
  if not ok then
    local msg = type(err) == "table" and (err.message or pretty(err)) or tostring(err)
    fail("expected no error, but got: " .. msg)
  end
end

---------------------------------------------------------------------------
-- Test tree collection
---------------------------------------------------------------------------

local root = { name = "", kind = "describe", children = {}, befores = {}, afters = {} }
local current = root

local function describe(name, fn)
  local node = { name = name, kind = "describe", children = {}, befores = {}, afters = {} }
  table.insert(current.children, node)
  local parent = current
  current = node
  fn()
  current = parent
end

local function it(name, fn)
  table.insert(current.children, { name = name, kind = "test", fn = fn })
end

local function before_each(fn)
  table.insert(current.befores, fn)
end

local function after_each(fn)
  table.insert(current.afters, fn)
end

---------------------------------------------------------------------------
-- Execution
---------------------------------------------------------------------------

-- Install the spec DSL as globals. Returns nothing; call before loading specs.
function M.expose()
  _G.describe = describe
  _G.it = it
  _G.before_each = before_each
  _G.after_each = after_each
  _G.assert = assert_t
  -- reset tree so repeated runs in one process are clean
  root.children = {}
  current = root
end

local function run_node(node, befores, afters, path, results)
  if node.kind == "test" then
    local full = path .. " " .. node.name
    -- run befores outer->inner
    local ok, err = pcall(function()
      for _, b in ipairs(befores) do b() end
      node.fn()
    end)
    -- run afters inner->outer regardless of test outcome
    for i = #afters, 1, -1 do pcall(afters[i]) end
    if ok then
      results.passed = results.passed + 1
      io.write(".")
    else
      results.failed = results.failed + 1
      local msg = type(err) == "table" and (err.message or pretty(err)) or tostring(err)
      table.insert(results.failures, { name = full, message = msg })
      io.write("F")
    end
  else
    local b2 = vim.list_extend(vim.list_extend({}, befores), node.befores)
    local a2 = vim.list_extend(vim.list_extend({}, afters), node.afters)
    local p2 = node.name == "" and path or (path .. " > " .. node.name)
    for _, child in ipairs(node.children) do
      run_node(child, b2, a2, p2, results)
    end
  end
end

-- Run the collected tree. Returns results table with passed/failed/failures.
function M.run()
  local results = { passed = 0, failed = 0, failures = {} }
  run_node(root, {}, {}, "", results)
  io.write("\n\n")
  if #results.failures > 0 then
    for _, f in ipairs(results.failures) do
      io.write(("FAIL: %s\n      %s\n"):format(f.name, f.message))
    end
    io.write("\n")
  end
  io.write(("%d passed, %d failed\n"):format(results.passed, results.failed))
  return results
end

return M
