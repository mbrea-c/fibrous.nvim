-- The `image` node kind: a first-class leaf in the layout/render pipeline.
-- Layout measures the placeholder grid from props.image (cols x rows); render
-- paints it procedurally -- one self-describing U+10EEEE cluster per cell,
-- id-encoding hl group on every cell -- clipped by the content box like any
-- other content. One extmark per row falls out of the canvas row_spans merge.

local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local kitty = require("fibrous.image.kitty")

local function image_node(img, props)
  return vim.tbl_extend("force", { kind = "image", props = vim.tbl_extend("force", { image = img }, props or {}) }, {})
end

local function row(r, cols)
  local out = {}
  for cl = 0, cols - 1 do
    out[#out + 1] = kitty.cell(r, cl)
  end
  return table.concat(out)
end

describe("image node kind", function()
  it("measures as its placeholder grid", function()
    local tree = image_node({ id = 1, hl = "Img", cols = 3, rows = 2 })
    layout.compute(tree, { width = 10 })
    assert.same({ w = 3, h = 2 }, tree.size)
  end)

  it("paints one placeholder cluster per cell, hl on every cell", function()
    local tree = image_node({ id = 1, hl = "Img", cols = 3, rows = 2 })
    layout.compute(tree, { width = 3 })
    local c = render.paint(tree, 3, 2)
    assert.same({ row(0, 3), row(1, 3) }, c:lines())
    -- one merged span per row, over the clusters' full byte range
    assert.same({
      { row = 0, start_col = 0, end_col = #row(0, 3), hl = "Img" },
      { row = 1, start_col = 0, end_col = #row(1, 3), hl = "Img" },
    }, c:highlights())
  end)

  it("clips to the content box: fewer columns simply show fewer image columns", function()
    local tree = image_node({ id = 1, hl = "Img", cols = 5, rows = 1 }, { width = 3 })
    layout.compute(tree, { width = 3 })
    local c = render.paint(tree, 3, 1)
    assert.same({ row(0, 3) }, c:lines())
  end)

  it("clips rows at the bottom of the content box", function()
    local tree = image_node({ id = 1, hl = "Img", cols = 2, rows = 4 }, { height = 2 })
    layout.compute(tree, { width = 2, height = 2 })
    local c = render.paint(tree, 2, 2)
    assert.same({ row(0, 2), row(1, 2) }, c:lines())
  end)

  it("lays out inside containers like any leaf", function()
    local img = image_node({ id = 1, hl = "Img", cols = 2, rows = 1 })
    local tree = {
      kind = "col",
      props = { align = "start" }, -- keep the leaf at its measured width
      children = { { kind = "text", text = "above" }, img },
    }
    layout.compute(tree, { width = 10 })
    assert.same({ x = 0, y = 1, w = 2, h = 1 }, img.rect)
  end)

  it("an image node without resolved props measures empty", function()
    local tree = image_node(nil)
    layout.compute(tree, { width = 10 })
    assert.same({ w = 0, h = 0 }, tree.size)
    assert.has_no_error(function()
      render.paint(tree, 10, 1)
    end)
  end)
end)
