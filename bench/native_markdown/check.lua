-- Run from the Fibrous checkout with nvim --headless -u NONE -l <this file>.
package.path = "./lua/?.lua;./lua/?/init.lua;./bench/?.lua;" .. package.path
local fixture = require("markdown_fixture")
local ui = require("fibrous.inline.components")
local Host = require("fibrous.inline.host")
local runtime = require("fibrous.reactive.runtime")
local sources = require("fibrous.sources")
local candidate = dofile("bench/native_markdown/adapter.lua")
local function mount(text, id)
  local size = { width = 100 }
  local host = Host.new({ get_size = function() return size end })
  local root = runtime.create_root(function()
    return {comp = ui.markdown, props = {text = text, source = {id = id, text = text, offset = 7}}}
  end, {}, {host = host})
  root:render()
  return size, host, root
end
local function marks(host)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, {details = true})) do
    out[#out+1] = {m[2], m[3], m[4].end_row, m[4].end_col, m[4].hl_group}
  end
  return out
end
local function compare(a,b,label)
  if not vim.deep_equal(a,b) then
    error(label .. "\nexpected " .. vim.inspect(a):sub(1,3000) .. "\nactual " .. vim.inspect(b):sub(1,3000))
  end
end
local function project(id, a, b)
  local out = sources.project(id, a, b)
  for _, p in ipairs(out) do p.bufnr = nil end
  return out
end
local function resolve(buf, row, col, last)
  local out = sources.resolve(buf, {lnum=row,col=col,end_lnum=row,end_col=last})
  for _, p in ipairs(out) do p.source = p.source.text end
  return out
end
local function check(text, widths)
  local size, ref, a = mount(text,"reference")
  local other, rust, b = mount(text,"candidate")
  candidate.attach(rust, function() return other end)
  for _, w in ipairs(widths or {99,64,43,29,17,11,36,100,100}) do
    size.width, other.width = w,w
    ref.relayout()
    rust.relayout()
    local lines = vim.api.nvim_buf_get_lines(ref.bufnr,0,-1,false)
    compare(lines,vim.api.nvim_buf_get_lines(rust.bufnr,0,-1,false),"lines width "..w)
    compare(marks(ref),marks(rust),"highlights width "..w)
    -- All single-byte projections include unmapped delimiters, clipped bytes and gaps.
    for byte=7,7+#text-1 do
      compare(project("reference",byte,byte+1),project("candidate",byte,byte+1),"projection width "..w.." byte "..byte)
    end
    for row,line in ipairs(lines) do
      compare(resolve(ref.bufnr,row,1,#line),resolve(rust.bufnr,row,1,#line),"selection width "..w.." row "..row)
    end
  end
  sources.clear(ref.bufnr); sources.clear(rust.bufnr)
  a:unmount(); b:unmount()
end
check(fixture.document(2))
check("# Heading\n\nlong_abcdefghijklmnopqrstuvwxyz123456,  **bold  word** and [a link](https://example.org) café 界面 é.\n\n1. hello   world\n2. again\n\n> quote with *styled text* and more words\n>\n> another paragraph\n\n```lua\nlocal x = 123456789123456789123456789\n```")
-- A styled wide glyph cut in half by the viewport keeps the color of the
-- visible half. The clipped glyph has no logical source or clickable cell.
check("| Name | Value |\n| :--- | ---: |\n| **界面** | [open guide](guide) |\n\n$$\n\\frac{a+b}{c}\n$$",
  {1, 2, 3, 8, 12, 30, 72})
print("Matched text, extmarks, per-byte projections and row selections.")
