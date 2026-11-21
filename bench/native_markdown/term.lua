-- Time the resize through synchronous redraw in a child with a real PTY.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local termdraw=require("fibrous.bench.termdraw")
local receipt=vim.fn.tempname()
local init=([[
vim.o.termguicolors=true
package.path="./lua/?.lua;./lua/?/init.lua;./bench/?.lua;"..package.path
local mode=vim.env.BENCH_MODE
if mode=="lua" then
  dofile("bench/native_markdown/coalesced.lua")
end
local fixture=require("resize_fixture")
local widths=vim.env.BENCH_NARROW=="1" and {62,53,43,37,30,23,17,19,26,35,42,55} or fixture.widths
local opts={width=100,height=22,row=0,col=0,mode="scroll"}
local Host=require("fibrous.inline.host")
local host,host_opts
local new=Host.new
Host.new=function(o) host,host_opts=new(o),o;return host end
local app=require("fibrous.inline.mount").floating(fixture.scene("markdown",200),{},opts)
Host.new=new
if mode=="rust" then
  dofile("bench/native_markdown/adapter.lua").attach(host,host_opts.get_size,host_opts.on_flush)
end
local samples, fingerprints={},{}
_G.FRAME=function(i)
  opts.width=widths[i]
  local t=vim.uv.hrtime()
  app.relayout()
  vim.cmd("redraw")
  samples[i]=(vim.uv.hrtime()-t)/1e6
  fingerprints[i]=fixture.fingerprint(host)
  if i==#widths then vim.fn.writefile({vim.json.encode({samples=samples,mode=mode,
    widths=widths,fingerprint=vim.fn.sha256(table.concat(fingerprints))})},%q) end
end
]]):format(receipt)
local r=termdraw.measure({rtp={vim.fn.getcwd()},cols=110,rows=26,frames=12,init=init,
  settle_ms=1000,timeout_ms=60000})
assert(vim.fn.filereadable(receipt)==1, "incomplete PTY measurements")
local sample=vim.json.decode(vim.fn.readfile(receipt)[1])
vim.fn.delete(receipt)
assert(#sample.samples==12)
sample.bytes=r.bytes
io.write(vim.json.encode(sample).."\n")
