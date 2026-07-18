-- A subwin mirror beside an image must not destroy the image's highlight
-- extmarks. mirror() rewrites shared rows via set_text (collapsing marks
-- through gravity) and then repairs them from the host's retained spans,
-- translating canvas byte cols through display cells when the line diverged.
-- That translation walks clusters: when the cluster iterator wrongly merged a
-- whole placeholder run into one giant cluster (is_combining treated
-- U+10EEEE as a combining mark), every interior cell resolved to the run's
-- END and the repaired marks came back zero-width — the image row simply
-- vanished (found on the fibrous-docs homepage, where every example preview
-- shares its rows with the editor raw_buffer).

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")
local image = require("fibrous.image")

local function be32(n)
  return string.char(
    math.floor(n / 2 ^ 24) % 256,
    math.floor(n / 2 ^ 16) % 256,
    math.floor(n / 2 ^ 8) % 256,
    n % 256
  )
end

-- Just the magic + IHDR: all fibrous.image.dims needs for sizing.
local function png_bytes(w, h)
  return "\137PNG\r\n\26\10" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
end

describe("image highlight marks beside a subwin mirror", function()
  before_each(function()
    image.reset()
    image.config.provider = "kitty"
    image.config.cell_px = { w = 10, h = 20 }
    image.config.writer = function() end
  end)

  after_each(function()
    image.reset()
  end)

  it("mirror row writes keep every image row's span intact", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two", "line three", "line four" })

    local handle = mount.floating(function()
      return {
        comp = ui.row,
        props = { gap = 2 },
        children = {
          {
            comp = ui.col,
            props = { grow = 3 },
            children = {
              { comp = ui.raw_buffer, props = { bufnr = buf, height = 6, style = { border = true } } },
            },
          },
          {
            comp = ui.col,
            props = { grow = 1, min_width = 24, style = { border = "rounded", padding = { x = 2, y = 1 } } },
            children = {
              { comp = ui.image, props = { data = png_bytes(200, 80), cols = 20 } },
            },
          },
        },
      }
    end, {}, { width = 100, height = 30, row = 0, col = 0, mode = "scroll" })

    local ph = vim.fn.nr2char(0x10EEEE)
    local seen = 0
    for lnum0, line in ipairs(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)) do
      local _, clusters = line:gsub(ph, "")
      if clusters > 0 then
        seen = seen + 1
        local row0 = lnum0 - 1
        local marks = vim.api.nvim_buf_get_extmarks(handle.bufnr, -1, { row0, 0 }, { row0, -1 }, { details = true })
        local covered = 0
        for _, m in ipairs(marks) do
          local d = m[4]
          if d.hl_group and tostring(d.hl_group):find("FibrousImage") and d.end_col then
            covered = covered + (d.end_col - m[3])
          end
        end
        -- each placeholder cluster is 8 bytes; the id hl must cover them all
        assert.equal(clusters * 8, covered, "image hl span broken on row " .. row0)
      end
    end
    assert.equal(4, seen, "expected 4 image rows on the canvas")
    handle.unmount()
  end)
end)
