package.path = "./lua/?.lua;./lua/?/init.lua;./bench/?.lua;" .. package.path
local dir = "bench/native_markdown/"
local mode=assert(vim.env.BENCH_MODE)
if mode=="lua" then
  dofile(dir.."coalesced.lua")
else assert(mode=="rust") end
local fixture=require("resize_fixture")
local Host=require("fibrous.inline.host")
local runtime=require("fibrous.reactive.runtime")
local sources=require("fibrous.sources")
local counts=require("throughput")
local widths=vim.env.BENCH_NARROW=="1" and {62,53,43,37,30,23,17,19,26,35,42,55} or fixture.widths
local n=tonumber(vim.env.BENCH_N) or 200
local function timed(f)
  local start=vim.uv.hrtime()
  f()
  return (vim.uv.hrtime()-start)/1e6
end
local size={width=100}
local host=Host.new({get_size=function()return size end})
local root=runtime.create_root(fixture.scene("markdown",n),{}, {host=host})
local mount=timed(function() root:render() end)
local setup=mode=="rust" and timed(function()
  dofile(dir.."adapter.lua").attach(host,function()return size end)
end) or 0
local function frame(w) size.width=w;host.relayout() end
collectgarbage("collect")
local first=timed(function() frame(64) end)
for _,w in ipairs(widths) do frame(w) end
collectgarbage("collect")
local samples={}
for _=1,2 do
  for _,w in ipairs(widths) do samples[#samples+1]=timed(function() frame(w) end) end
end
-- Fresh resize with a real synchronous source projection, timed independently.
local result,queried={},{}
for _,w in ipairs(widths) do
  queried[#queried+1]=timed(function() frame(w); result=sources.project("resize", 14, 96) end)
end
assert(#result>0)
local counted=counts.counting(function() frame(widths[7]) end)
local fingerprint=fixture.fingerprint(host)
io.write(vim.json.encode({mode=mode,widths=widths,n=n,samples=samples,query_samples=queried,
  setup=setup,mount=mount,first=first,fingerprint=fingerprint,writes=counted.writes,cells=counted.cells}).."\n")
