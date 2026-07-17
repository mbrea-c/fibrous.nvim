-- ui.image: the function component fronting the `image` host leaf. It owns
-- everything non-geometric -- provider/spec resolution at render, retain on
-- mount / release on unmount via use_effect (the animation pattern) -- while
-- the leaf carries only resolved display props. Provider "text" (or
-- undecodable content) degrades to the alt text.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local ui = require("fibrous.inline.components")
local image = require("fibrous.image")
local kitty = require("fibrous.image.kitty")

local function be32(n)
  return string.char(
    math.floor(n / 2 ^ 24) % 256,
    math.floor(n / 2 ^ 16) % 256,
    math.floor(n / 2 ^ 8) % 256,
    n % 256
  )
end

local function png_b64(w, h)
  local bytes = "\137PNG\r\n\26\10" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
  return vim.base64.encode(bytes)
end

local function host_of(w)
  return inline_host.new({
    get_size = function()
      return { width = w }
    end,
  })
end

local written

local function mount(props)
  local host = host_of(12)
  local root = runtime.create_root(function()
    return { comp = ui.image, props = props }
  end, {}, { host = host }):render()
  return host, root
end

describe("ui.image", function()
  -- scoped to THIS describe: a file-level before_each would attach to the
  -- harness root and run for every spec in the whole suite
  before_each(function()
    image.reset()
    image.config.provider = "kitty"
    image.config.cell_px = { w = 10, h = 20 }
    written = {}
    image.config.writer = function(data)
      written[#written + 1] = data
    end
  end)

  after_each(function()
    image.reset()
  end)

  it("renders the placeholder grid into the buffer and transmits once", function()
    -- 30x40 px at 10x20 cell_px: 3 cols x 2 rows
    local host, root = mount({ b64 = png_b64(30, 40) })
    local lines = vim.api.nvim_buf_get_lines(host.bufnr, 0, -1, false)
    assert.equal(2, #lines)
    assert.truthy(lines[1]:find(kitty.cell(0, 0), 1, true))
    assert.truthy(lines[1]:find(kitty.cell(0, 2), 1, true))
    assert.truthy(lines[2]:find(kitty.cell(1, 0), 1, true))
    assert.equal(1, #written)
    assert.truthy(written[1]:find("a=T,U=1", 1, true))
    root:unmount()
  end)

  it("releases (deletes) on unmount", function()
    local _, root = mount({ b64 = png_b64(30, 40) })
    assert.equal(1, #written)
    root:unmount()
    assert.equal(2, #written)
    assert.truthy(written[2]:find("a=d,d=I", 1, true))
  end)

  it("two components with the same content share one transmission", function()
    local b64 = png_b64(30, 40)
    local host = host_of(12)
    local root = runtime
      .create_root(function()
        return {
          comp = ui.col,
          props = {},
          children = {
            { comp = ui.image, props = { b64 = b64 } },
            { comp = ui.image, props = { b64 = b64 } },
          },
        }
      end, {}, { host = host })
      :render()
    assert.equal(1, #written)
    root:unmount()
    assert.equal(2, #written) -- one delete, after the LAST release
    assert.truthy(written[2]:find("a=d,d=I", 1, true))
  end)

  it("provider text degrades to the alt text, nothing transmitted", function()
    image.config.provider = "text"
    local host, root = mount({ b64 = png_b64(30, 40), alt = "[fig 1]" })
    local line = vim.api.nvim_buf_get_lines(host.bufnr, 0, 1, false)[1]
    assert.truthy(line:find("[fig 1]", 1, true))
    assert.equal(0, #written)
    root:unmount()
    assert.equal(0, #written)
  end)

  it("undecodable content degrades to the alt text", function()
    local host, root = mount({ b64 = vim.base64.encode("junk that is long enough to sniff"), alt = "<broken>" })
    local line = vim.api.nvim_buf_get_lines(host.bufnr, 0, 1, false)[1]
    assert.truthy(line:find("<broken>", 1, true))
    assert.equal(0, #written)
    root:unmount()
  end)
end)
