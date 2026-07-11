-- SpanStyle + interactive spans (the markdown-widget foundation). A span table
-- may now carry a `style` (a strict subset of the node style vocabulary:
-- text_hl + _hover, no box model), plus generic `on_click` / `role`. spans.lua
-- lowers these into byte ranges and paint-ready runs; style.span_style is the
-- restricted normalizer. Style-only spans stay byte-identical to before (see
-- spans_spec); interactive spans gain a stable logical id so every run they
-- wrap into shares it (whole-span hover, one flash target per span).

local style = require("fibrous.inline.style")
local spans = require("fibrous.inline.spans")

describe("style.span_style", function()
  it("normalizes text_hl and a _hover override", function()
    local s = style.span_style({ text_hl = "@markup.link", _hover = { text_hl = "@markup.link.hover" } })
    assert.equal("@markup.link", s.base.text_hl)
    assert.equal("@markup.link.hover", s.hover.text_hl)
  end)

  it("returns nil for a nil spec and { base } for a bare one", function()
    assert.is_nil(style.span_style(nil))
    local s = style.span_style({ text_hl = "X" })
    assert.equal("X", s.base.text_hl)
    assert.is_nil(s.hover)
  end)

  it("rejects box-model keys and unknown keys", function()
    assert.has_error(function()
      style.span_style({ border = true })
    end, "border")
    assert.has_error(function()
      style.span_style({ padding = { x = 1 } })
    end, "padding")
    assert.has_error(function()
      style.span_style({ nonsense = 1 })
    end, "nonsense")
  end)
end)

describe("spans.flatten with interactive spans", function()
  it("keeps a style-only span byte-identical to a legacy hl span", function()
    local _, legacy = spans.flatten({ { "x", hl = "Title" } })
    local _, styled = spans.flatten({ { "x", style = { text_hl = "Title" } } })
    assert.same({ { s = 1, e = 2, hl = "Title" } }, legacy)
    assert.same({ { s = 1, e = 2, hl = "Title" } }, styled)
  end)

  it("carries on_click, role, hover_hl and a stable id on an interactive span", function()
    local fn = function() end
    local text, ranges = spans.flatten({
      "see ",
      {
        "the docs",
        style = { text_hl = "@markup.link", _hover = { text_hl = "@markup.link.hover" } },
        on_click = fn,
        role = "link",
      },
      " now",
    })
    assert.equal("see the docs now", text)
    assert.equal(1, #ranges)
    local r = ranges[1]
    assert.equal(5, r.s)
    assert.equal(13, r.e)
    assert.equal("@markup.link", r.hl)
    assert.equal("@markup.link.hover", r.hover_hl)
    assert.equal(fn, r.on_click)
    assert.equal("link", r.role)
    assert.equal("number", type(r.id))
  end)

  it("gives distinct ids to distinct interactive spans", function()
    local _, ranges = spans.flatten({
      { "a", on_click = function() end },
      " ",
      { "b", on_click = function() end },
    })
    assert.equal(2, #ranges)
    assert.is_true(ranges[1].id ~= ranges[2].id)
  end)
end)

describe("spans.runs on interactive spans", function()
  it("every run of one logical span shares its id and handler", function()
    local fn = function() end
    local _, ranges = spans.flatten({ { "hello world", on_click = fn, role = "link" } })
    -- simulate a wrap that split the span across two output lines
    local a = spans.runs({ { s = 1, text = "hello" } }, ranges)
    local b = spans.runs({ { s = 7, text = "world" } }, ranges)
    assert.equal(1, #a)
    assert.equal(1, #b)
    assert.equal(a[1].id, b[1].id)
    assert.equal(fn, a[1].on_click)
    assert.equal(fn, b[1].on_click)
    assert.equal("link", a[1].role)
  end)

  it("leaves a style-only run free of interaction fields", function()
    local _, ranges = spans.flatten({ { "x", hl = "Title" } })
    local runs = spans.runs({ { s = 1, text = "x" } }, ranges)
    assert.same({ { text = "x", hl = "Title" } }, runs)
  end)
end)
