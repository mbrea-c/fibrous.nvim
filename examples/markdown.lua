-- The markdown widget: render markdown source as rich, interactive blocks.
-- Demonstrates ui.markdown — a pure-Lua parser (no treesitter) feeding the
-- shared document renderer — with headings, inline emphasis/code, LINKS that
-- are real interactive spans (move onto one and press <CR>, or click it),
-- lists, GFM task lists and tables, blockquotes, and fenced code.

local nr = require("fibrous")
local ui = nr.ui
local util = require("examples.util")

local SOURCE = table.concat({
  "# Markdown in fibrous",
  "",
  "Render **markdown** *source* as rich blocks, with `inline code` and a",
  "[clickable link](https://example.com) that hovers, clicks, and flash-jumps",
  "like any other widget.",
  "",
  "## Lists",
  "",
  "- a plain bullet",
  "- a bullet with `code`",
  "- [x] a finished task",
  "- [ ] a pending task",
  "",
  "## Tables",
  "",
  "| Language | Speed  | Note        |",
  "| :------- | -----: | :---------: |",
  "| lua      |   fast | **vendored** |",
  "| vimscript| slower | legacy      |",
  "",
  "## Quotes and code",
  "",
  "> Blockquotes render with a rule and padding,",
  "> across as many lines as you like.",
  "",
  "```lua",
  "local function add(a, b)",
  "  return a + b",
  "end",
  "```",
  "",
  "## Math",
  "",
  "Inline math like $E = mc^2$ and $\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$ flows",
  "with the prose, including fonts and accents like $\\mathbf{v} \\cdot \\hat{n}$.",
  "Display math renders stacked, with fences that grow to their content:",
  "",
  "$$",
  "\\left[ \\frac{n(n+1)}{2} \\right]^2 = \\sum_{k=1}^{n} k^3",
  "$$",
  "",
  "More display math:",
  "",
  "$$",
  "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}",
  "$$",
  "",
  "Nesting works too -- a continued fraction, a nested radical, and a sum:",
  "",
  "$$",
  "\\frac{1}{1 + \\frac{1}{1 + \\frac{1}{x}}}",
  "$$",
  "",
  "$$",
  "\\phi = \\frac{1 + \\sqrt{5}}{2}",
  "$$",
  "",
  "$$",
  "\\sum_{k=1}^{n} \\frac{1}{k^2} = \\frac{\\pi^2}{6}",
  "$$",
  "",
  "Big operators grow, with limits stacked above and below -- a summation, a",
  "definite integral, and a nested radical:",
  "",
  "$$",
  "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
  "$$",
  "",
  "$$",
  "\\sqrt{\\frac{a + b}{c + d}}",
  "$$",
  "",
  "### Matrices, determinants, and cases",
  "",
  "Environments lay out as real grids, with brackets grown to fit:",
  "",
  "$$",
  "A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
  "$$",
  "",
  "$$",
  "\\det A = \\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix} = ad - bc",
  "$$",
  "",
  "A piecewise definition with a brace that spans its rows:",
  "",
  "$$",
  "|x| = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}",
  "$$",
  "",
  "### Named operators, sums, and derivations",
  "",
  "The binomial theorem, a summand carrying a binomial coefficient:",
  "",
  "$$",
  "(x + y)^n = \\sum_{k=0}^{n} \\binom{n}{k} x^k y^{n-k}",
  "$$",
  "",
  "A derivative from first principles -- \\lim stacks its limit below:",
  "",
  "$$",
  "f'(x) = \\lim_{h \\to 0} \\frac{f(x + h) - f(x)}{h}",
  "$$",
  "",
  "An aligned derivation, lined up on the = column:",
  "",
  "$$",
  "\\begin{aligned} (a + b)^2 &= a^2 + 2ab + b^2 \\\\ &= (a + b)(a + b) \\end{aligned}",
  "$$",
  "",
  "### Vectors and fonts",
  "",
  "Wide arrows for vectors, and blackboard, script and fraktur alphabets:",
  "",
  "$$",
  "\\overrightarrow{AB} = \\vec{v}, \\quad \\nabla \\times \\vec{F}",
  "$$",
  "",
  "Fields $\\mathbb{R} \\subset \\mathbb{C}$, a Lie algebra $\\mathfrak{g}$, a",
  "Lagrangian $\\mathcal{L}$, and Euler's identity $e^{i\\pi} + 1 = 0$.",
  "",
  "Move the cursor onto the link above and press <CR>.  Press  q  to close.",
}, "\n")

local function Doc()
  return {
    comp = ui.col,
    props = { grow = 1, style = { padding = { x = 2, y = 1 } } },
    children = {
      {
        comp = ui.markdown,
        props = {
          text = SOURCE,
          on_link = function(url)
            vim.notify("open link: " .. url)
          end,
        },
      },
    },
  }
end

local M = {}

function M.run()
  local handle = nr.mount(Doc, {}, { width = 62, height = 30, mode = "scroll" })
  handle.focus()
  return util.bind(handle, {
    { "n", "q", function() handle.unmount() end, { desc = "close example" } },
  })
end

return M
