-- Pure-Lua LaTeX math rendering. A shared recursive-descent parser turns a TeX
-- string into a small math AST, and two backends render it: `single` (a flat
-- Unicode line, for inline $...$) and `stack` (a 2D box layout, for display
-- $$...$$). No treesitter, no binary, so it runs everywhere fibrous does,
-- including the WASM docs site. Anything the parser does not understand degrades
-- to the command name or the literal source rather than erroring.
--
-- Scope (documented subset, expandable): symbols (Greek, operators, relations,
-- arrows, big operators), `^`/`_` scripts, `\frac`, `\sqrt`, `{...}` groups,
-- fonts (`\mathbf`, `\mathit`, `\boldsymbol`, `\mathrm`, `\text`), accents
-- (`\hat`, `\dot`, `\bar`, `\vec`, `\tilde`), spacing (`\quad`, `\qquad`), and
-- `\left…\right` fences sized to their content. Matrices and environments fall
-- through as plain text; variables are NOT auto-italicised (opt in via \mathit).

local M = {}

-- ── symbol tables ────────────────────────────────────────────────────────────

-- \command -> Unicode. Kept intentionally common; unknowns pass through as the
-- bare command name (graceful).
local SYMBOLS = {
  -- greek lower
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ε", varepsilon = "ε",
  zeta = "ζ", eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ", lambda = "λ",
  mu = "μ", nu = "ν", xi = "ξ", pi = "π", rho = "ρ", sigma = "σ", tau = "τ", upsilon = "υ",
  phi = "φ", varphi = "φ", chi = "χ", psi = "ψ", omega = "ω",
  -- greek upper
  Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π", Sigma = "Σ",
  Upsilon = "Υ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
  -- operators
  times = "×", div = "÷", pm = "±", mp = "∓", cdot = "·", ast = "∗", star = "⋆",
  circ = "∘", bullet = "•", oplus = "⊕", otimes = "⊗", setminus = "∖",
  -- relations
  leq = "≤", le = "≤", geq = "≥", ge = "≥", neq = "≠", ne = "≠", equiv = "≡",
  approx = "≈", sim = "∼", simeq = "≃", cong = "≅", propto = "∝", ll = "≪", gg = "≫",
  -- sets and logic
  ["in"] = "∈", notin = "∉", subset = "⊂", subseteq = "⊆", supset = "⊃", supseteq = "⊇",
  cup = "∪", cap = "∩", emptyset = "∅", varnothing = "∅", forall = "∀", exists = "∃",
  neg = "¬", land = "∧", lor = "∨",
  -- arrows
  to = "→", rightarrow = "→", leftarrow = "←", Rightarrow = "⇒", Leftarrow = "⇐",
  leftrightarrow = "↔", Leftrightarrow = "⇔", iff = "⇔", mapsto = "↦",
  -- big operators / calculus
  sum = "∑", prod = "∏", int = "∫", oint = "∮", bigcup = "⋃", bigcap = "⋂",
  partial = "∂", nabla = "∇", infty = "∞",
  -- dots and misc
  cdots = "⋯", ldots = "…", dots = "…", vdots = "⋮", ddots = "⋱",
  angle = "∠", perp = "⊥", parallel = "∥", hbar = "ℏ", ell = "ℓ", prime = "′",
  langle = "⟨", rangle = "⟩", lceil = "⌈", rceil = "⌉", lfloor = "⌊", rfloor = "⌋",
}

-- Unicode superscript / subscript forms, char -> form. Coverage is partial (this
-- is a Unicode limitation), so a script whose chars are not all mappable falls
-- back to ^(..) / _(..).
local SUP = {
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴", ["5"] = "⁵",
  ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹", ["+"] = "⁺", ["-"] = "⁻",
  ["="] = "⁼", ["("] = "⁽", [")"] = "⁾", n = "ⁿ", i = "ⁱ",
  a = "ᵃ", b = "ᵇ", c = "ᶜ", d = "ᵈ", e = "ᵉ", f = "ᶠ", g = "ᵍ", h = "ʰ", j = "ʲ",
  k = "ᵏ", l = "ˡ", m = "ᵐ", o = "ᵒ", p = "ᵖ", r = "ʳ", s = "ˢ", t = "ᵗ", u = "ᵘ",
  v = "ᵛ", w = "ʷ", x = "ˣ", y = "ʸ", z = "ᶻ",
}
local SUB = {
  ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄", ["5"] = "₅",
  ["6"] = "₆", ["7"] = "₇", ["8"] = "₈", ["9"] = "₉", ["+"] = "₊", ["-"] = "₋",
  ["="] = "₌", ["("] = "₍", [")"] = "₎",
  a = "ₐ", e = "ₑ", h = "ₕ", i = "ᵢ", j = "ⱼ", k = "ₖ", l = "ₗ", m = "ₘ", n = "ₙ",
  o = "ₒ", p = "ₚ", r = "ᵣ", s = "ₛ", t = "ₜ", u = "ᵤ", v = "ᵥ", x = "ₓ",
}

-- Encode a Unicode codepoint as UTF-8 (LuaJIT ships no utf8.char). Used to build
-- the math alphanumeric style blocks (bold, italic), whose glyphs live in plane 1.
local function utf8c(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

-- Build an ASCII-char -> styled-glyph map from contiguous codepoint ranges
-- `{ {ascii_start, ascii_end, cp_start}, ... }`, with optional per-char overrides
-- (for the reserved holes the math blocks fill from the Letterlike Symbols block).
local function alphamap(ranges, overrides)
  local m = {}
  for _, r in ipairs(ranges) do
    local a0, a1 = r[1]:byte(), r[2]:byte()
    for b = a0, a1 do
      m[string.char(b)] = utf8c(r[3] + (b - a0))
    end
  end
  for k, v in pairs(overrides or {}) do
    m[k] = v
  end
  return m
end

-- Math alphanumeric symbol blocks: A-Z, a-z, (bold also 0-9). Punctuation has no
-- styled form, so it falls through unchanged (restyle keeps unmapped chars).
local BOLD = alphamap({ { "A", "Z", 0x1D400 }, { "a", "z", 0x1D41A }, { "0", "9", 0x1D7CE } })
-- Italic omits digits (upright by convention) and has a reserved slot for h,
-- which Unicode fills with U+210E (the Planck constant) in Letterlike Symbols.
local ITALIC = alphamap({ { "A", "Z", 0x1D434 }, { "a", "z", 0x1D44E } }, { h = utf8c(0x210E) })
-- Style key -> char map; "rm" (upright roman, e.g. \text) is identity (no map).
local FONTS = { bf = BOLD, it = ITALIC }

-- Argument-taking font/wrapper commands: \cmd{...} restyles its argument's glyphs.
local WRAPCMD = {
  text = "rm", mathrm = "rm", mathbf = "bf", boldsymbol = "bf", mathit = "it",
}

-- Named spacing commands (alphabetic, so they never reach the escaped-punct
-- SPACING table): a run of spaces standing in for the em-based LaTeX widths.
local NAMED_SPACING = { quad = string.rep(" ", 4), qquad = string.rep(" ", 8) }

-- Accent commands: a combining mark placed over the argument. In single-line mode
-- the mark is a Unicode combining char after the base; display mode stacks a row.
local ACCENTS = {
  hat = { combining = utf8c(0x0302), glyph = "^" },
  dot = { combining = utf8c(0x0307), glyph = utf8c(0x02D9) },
  bar = { combining = utf8c(0x0304), glyph = utf8c(0x203E) },
  vec = { combining = utf8c(0x20D7), glyph = utf8c(0x2192) },
  tilde = { combining = utf8c(0x0303), glyph = "~" },
}

-- \left<delim> ... \right<delim>: fences sized to their content in display mode
-- (plain glyphs inline). The token read after \left / \right (a bare char, or an
-- escaped one like \{ \|, or a named one like \langle) maps to its base glyph; a
-- "." delimiter is null (no fence drawn).
local DELIM = {
  ["("] = "(", [")"] = ")", ["["] = "[", ["]"] = "]", ["|"] = "|",
  ["<"] = "⟨", [">"] = "⟩", ["."] = "",
  ["\\{"] = "{", ["\\}"] = "}", ["\\|"] = "‖",
  ["\\langle"] = "⟨", ["\\rangle"] = "⟩", ["\\lvert"] = "|", ["\\rvert"] = "|",
  ["\\lVert"] = "‖", ["\\rVert"] = "‖", ["\\lbrace"] = "{", ["\\rbrace"] = "}",
}

-- Multi-row fence pieces, base glyph -> { top, extension, bottom, mid = ? }. A
-- glyph absent here (|, ‖, ⟨, ⟩) is simply repeated on every row; the middle
-- `mid` piece (braces) lands on the centre row.
local FENCE = {
  ["("] = { "⎛", "⎜", "⎝" }, [")"] = { "⎞", "⎟", "⎠" },
  ["["] = { "⎡", "⎢", "⎣" }, ["]"] = { "⎤", "⎥", "⎦" },
  ["{"] = { "⎧", "⎪", "⎩", mid = "⎨" }, ["}"] = { "⎫", "⎪", "⎭", mid = "⎬" },
}

-- Read the delimiter token following \left / \right: a bare char, an escaped
-- char (\{ \} \|), or a named command (\langle).  Returns (token, next_i).
local function read_delim(s, i)
  while s:sub(i, i) == " " do
    i = i + 1
  end
  local c = s:sub(i, i)
  if c == "\\" then
    local cmd, ni = s:match("^\\(%a+)()", i)
    if cmd then
      return "\\" .. cmd, ni
    end
    return "\\" .. s:sub(i + 1, i + 1), i + 2
  end
  return c, i + 1
end

-- ── parser ───────────────────────────────────────────────────────────────────

-- Big operators: rendered inline in single-line mode (∑ⁿᵢ₌₁), but as a large
-- multi-row glyph with limits stacked above/below in display mode. The pieces
-- stack vertically to form the tall glyph (a summation top/bottom, an integral
-- top/extension/bottom); operators without stacking glyphs use the single char.
local BIGOPS = { sum = true, prod = true, int = true, oint = true, bigcup = true, bigcap = true }
-- Relation glyphs bound a big operator's operand: `\sum f = g` sizes the sigma
-- to f, not to the whole line, so a tall right-hand side does not inflate it.
local RELATIONS = {
  ["="] = true, ["<"] = true, [">"] = true, ["≤"] = true, ["≥"] = true, ["≠"] = true,
  ["≈"] = true, ["≡"] = true, ["∼"] = true, ["≃"] = true, ["≅"] = true, ["∝"] = true,
  ["→"] = true, ["⇒"] = true, ["↦"] = true, ["∈"] = true,
}
local BIGOP_PIECES = {
  sum = { "⎲", "⎳" },
  int = { "⌠", "⎮", "⌡" },
  oint = { "⌠", "⎮", "⌡" },
}

local parse_nodes, parse_arg

-- One argument: a `{...}` group (returns its body list) or a single atom.
---@return table[] nodes, integer next_i
parse_arg = function(s, i)
  while s:sub(i, i) == " " do
    i = i + 1
  end
  local c = s:sub(i, i)
  if c == "{" then
    local body, ni = parse_nodes(s, i + 1, "}")
    return body, ni + 1
  elseif c == "\\" then
    local cmd, ni = s:match("^\\(%a+)()", i)
    if cmd then
      return { { kind = "sym", text = SYMBOLS[cmd] or cmd } }, ni
    end
    return { { kind = "sym", text = s:sub(i + 1, i + 1) } }, i + 2
  elseif c == "" then
    return {}, i
  end
  return { { kind = "sym", text = c } }, i + 1
end

-- Parse a run of atoms until `stop` (or end). `^`/`_` attach to the previous atom.
---@return table[] nodes, integer next_i
parse_nodes = function(s, i, stop)
  local nodes = {}
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if stop and c == stop then
      break
    end
    if c == "^" or c == "_" then
      local arg, ni = parse_arg(s, i + 1)
      local prev = nodes[#nodes]
      if prev then
        prev[c == "^" and "sup" or "sub"] = arg
      end
      i = ni
    elseif c == "{" then
      local body, ni = parse_nodes(s, i + 1, "}")
      nodes[#nodes + 1] = { kind = "group", body = body }
      i = ni + 1
    elseif c == "\\" then
      local cmd, ni = s:match("^\\(%a+)()", i)
      if cmd == "right" then
        break -- terminates the enclosing \left; that branch consumes the delim
      elseif cmd == "left" then
        local ld, i2 = read_delim(s, ni)
        local body, i3 = parse_nodes(s, i2, stop)
        -- consume the matching \right<delim> (leniently, if present)
        local rcmd, rni = s:match("^\\(%a+)()", i3)
        local rd = ""
        if rcmd == "right" then
          rd, i3 = read_delim(s, rni)
        end
        nodes[#nodes + 1] = { kind = "delim", left = ld, right = rd, body = body }
        i = i3
      elseif cmd == "frac" then
        local num, i2 = parse_arg(s, ni)
        local den, i3 = parse_arg(s, i2)
        nodes[#nodes + 1] = { kind = "frac", num = num, den = den }
        i = i3
      elseif cmd == "sqrt" then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "sqrt", body = body }
        i = i2
      elseif cmd and BIGOPS[cmd] then
        nodes[#nodes + 1] = { kind = "bigop", text = SYMBOLS[cmd], op = cmd }
        i = ni
      elseif cmd and NAMED_SPACING[cmd] then
        nodes[#nodes + 1] = { kind = "sym", text = NAMED_SPACING[cmd] }
        i = ni
      elseif cmd and WRAPCMD[cmd] then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "styled", font = WRAPCMD[cmd], body = body }
        i = i2
      elseif cmd and ACCENTS[cmd] then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "accent", accent = ACCENTS[cmd], body = body }
        i = i2
      elseif cmd then
        nodes[#nodes + 1] = { kind = "sym", text = SYMBOLS[cmd] or cmd }
        i = ni
      else
        -- escaped non-letter: LaTeX spacing commands (\, \; \: \ ) become a
        -- space, \! nothing; anything else is the literal escaped character.
        local ch = s:sub(i + 1, i + 1)
        local SPACING = { [","] = " ", [";"] = " ", [":"] = " ", [" "] = " ", ["!"] = "" }
        nodes[#nodes + 1] = { kind = "sym", text = SPACING[ch] or ch }
        i = i + 2
      end
    else
      nodes[#nodes + 1] = { kind = "sym", text = c }
      i = i + 1
    end
  end
  return nodes, i
end

local function parse(tex)
  return (parse_nodes(tex, 1, nil))
end

-- ── single-line renderer ─────────────────────────────────────────────────────

-- Iterate the Unicode characters of `s`.
local function chars(s)
  return s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- Map every char of `s` through `tbl`; nil if any char is unmappable.
local function map_all(s, tbl)
  local out = {}
  for ch in chars(s) do
    local m = tbl[ch]
    if not m then
      return nil
    end
    out[#out + 1] = m
  end
  return table.concat(out)
end

-- Map every char of `s` through `map` (a font block), keeping unmapped chars
-- (punctuation, box-drawing) as-is. `nil` map is identity (upright roman).
local function restyle(s, map)
  if not map then
    return s
  end
  local out = {}
  for ch in chars(s) do
    out[#out + 1] = map[ch] or ch
  end
  return table.concat(out)
end

local render_single

-- Parenthesize `str` when `nodes` is a compound (more than one atom).
local function paren(str, nodes)
  return #nodes > 1 and ("(" .. str .. ")") or str
end

render_single = function(nodes)
  local parts = {}
  for _, node in ipairs(nodes) do
    local base
    if node.kind == "sym" or node.kind == "bigop" then
      base = node.text
    elseif node.kind == "group" then
      base = render_single(node.body)
    elseif node.kind == "frac" then
      base = paren(render_single(node.num), node.num) .. "/" .. paren(render_single(node.den), node.den)
    elseif node.kind == "sqrt" then
      base = "√" .. paren(render_single(node.body), node.body)
    elseif node.kind == "styled" then
      base = restyle(render_single(node.body), FONTS[node.font])
    elseif node.kind == "accent" then
      -- a combining mark trails each base char; a single base is the common case
      base = render_single(node.body) .. node.accent.combining
    elseif node.kind == "delim" then
      base = (DELIM[node.left] or node.left) .. render_single(node.body) .. (DELIM[node.right] or node.right)
    else
      base = ""
    end
    if node.sup then
      local s = render_single(node.sup)
      base = base .. (map_all(s, SUP) or ("^(" .. s .. ")"))
    end
    if node.sub then
      local s = render_single(node.sub)
      base = base .. (map_all(s, SUB) or ("_(" .. s .. ")"))
    end
    parts[#parts + 1] = base
  end
  return table.concat(parts)
end

-- Rendering is pure in `tex` and re-run every relayout, so memoize both forms
-- (bounded; dropped wholesale past the cap), like the code highlighter.
local single_cache, stack_cache, cache_n = {}, {}, 0
local CACHE_MAX = 1024

local function bump()
  cache_n = cache_n + 1
  if cache_n >= CACHE_MAX then
    single_cache, stack_cache, cache_n = {}, {}, 0
  end
end

-- Render `tex` as a single Unicode line (inline math).
---@param tex string
---@return string
function M.single(tex)
  local hit = single_cache[tex]
  if hit == nil then
    hit = render_single(parse(tex))
    single_cache[tex] = hit
    bump()
  end
  return hit
end

-- ── stacked (2D) renderer ────────────────────────────────────────────────────
-- A box is { lines, w, h, axis } where axis is the 0-based row treated as the
-- vertical centre for alignment. Fractions and roots build vertical structure;
-- scripts stay inline (the single-line Unicode super/subscripts), which keeps
-- the layout simple while giving display mode its main win: stacked fractions.

local width = require("fibrous.inline.width")
local dw = width.str

local function spaces(n)
  return (" "):rep(math.max(n, 0))
end

local function pad_to(s, w)
  return s .. spaces(w - dw(s))
end

local function center(s, w)
  local total = w - dw(s)
  local left = math.floor(total / 2)
  return spaces(left) .. s .. spaces(total - left)
end

local function text_box(s)
  return { lines = { s }, w = dw(s), h = 1, axis = 0 }
end

-- Concatenate boxes horizontally, aligning them on their axes.
local function hcat(boxes)
  local above, below, w = 0, 0, 0
  for _, b in ipairs(boxes) do
    above = math.max(above, b.axis)
    below = math.max(below, b.h - 1 - b.axis)
    w = w + b.w
  end
  local h = above + below + 1
  local lines = {}
  for r = 1, h do
    local row = {}
    for _, b in ipairs(boxes) do
      local br = r - (above - b.axis) -- 1-based row within this box
      row[#row + 1] = (br >= 1 and br <= b.h) and pad_to(b.lines[br], b.w) or spaces(b.w)
    end
    lines[r] = table.concat(row)
  end
  return { lines = lines, w = w, h = h, axis = above }
end

local function frac_box(num, den)
  local w = math.max(num.w, den.w)
  local lines = {}
  for i = 1, num.h do
    lines[#lines + 1] = center(num.lines[i], w)
  end
  lines[#lines + 1] = ("─"):rep(w)
  for i = 1, den.h do
    lines[#lines + 1] = center(den.lines[i], w)
  end
  return { lines = lines, w = w, h = #lines, axis = num.h }
end

local function sqrt_box(body)
  local w = body.w
  -- Single-row body: the compact form. The vinculum uses "_" (bottom of its
  -- cell) so on the row above it hugs the content rather than floating.
  if body.h == 1 then
    return { lines = { " " .. ("_"):rep(w), "√" .. pad_to(body.lines[1], w) }, w = w + 1, h = 2, axis = 1 }
  end
  -- Tall body: a growing radical. A "╲╱" check at the bottom-left, a "╱"
  -- diagonal rising one column per row to the top bar, drawn with single-width
  -- box glyphs so it stays on the grid.
  local h = body.h
  local g = h + 1 -- gutter width (the diagonal rises across these columns)
  -- the vinculum sits over the CONTENT (its left end already meets the "╱"
  -- apex at the cell corner); extending it further left would cover the diagonal
  local lines = { spaces(g) .. ("_"):rep(w) }
  for i = 1, h do
    local gut = {}
    for c = 1, g do
      gut[c] = " "
    end
    local col = g - i + 1 -- the diagonal steps left going down
    gut[col] = "╱"
    if i == h then
      gut[col - 1] = "╲" -- the check vertex at the bottom
    end
    lines[i + 1] = table.concat(gut) .. pad_to(body.lines[i], w)
  end
  return { lines = lines, w = g + w, h = h + 1, axis = body.axis + 1 }
end

-- A fence column of height `h` for a base glyph. Height 1 is the plain glyph;
-- a null delimiter ("") draws no column (nil). Known fences use their piece set
-- (top/extension/bottom, plus a centre `mid` for braces); others repeat.
local function fence_lines(glyph, h)
  if glyph == "" then
    return nil
  end
  if h <= 1 then
    return { glyph }
  end
  local f = FENCE[glyph]
  if not f then
    local l = {}
    for i = 1, h do
      l[i] = glyph
    end
    return l
  end
  local midrow = f.mid and math.floor((h + 1) / 2) or nil
  local l = { f[1] }
  for i = 2, h - 1 do
    l[i] = (i == midrow) and f.mid or f[2]
  end
  l[h] = f[3]
  return l
end

local render_stack

-- Inline scripts (unicode, or ^()/_() fallback) for a tall base box.
local function scripts_text(node)
  local out = ""
  if node.sup then
    local s = render_single(node.sup)
    out = out .. (map_all(s, SUP) or ("^(" .. s .. ")"))
  end
  if node.sub then
    local s = render_single(node.sub)
    out = out .. (map_all(s, SUB) or ("_(" .. s .. ")"))
  end
  return out
end

-- A scalable box-drawing summation of exact height `h`. Σ's point is on the
-- RIGHT with its bars opening right: the upper "╲" descends down-right to the
-- vertex, the lower "╱" returns down-left, and the ▔/▁ bars sit to the right of
-- the arms. Bars use the top/bottom EDGE eighth-blocks so they meet the
-- diagonals at cell CORNERS (a mid-height "─" would leave a gap). An EVEN height
-- puts the vertex on the corner where the two diagonals meet; an ODD height puts
-- it on its own row as a chevron "❯".
local function box_sigma(h)
  local arm = math.floor(h / 2)
  local odd = (h % 2) == 1
  local vcol = odd and (arm + 1) or arm -- rightmost column (the vertex)
  local barw = math.max(arm, 1)
  local w = vcol + barw
  local function row()
    local r = {}
    for c = 1, w do
      r[c] = " "
    end
    return r
  end
  local lines = {}
  for i = 1, arm do -- upper arm ╲, stepping right toward the vertex
    local r = row()
    r[i] = "╲"
    if i == 1 then
      for c = 2, 1 + barw do
        r[c] = "▔"
      end
    end
    lines[#lines + 1] = table.concat(r)
  end
  if odd then -- the vertex on its own row
    local r = row()
    r[vcol] = "❯"
    lines[#lines + 1] = table.concat(r)
  end
  for i = 1, arm do -- lower arm ╱, stepping left away from the vertex
    local r = row()
    r[arm - i + 1] = "╱"
    if i == arm then
      for c = 2, 1 + barw do
        r[c] = "▁"
      end
    end
    lines[#lines + 1] = table.concat(r)
  end
  return lines
end

-- The operator glyph lines, sized to the summand height `oph`. Sum: 1 line uses
-- the plain ∑, 2 lines the two-halves ⎲⎳, 3+ the box-drawing sigma. Integral
-- grows via the ⎮ extension; other operators stay single-glyph.
local function op_pieces(node, oph)
  if node.op == "sum" then
    if oph <= 1 then
      return { "∑" }
    elseif oph == 2 then
      return { "⎲", "⎳" }
    end
    return box_sigma(oph) -- exact height; even = corner vertex, odd = chevron
  elseif node.op == "int" or node.op == "oint" then
    local p = { "⌠" }
    for _ = 1, math.max(oph - 2, 1) do
      p[#p + 1] = "⎮"
    end
    p[#p + 1] = "⌡"
    return p
  end
  return { node.text }
end

-- A big operator's limit: rendered SMALL (unicode super/subscript, mimicking
-- scriptstyle) when every char has a small form, else full-size stacked.
local function limit_box(nodes, map)
  local s = render_single(nodes)
  local small = map_all(s, map)
  if small then
    return { lines = { small }, w = dw(small), h = 1, axis = 0 }
  end
  return render_stack(nodes)
end

-- A big operator (∑, ∫, …), its glyph sized to the summand height `oph`, with
-- its limits stacked above and below (display).
local function bigop_box(node, oph)
  local pieces = op_pieces(node, oph)
  local sup = node.sup and limit_box(node.sup, SUP) or nil
  local sub = node.sub and limit_box(node.sub, SUB) or nil
  local w = 0
  for _, l in ipairs(pieces) do
    w = math.max(w, dw(l))
  end
  if sup then
    w = math.max(w, sup.w)
  end
  if sub then
    w = math.max(w, sub.w)
  end
  local lines = {}
  if sup then
    for _, l in ipairs(sup.lines) do
      lines[#lines + 1] = center(l, w)
    end
  end
  -- axis on the operator's middle row, so the summand aligns to its centre
  local axis = #lines + math.floor((#pieces - 1) / 2)
  for _, l in ipairs(pieces) do
    lines[#lines + 1] = center(l, w)
  end
  if sub then
    for _, l in ipairs(sub.lines) do
      lines[#lines + 1] = center(l, w)
    end
  end
  return { lines = lines, w = w, h = #lines, axis = axis }
end

local function box_of(node)
  if node.kind == "sym" then
    -- a plain atom (with its scripts) is one inline row
    return text_box(render_single({ node }))
  end
  if node.kind == "bigop" then
    return bigop_box(node, 1) -- fallback size; render_stack sizes to the summand
  end
  local b
  if node.kind == "frac" then
    b = frac_box(render_stack(node.num), render_stack(node.den))
  elseif node.kind == "sqrt" then
    b = sqrt_box(render_stack(node.body))
  elseif node.kind == "group" then
    b = render_stack(node.body)
  elseif node.kind == "styled" then
    b = render_stack(node.body)
    local map = FONTS[node.font]
    if map then
      local nl = {}
      for i, l in ipairs(b.lines) do
        nl[i] = restyle(l, map)
      end
      b = { lines = nl, w = b.w, h = b.h, axis = b.axis }
    end
  elseif node.kind == "accent" then
    -- stack the accent glyph on a new row above the body, centred on its width
    b = render_stack(node.body)
    local top = center(node.accent.glyph, b.w)
    local lines = { top }
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = l
    end
    b = { lines = lines, w = b.w, h = b.h + 1, axis = b.axis + 1 }
  elseif node.kind == "delim" then
    -- fences sized to the content height, drawn to the left/right of its box
    local inner = render_stack(node.body)
    local parts = {}
    local lg = fence_lines(DELIM[node.left] or node.left, inner.h)
    if lg then
      parts[#parts + 1] = { lines = lg, w = dw(lg[1]), h = inner.h, axis = inner.axis }
    end
    parts[#parts + 1] = inner
    local rg = fence_lines(DELIM[node.right] or node.right, inner.h)
    if rg then
      parts[#parts + 1] = { lines = rg, w = dw(rg[1]), h = inner.h, axis = inner.axis }
    end
    b = hcat(parts)
  else
    b = text_box("")
  end
  local sc = scripts_text(node)
  if sc ~= "" then
    b = hcat({ b, text_box(sc) })
  end
  return b
end

render_stack = function(nodes)
  if #nodes == 0 then
    return text_box("")
  end
  -- render everything except big operators first; a big operator's glyph is
  -- sized to its summand, which is the content to its right (look-ahead).
  local boxes = {}
  for idx, node in ipairs(nodes) do
    boxes[idx] = (node.kind ~= "bigop") and box_of(node) or false
  end
  for idx, node in ipairs(nodes) do
    if node.kind == "bigop" then
      local oph = 1
      for j = idx + 1, #nodes do
        local nj = nodes[j]
        if nj.kind == "sym" and RELATIONS[nj.text] then
          break -- the operand ends at a relation (= , ≤, …)
        end
        if boxes[j] then
          oph = math.max(oph, boxes[j].h)
        end
      end
      boxes[idx] = bigop_box(node, oph)
    end
  end
  return hcat(boxes)
end

-- Render `tex` as a 2D block of Unicode lines (display math).
---@param tex string
---@return string[] lines
function M.stack(tex)
  local hit = stack_cache[tex]
  if hit == nil then
    hit = render_stack(parse(tex)).lines
    stack_cache[tex] = hit
    bump()
  end
  return hit
end

return M
