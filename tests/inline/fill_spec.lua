-- `fill`: a text node whose content is GENERATED from its measured box width at
-- layout time, rather than measured from fixed text. `props.fill` is a
-- `function(width) -> string | span-list` called once the node's content box is
-- final (so it fills a stretched/grown box exactly), and re-called on every
-- relayout — so it tracks a resize WITHOUT a component re-render (the layout
-- pass runs on resize; components memoize). The width-aware activity indicators
-- (weave's water line) need this to span their column.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local ui = require("fibrous.inline.components")

local function line0(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
end

describe("inline.fill", function()
  it("generates content from the measured width and re-fills on resize", function()
    local w = 8
    local seen = {}
    local host = inline_host.new({
      get_size = function()
        return { width = w }
      end,
    })
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.label,
            props = {
              fill = function(cw)
                seen[#seen + 1] = cw
                return ("="):rep(cw)
              end,
            },
          },
        },
      }
    end
    local root = runtime.create_root(App, {}, { host = host }):render()
    assert.equal(("="):rep(8), line0(host.bufnr)) -- stretched to the full column width

    w = 14
    host.relayout() -- a pure resize: layout re-runs, the component does NOT
    assert.equal(("="):rep(14), line0(host.bufnr)) -- re-filled to the new width
    assert.same({ 8, 14 }, seen)
    root:unmount()
  end)

  it("a fill span-list carries its highlights", function()
    local host = inline_host.new({
      get_size = function()
        return { width = 4 }
      end,
    })
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.label,
            props = {
              fill = function(cw)
                local spans = {}
                for i = 1, cw do
                  spans[i] = { "x", hl = "Title" }
                end
                return spans
              end,
            },
          },
        },
      }
    end
    local root = runtime.create_root(App, {}, { host = host }):render()
    assert.equal("xxxx", line0(host.bufnr))
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "Title" then
        found = true
      end
    end
    assert.is_true(found)
    root:unmount()
  end)
end)
