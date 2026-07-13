-- Pure-Lua LaTeX math rendering. A shared recursive-descent parser turns a TeX
-- string into a small math AST, and two backends render it: `single` (a flat
-- Unicode line, for inline $...$) and `stack` (a 2D box layout, for display
-- $$...$$). No treesitter, no binary, so it runs everywhere fibrous does,
-- including the WASM docs site. Anything the parser does not understand degrades
-- to the command name or the literal source rather than erroring.
--
-- M.single / M.stack return plain text; M.single_spans / M.stack_spans return the
-- same content as { text, var } run lists, where `var` marks identifier variables
-- so the doc renderer can italicise just those cells (see the proxy note below).
--
-- Scope (documented subset, expandable): symbols (Greek, operators, relations,
-- arrows, big operators, logic/lattice/Letterlike), `^`/`_` scripts, primes,
-- `\frac` (and `\dfrac`/`\tfrac`), `\binom`, `\sqrt` including the `\sqrt[n]{}`
-- index, `{...}` groups, fonts (`\mathbf`, `\mathit`, `\boldsymbol`, `\mathrm`,
-- `\mathbb`, `\mathcal`, `\mathfrak`, `\mathsf`, `\mathtt`, `\text`,
-- `\operatorname`), accents (`\hat`, `\dot`, `\bar`, `\vec`, `\tilde`) and wide
-- accents (`\widehat`, `\widetilde`, `\overrightarrow`, `\overleftarrow`),
-- `\overline`, `\overbrace`/`\underbrace`, `\overset`/`\underset`/`\stackrel`,
-- named operators with limits (`\lim`, `\max`, `\min`, `\sup`, `\det`, …),
-- `\bmod`/`\pmod`, spacing (`\quad`, `\qquad`), `\left…\right` fences sized to
-- their content, and environments (`matrix`/`pmatrix`/`bmatrix`/`Bmatrix`/
-- `vmatrix`/`Vmatrix`, `cases`, `aligned`/`align`) laid out as 2D grids in
-- display and flattened inline. Unknown commands degrade to their name;
-- variables are NOT auto-italicised (opt in via \mathit).

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
  coprod = "∐", bigoplus = "⨁", bigotimes = "⨂", bigodot = "⨀", bigwedge = "⋀",
  bigvee = "⋁", biguplus = "⨄", bigsqcup = "⨆", iint = "∬", iiint = "∭",
  partial = "∂", nabla = "∇", infty = "∞",
  -- dots and misc
  cdots = "⋯", ldots = "…", dots = "…", vdots = "⋮", ddots = "⋱",
  angle = "∠", perp = "⊥", parallel = "∥", mid = "∣", nmid = "∤", hbar = "ℏ", ell = "ℓ", prime = "′",
  langle = "⟨", rangle = "⟩", lceil = "⌈", rceil = "⌉", lfloor = "⌊", rfloor = "⌋",
  -- logic and lattice
  wedge = "∧", vee = "∨", lnot = "¬", top = "⊤", bot = "⊥",
  vdash = "⊢", dashv = "⊣", models = "⊨", vDash = "⊨",
  -- order and set relations
  prec = "≺", succ = "≻", preceq = "⪯", succeq = "⪰",
  sqsubseteq = "⊑", sqsupseteq = "⊒", sqsubset = "⊏", sqsupset = "⊐",
  subsetneq = "⊊", supsetneq = "⊋", ni = "∋", owns = "∋",
  asymp = "≍", doteq = "≐", gtrless = "≷", lessgtr = "≶",
  -- Letterlike and misc symbols
  aleph = "ℵ", beth = "ℶ", Re = "ℜ", Im = "ℑ", wp = "℘", Bbbk = "𝕜",
  complement = "∁", therefore = "∴", because = "∵",
  imath = "ı", jmath = "ȷ", Finv = "Ⅎ", Game = "⅁",
  dagger = "†", ddagger = "‡", triangle = "△", square = "□", diamond = "⋄",
  triangleleft = "◁", triangleright = "▷", flat = "♭", sharp = "♯", natural = "♮",
  clubsuit = "♣", diamondsuit = "♢", heartsuit = "♡", spadesuit = "♠",
  measuredangle = "∡", sphericalangle = "∢", degree = "°", backslash = "\\",
  -- ring / boxed operators
  odot = "⊙", ominus = "⊖", oslash = "⊘", boxplus = "⊞", boxtimes = "⊠",
  boxminus = "⊟", boxdot = "⊡", sqcup = "⊔", sqcap = "⊓", uplus = "⊎",
  amalg = "⨿", wr = "≀",
  -- delimiters / bars
  vert = "|", Vert = "‖", lbrace = "{", rbrace = "}", lbrack = "[", rbrack = "]",
  -- vertical, long and hooked arrows
  uparrow = "↑", downarrow = "↓", updownarrow = "↕", Uparrow = "⇑", Downarrow = "⇓",
  Updownarrow = "⇕", nearrow = "↗", searrow = "↘", nwarrow = "↖", swarrow = "↙",
  gets = "←", longrightarrow = "⟶", longleftarrow = "⟵", longleftrightarrow = "⟷",
  Longrightarrow = "⟹", Longleftarrow = "⟸", Longleftrightarrow = "⟺",
  implies = "⟹", impliedby = "⟸", hookrightarrow = "↪", hookleftarrow = "↩",
  rightharpoonup = "⇀", leftharpoonup = "↼", rightharpoondown = "⇁", leftharpoondown = "↽",
  -- colon-like spacing and modular arithmetic
  colon = ":", bmod = "mod",
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
-- Blackboard bold (\mathbb) and script (\mathcal). Both blocks reserve slots that
-- Unicode fills from the Letterlike Symbols block, so those need overrides.
local BLACKBOARD = alphamap(
  { { "A", "Z", 0x1D538 }, { "a", "z", 0x1D552 }, { "0", "9", 0x1D7D8 } },
  {
    C = utf8c(0x2102), H = utf8c(0x210D), N = utf8c(0x2115), P = utf8c(0x2119),
    Q = utf8c(0x211A), R = utf8c(0x211D), Z = utf8c(0x2124),
  }
)
-- \mathcal is upright-uppercase in standard LaTeX; lowercase passes through.
local SCRIPT = alphamap({ { "A", "Z", 0x1D49C } }, {
  B = utf8c(0x212C), E = utf8c(0x2130), F = utf8c(0x2131), H = utf8c(0x210B),
  I = utf8c(0x2110), L = utf8c(0x2112), M = utf8c(0x2133), R = utf8c(0x211B),
})
-- Fraktur (\mathfrak): the Mathematical Fraktur block, with the usual reserved
-- slots filled from Letterlike Symbols. Sans-serif (\mathsf) and monospace
-- (\mathtt) blocks are contiguous (digits included, no holes).
local FRAKTUR = alphamap({ { "A", "Z", 0x1D504 }, { "a", "z", 0x1D51E } }, {
  C = utf8c(0x212D), H = utf8c(0x210C), I = utf8c(0x2111), R = utf8c(0x211C), Z = utf8c(0x2128),
})
local SANS = alphamap({ { "A", "Z", 0x1D5A0 }, { "a", "z", 0x1D5BA }, { "0", "9", 0x1D7E2 } })
local MONO = alphamap({ { "A", "Z", 0x1D670 }, { "a", "z", 0x1D68A }, { "0", "9", 0x1D7F6 } })

-- Style key -> char map; "rm" (upright roman, e.g. \text) is identity (no map).
local FONTS = { bf = BOLD, it = ITALIC, bb = BLACKBOARD, cal = SCRIPT, frak = FRAKTUR, sf = SANS, tt = MONO }

-- Argument-taking font/wrapper commands: \cmd{...} restyles its argument's glyphs.
-- \operatorname is upright roman like \mathrm (a multi-letter operator name).
local WRAPCMD = {
  text = "rm", mathrm = "rm", operatorname = "rm", mathbf = "bf", boldsymbol = "bf",
  mathit = "it", mathbb = "bb", mathcal = "cal", mathfrak = "frak", mathsf = "sf", mathtt = "tt",
}

-- Combining marks that overlay the preceding glyph (no extra row/column).
local NOT_OVERLAY = utf8c(0x0338) -- combining long solidus (for \not)
local OVERLINE_MARK = utf8c(0x0305) -- combining overline (inline \overline)

-- Named spacing commands (alphabetic, so they never reach the escaped-punct
-- SPACING table): a run of spaces standing in for the em-based LaTeX widths.
local NAMED_SPACING = { quad = string.rep(" ", 4), qquad = string.rep(" ", 8) }

-- Prime marks: a run of ASCII apostrophes in math mode becomes the prime glyphs
-- (x' => x′, x'' => x″), like TeX turning ' into a \prime superscript.
local PRIMES = { "′", "″", "‴" }

-- Accent commands: a combining mark placed over the argument. In single-line mode
-- the mark is a Unicode combining char after the base; display mode stacks a row.
local ACCENTS = {
  hat = { combining = utf8c(0x0302), glyph = "^" },
  dot = { combining = utf8c(0x0307), glyph = utf8c(0x02D9) },
  bar = { combining = utf8c(0x0304), glyph = utf8c(0x203E) },
  vec = { combining = utf8c(0x20D7), glyph = utf8c(0x2192) },
  tilde = { combining = utf8c(0x0303), glyph = "~" },
}

-- Named operators that take LIMITS: their sub/superscripts sit below/above in
-- display (like \sum); inline they stay ordinary scripts. The name is its own
-- glyph (upright, multi-letter). Plain functions (\sin, \cos, \log, …) need no
-- entry: an unknown command already degrades to its upright name.
local LIMIT_OPS = {
  lim = true, limsup = true, liminf = true, max = true, min = true, sup = true,
  inf = true, det = true, gcd = true, Pr = true, injlim = true, projlim = true,
  varinjlim = true, varprojlim = true,
}

-- Wide accents: a mark spanning the whole argument. Inline, the combining mark
-- trails every char; in display, box_of draws a `shape` row spanning the width.
local WIDE_ACCENTS = {
  widehat = { combining = utf8c(0x0302), shape = "hat" },
  widetilde = { combining = utf8c(0x0303), shape = "tilde" },
  overrightarrow = { combining = utf8c(0x20D7), shape = "aright" },
  overleftarrow = { combining = utf8c(0x20D6), shape = "aleft" },
  overleftrightarrow = { combining = utf8c(0x20E1), shape = "aboth" },
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
-- glyph absent here (⟨, ⟩) is simply repeated on every row; the middle `mid`
-- piece (braces) lands on the centre row. The bar delimiters use box-drawing
-- verticals (│ single, ║ double) whose top/extension/bottom are the SAME glyph:
-- they meet across cell edges, so a tall determinant or norm reads as one
-- continuous rule rather than a column of gappy ASCII pipes.
local FENCE = {
  ["("] = { "⎛", "⎜", "⎝" }, [")"] = { "⎞", "⎟", "⎠" },
  ["["] = { "⎡", "⎢", "⎣" }, ["]"] = { "⎤", "⎥", "⎦" },
  ["{"] = { "⎧", "⎪", "⎩", mid = "⎨" }, ["}"] = { "⎫", "⎪", "⎭", mid = "⎬" },
  ["|"] = { "│", "│", "│" }, ["‖"] = { "║", "║", "║" },
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
local BIGOPS = {
  sum = true, prod = true, int = true, oint = true, bigcup = true, bigcap = true,
  coprod = true, bigoplus = true, bigotimes = true, bigodot = true, bigwedge = true,
  bigvee = true, biguplus = true, bigsqcup = true, iint = true, iiint = true,
}
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

-- Delimiters that wrap each matrix-like environment (base glyphs; display sizes
-- them via fence_lines, inline uses them literally). An empty side draws none.
local ENV_DELIMS = {
  matrix = { "", "" }, pmatrix = { "(", ")" }, bmatrix = { "[", "]" },
  Bmatrix = { "{", "}" }, vmatrix = { "|", "|" }, Vmatrix = { "‖", "‖" },
  cases = { "{", "" },
}
-- Environments whose columns alternate right/left alignment at each & (so the
-- relation column lines up); everything else centres, cases left-aligns.
local ALIGN_ALTERNATE = {
  aligned = true, ["aligned*"] = true, align = true, ["align*"] = true, split = true,
}

local parse_nodes, parse_arg, parse_env

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
    elseif c == "'" then
      local j = i
      while s:sub(j, j) == "'" do
        j = j + 1
      end
      local run = j - i
      nodes[#nodes + 1] = { kind = "sym", text = PRIMES[run] or ("′"):rep(run) }
      i = j
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
      elseif cmd == "frac" or cmd == "dfrac" or cmd == "tfrac" or cmd == "cfrac" then
        local num, i2 = parse_arg(s, ni)
        local den, i3 = parse_arg(s, i2)
        nodes[#nodes + 1] = { kind = "frac", num = num, den = den }
        i = i3
      elseif cmd == "sqrt" then
        -- optional index: \sqrt[n]{x}. The bracketed run is parsed like a group
        -- but delimited by "]" rather than "}".
        local j = ni
        while s:sub(j, j) == " " do
          j = j + 1
        end
        local index = nil
        if s:sub(j, j) == "[" then
          local idx, jn = parse_nodes(s, j + 1, "]")
          index = idx
          j = jn + 1
        end
        local body, i2 = parse_arg(s, j)
        nodes[#nodes + 1] = { kind = "sqrt", body = body, index = index }
        i = i2
      elseif cmd == "binom" or cmd == "dbinom" or cmd == "tbinom" then
        local num, i2 = parse_arg(s, ni)
        local den, i3 = parse_arg(s, i2)
        nodes[#nodes + 1] = { kind = "binom", num = num, den = den }
        i = i3
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
      elseif cmd == "overline" then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "overline", body = body }
        i = i2
      elseif cmd == "not" then
        -- \not overlays a combining solidus on the following atom (\not= => ≠)
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "overlay", mark = NOT_OVERLAY, body = body }
        i = i2
      elseif cmd == "begin" then
        local name, after = s:match("^%s*{([%a*]+)}()", ni)
        if name then
          local node, ai = parse_env(s, after, name)
          nodes[#nodes + 1] = node
          i = ai
        else
          nodes[#nodes + 1] = { kind = "sym", text = "begin" }
          i = ni
        end
      elseif cmd and LIMIT_OPS[cmd] then
        -- a named operator whose scripts stack as limits in display; the name
        -- string is the glyph, reusing the big-operator machinery
        nodes[#nodes + 1] = { kind = "bigop", text = cmd, op = cmd }
        i = ni
      elseif cmd == "pmod" then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "pmod", body = body }
        i = i2
      elseif cmd and WIDE_ACCENTS[cmd] then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = "wideaccent", accent = WIDE_ACCENTS[cmd], body = body }
        i = i2
      elseif cmd == "overbrace" or cmd == "underbrace" then
        local body, i2 = parse_arg(s, ni)
        nodes[#nodes + 1] = { kind = cmd, body = body }
        i = i2
      elseif cmd == "overset" or cmd == "stackrel" then
        -- \overset{top}{base} and \stackrel{top}{rel}: top set above the base
        local over, i2 = parse_arg(s, ni)
        local base, i3 = parse_arg(s, i2)
        nodes[#nodes + 1] = { kind = "overset", over = over, base = base }
        i = i3
      elseif cmd == "underset" then
        local under, i2 = parse_arg(s, ni)
        local base, i3 = parse_arg(s, i2)
        nodes[#nodes + 1] = { kind = "underset", under = under, base = base }
        i = i3
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

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split an environment body into a grid: rows at top-level `\\`, cells at
-- top-level `&`, "top-level" meaning outside any {} group or nested \begin..\end.
-- Each cell is parsed into its own node list.
local function parse_matrix_body(body)
  local rows, cur_row, cur = {}, {}, {}
  local depth, envd = 0, 0
  local function push_cell()
    cur_row[#cur_row + 1] = parse(trim(table.concat(cur)))
    cur = {}
  end
  local function push_row()
    push_cell()
    rows[#rows + 1] = cur_row
    cur_row = {}
  end
  local i, n = 1, #body
  while i <= n do
    local c = body:sub(i, i)
    if c == "{" then
      depth = depth + 1
      cur[#cur + 1] = c
      i = i + 1
    elseif c == "}" then
      depth = depth - 1
      cur[#cur + 1] = c
      i = i + 1
    elseif c == "&" and depth == 0 and envd == 0 then
      push_cell()
      i = i + 1
    elseif c == "\\" then
      local word = body:match("^\\(%a+)", i)
      if word == "begin" then
        envd = envd + 1
        cur[#cur + 1] = "\\begin"
        i = i + 6
      elseif word == "end" then
        envd = envd - 1
        cur[#cur + 1] = "\\end"
        i = i + 4
      elseif word then
        -- keep a full command token intact (do not chop \alpha into \a + lpha)
        cur[#cur + 1] = "\\" .. word
        i = i + 1 + #word
      elseif body:sub(i, i + 1) == "\\\\" then
        if depth == 0 and envd == 0 then
          push_row()
        else
          cur[#cur + 1] = "\\\\"
        end
        i = i + 2
      else
        cur[#cur + 1] = body:sub(i, i + 1)
        i = i + 2
      end
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  if #cur_row > 0 or trim(table.concat(cur)) ~= "" then
    push_row()
  end
  return rows
end

-- Consume s from `i` (just past \begin{name}) to the matching \end{name},
-- honouring nested environments, and return the parsed matrix node.
parse_env = function(s, i, name)
  local depth, j, n = 1, i, #s
  local function skip_group(k)
    return s:match("^%s*{[%a*]+}()", k) or k
  end
  while j <= n do
    if s:sub(j, j) == "\\" then
      local w, nj = s:match("^\\(%a+)()", j)
      if w == "begin" then
        depth = depth + 1
        j = skip_group(nj)
      elseif w == "end" then
        depth = depth - 1
        if depth == 0 then
          local body = s:sub(i, j - 1)
          return { kind = "matrix", env = name, rows = parse_matrix_body(body) }, skip_group(nj)
        end
        j = skip_group(nj)
      elseif w then
        j = nj
      else
        j = j + 1
      end
    else
      j = j + 1
    end
  end
  -- unterminated: render whatever body we have
  return { kind = "matrix", env = name, rows = parse_matrix_body(s:sub(i)) }, n + 1
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

-- ── variable proxies ─────────────────────────────────────────────────────────
-- A "variable" (a lone identifier letter, not a digit/operator/function name and
-- not inside \text/\mathbf/…) is rendered as a Private-Use proxy codepoint of the
-- SAME display width, so the box layout is byte-for-cell identical. M.single /
-- M.stack strip the proxies back to the real glyph; the *_spans variants split on
-- them, so the doc renderer can italicise just those cells via a dedicated
-- (FibrousMathVariable) highlight without touching the user's @markup.math.
local PROXY0 = 0xE000

local function cp_of(ch)
  local b = ch:byte(1)
  if b < 0x80 then
    return b
  elseif b < 0xE0 then
    return (b - 0xC0) * 0x40 + (ch:byte(2) - 0x80)
  elseif b < 0xF0 then
    return (b - 0xE0) * 0x1000 + (ch:byte(2) - 0x80) * 0x40 + (ch:byte(3) - 0x80)
  end
  return (b - 0xF0) * 0x40000 + (ch:byte(2) - 0x80) * 0x1000 + (ch:byte(3) - 0x80) * 0x40 + (ch:byte(4) - 0x80)
end

-- ASCII letters and lowercase Greek (α-ω plus its variant glyphs) are variables;
-- uppercase Greek, digits and operators stay upright, as in real math setting.
local function is_var_cp(cp)
  return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) or (cp >= 0x3B1 and cp <= 0x3D6)
end

-- The proxy for a variable glyph, or nil if the glyph is not a variable. Only a
-- SINGLE character is a candidate: re-encoding its codepoint must reproduce the
-- input exactly, which rejects multi-char sym text (an unknown macro like "ab",
-- a function name like "sin") that would otherwise be truncated to its first
-- letter, since cp_of only decodes the leading character.
local function proxy_of(glyph)
  if #glyph == 0 then
    return nil
  end
  local cp = cp_of(glyph)
  if utf8c(cp) ~= glyph then
    return nil
  end
  return is_var_cp(cp) and utf8c(PROXY0 + cp) or nil
end

local function is_proxy_cp(cp)
  return cp >= PROXY0 and cp < PROXY0 + 0x1000
end

-- Replace every proxy with its real glyph (fast path: a proxy's lead byte is 0xEE).
local function strip_proxies(s)
  if not s:find("\238", 1, true) then
    return s
  end
  local out = {}
  for ch in chars(s) do
    local cp = cp_of(ch)
    out[#out + 1] = is_proxy_cp(cp) and utf8c(cp - PROXY0) or ch
  end
  return table.concat(out)
end

-- Split `s` into a run list { { text, var }, … }, restoring proxy glyphs and
-- coalescing adjacent runs of the same kind.
local function to_runs(s)
  local runs = {}
  for ch in chars(s) do
    local cp = cp_of(ch)
    local var = is_proxy_cp(cp)
    local glyph = var and utf8c(cp - PROXY0) or ch
    local last = runs[#runs]
    if last and last.var == var then
      last.text = last.text .. glyph
    else
      runs[#runs + 1] = { text = glyph, var = var }
    end
  end
  return runs
end

local render_single

-- Parenthesize `str` when linearising it could be misread: a compound (more
-- than one atom), or a lone fraction (whose own "/" would run into the outer
-- one, e.g. \frac{\frac{a}{b}}{c} must read "(a/b)/c", not "a/b/c").
local function paren(str, nodes)
  local ambiguous = #nodes > 1 or (nodes[1] and nodes[1].kind == "frac")
  return ambiguous and ("(" .. str .. ")") or str
end

-- `upright` (default false) suppresses variable-proxying: it is set for content
-- that is explicitly fonted (\text, \mathbf, …) and for scripts/limits (rendered
-- small, kept plain so the unicode super/subscript maps still apply).
render_single = function(nodes, upright)
  local parts = {}
  for _, node in ipairs(nodes) do
    local base
    if node.kind == "sym" or node.kind == "bigop" then
      base = (not upright and proxy_of(node.text)) or node.text
    elseif node.kind == "group" then
      base = render_single(node.body, upright)
    elseif node.kind == "frac" then
      base = paren(render_single(node.num, upright), node.num)
        .. "/"
        .. paren(render_single(node.den, upright), node.den)
    elseif node.kind == "sqrt" then
      local prefix = ""
      if node.index then
        local s = render_single(node.index, true)
        prefix = map_all(s, SUP) or s
      end
      base = prefix .. "√" .. paren(render_single(node.body, upright), node.body)
    elseif node.kind == "binom" then
      -- flat: the standard C(n, k) coefficient notation (the 2D form is display)
      base = "C(" .. render_single(node.num, upright) .. ", " .. render_single(node.den, upright) .. ")"
    elseif node.kind == "styled" then
      base = restyle(render_single(node.body, true), FONTS[node.font])
    elseif node.kind == "accent" then
      -- a combining mark trails each base char; a single base is the common case
      base = render_single(node.body, upright) .. node.accent.combining
    elseif node.kind == "overlay" then
      -- \not: a combining overlay on the (single) following atom
      base = render_single(node.body, upright) .. node.mark
    elseif node.kind == "overline" then
      -- a combining overline after every char yields a continuous bar
      local acc = {}
      for ch in chars(render_single(node.body, upright)) do
        acc[#acc + 1] = ch .. OVERLINE_MARK
      end
      base = table.concat(acc)
    elseif node.kind == "wideaccent" then
      -- the combining mark trails every char, so it spans the whole argument
      local acc = {}
      for ch in chars(render_single(node.body, upright)) do
        acc[#acc + 1] = ch .. node.accent.combining
      end
      base = table.concat(acc)
    elseif node.kind == "overbrace" or node.kind == "underbrace" then
      base = render_single(node.body, upright) -- the brace is a display-only flourish
    elseif node.kind == "overset" then
      local t = render_single(node.over, true)
      base = render_single(node.base, upright) .. (map_all(t, SUP) or ("^(" .. t .. ")"))
    elseif node.kind == "underset" then
      local u = render_single(node.under, true)
      base = render_single(node.base, upright) .. (map_all(u, SUB) or ("_(" .. u .. ")"))
    elseif node.kind == "pmod" then
      base = "(mod " .. render_single(node.body, upright) .. ")"
    elseif node.kind == "matrix" then
      -- flatten: cells joined by ", ", rows by "; ", wrapped in the delimiters
      local rws = {}
      for _, row in ipairs(node.rows) do
        local cs = {}
        for _, cell in ipairs(row) do
          cs[#cs + 1] = render_single(cell, upright)
        end
        rws[#rws + 1] = table.concat(cs, ", ")
      end
      local d = ENV_DELIMS[node.env] or { "", "" }
      base = d[1] .. table.concat(rws, "; ") .. d[2]
    elseif node.kind == "delim" then
      base = (DELIM[node.left] or node.left)
        .. render_single(node.body, upright)
        .. (DELIM[node.right] or node.right)
    else
      base = ""
    end
    if node.sup then
      local s = render_single(node.sup, true)
      base = base .. (map_all(s, SUP) or ("^(" .. s .. ")"))
    end
    if node.sub then
      local s = render_single(node.sub, true)
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

-- Cached PROXIED single-line render (variables as proxy codepoints); M.single and
-- M.single_spans derive the plain string and the run list from it.
local function proxied_single(tex)
  local hit = single_cache[tex]
  if hit == nil then
    hit = render_single(parse(tex), false)
    single_cache[tex] = hit
    bump()
  end
  return hit
end

-- Render `tex` as a single Unicode line (inline math).
---@param tex string
---@return string
function M.single(tex)
  return strip_proxies(proxied_single(tex))
end

-- Inline math as a run list { { text, var }, … }; `var` runs are the variables to
-- italicise. The plain text is the runs concatenated.
---@param tex string
---@return { text: string, var: boolean }[]
function M.single_spans(tex)
  return to_runs(proxied_single(tex))
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

-- `index` (optional) is the nth-root degree, drawn small in the leading gutter
-- above the radical (\sqrt[3]{x}). Its width shifts the radical right by `iw`.
local function sqrt_box(body, index)
  local w = body.w
  local idx = ""
  if index then
    local s = render_single(index, true)
    idx = map_all(s, SUP) or s
  end
  local iw = dw(idx)
  -- Single-row body: the compact form. The vinculum uses "_" (bottom of its
  -- cell) so on the row above it hugs the content rather than floating.
  if body.h == 1 then
    return {
      lines = { pad_to(idx, iw) .. " " .. ("_"):rep(w), spaces(iw) .. "√" .. pad_to(body.lines[1], w) },
      w = iw + w + 1,
      h = 2,
      axis = 1,
    }
  end
  -- Tall body: a growing radical. A "╲╱" check at the bottom-left, a "╱"
  -- diagonal rising one column per row to the top bar, drawn with single-width
  -- box glyphs so it stays on the grid.
  local h = body.h
  local g = h + 1 -- gutter width (the diagonal rises across these columns)
  -- the vinculum sits over the CONTENT (its left end already meets the "╱"
  -- apex at the cell corner); extending it further left would cover the diagonal
  local lines = { pad_to(idx, iw) .. spaces(g) .. ("_"):rep(w) }
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
    lines[i + 1] = spaces(iw) .. table.concat(gut) .. pad_to(body.lines[i], w)
  end
  return { lines = lines, w = iw + g + w, h = h + 1, axis = body.axis + 1 }
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

-- \binom: numerator over denominator with NO bar, wrapped in parens sized to
-- the stacked height. Like frac_box minus the vinculum.
local function binom_box(num, den)
  local w = math.max(num.w, den.w)
  local lines = {}
  for i = 1, num.h do
    lines[#lines + 1] = center(num.lines[i], w)
  end
  for i = 1, den.h do
    lines[#lines + 1] = center(den.lines[i], w)
  end
  local h = #lines
  -- The binom has no bar row, so its centre falls on the boundary BETWEEN the
  -- numerator and denominator (num.h - 0.5). Per the house convention every
  -- even-height stack rounds its axis to the LOWER of the two middle rows, so
  -- that is num.h (the first denominator row); a big operator and a matrix round
  -- the same way, keeping them all on one axis (see bigop_box / matrix_box).
  local inner = { lines = lines, w = w, h = h, axis = num.h }
  local lg = fence_lines("(", h)
  local rg = fence_lines(")", h)
  return hcat({
    { lines = lg, w = dw(lg[1]), h = h, axis = inner.axis },
    inner,
    { lines = rg, w = dw(rg[1]), h = h, axis = inner.axis },
  })
end

local render_stack

-- Inline scripts (unicode, or ^()/_() fallback) for a tall base box. Scripts are
-- kept upright (no variable proxies) so the small-form maps still apply.
local function scripts_text(node)
  local out = ""
  if node.sup then
    local s = render_single(node.sup, true)
    out = out .. (map_all(s, SUP) or ("^(" .. s .. ")"))
  end
  if node.sub then
    local s = render_single(node.sub, true)
    out = out .. (map_all(s, SUB) or ("_(" .. s .. ")"))
  end
  return out
end

-- One script rendered small (unicode super/subscript) where every char maps,
-- else the plain string (its raised/lowered position still reads as a script).
local function script_str(nodes, map)
  local s = render_single(nodes, true)
  return map_all(s, map) or s
end

-- Attach a node's scripts to its rendered base box. An atom-height base keeps the
-- compact inline form on its single row (x²ᵢ). A TALL base (fraction, fence,
-- root) instead gets a right-hand column with the superscript on its TOP row and
-- the subscript on its BOTTOM row, so neither lands on the vertical centre.
local function attach_scripts(b, node)
  if not (node.sup or node.sub) then
    return b
  end
  if b.h == 1 then
    local sc = scripts_text(node)
    return sc ~= "" and hcat({ b, text_box(sc) }) or b
  end
  local sup = node.sup and script_str(node.sup, SUP) or nil
  local sub = node.sub and script_str(node.sub, SUB) or nil
  local cw = math.max(sup and dw(sup) or 0, sub and dw(sub) or 0)
  local lines = {}
  for i = 1, b.h do
    local seg = ""
    if i == 1 and sup then
      seg = sup
    elseif i == b.h and sub then
      seg = sub
    end
    lines[i] = pad_to(seg, cw)
  end
  return hcat({ b, { lines = lines, w = cw, h = b.h, axis = b.axis } })
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
  local s = render_single(nodes, true)
  local small = map_all(s, map)
  if small then
    return { lines = { small }, w = dw(small), h = 1, axis = 0 }
  end
  return render_stack(nodes, true)
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
  -- axis on the operator's middle piece, so the summand aligns to its centre;
  -- an even piece count rounds to the LOWER of the two middle rows (house
  -- convention, shared with binom_box and matrix_box) via ceil
  local axis = #lines + math.ceil((#pieces - 1) / 2)
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

-- Pad every line of a box to width `w`, aligned left / right / centre.
local function pad_cell(box, w, align)
  local lines = {}
  for i, l in ipairs(box.lines) do
    if align == "right" then
      lines[i] = spaces(w - dw(l)) .. l
    elseif align == "left" then
      lines[i] = pad_to(l, w)
    else
      lines[i] = center(l, w)
    end
  end
  return { lines = lines, w = w, h = box.h, axis = box.axis }
end

-- A matrix-like environment: a grid of cell boxes laid out in aligned columns,
-- stacked into rows, then wrapped in the environment's delimiters (sized to the
-- grid height). Columns are 2 spaces apart.
local function matrix_box(node)
  local cells, ncol = {}, 0
  for r, row in ipairs(node.rows) do
    cells[r] = {}
    for c, cell in ipairs(row) do
      cells[r][c] = render_stack(cell, false)
    end
    ncol = math.max(ncol, #row)
  end
  local colw, align = {}, {}
  for c = 1, ncol do
    local w = 0
    for r = 1, #cells do
      if cells[r][c] then
        w = math.max(w, cells[r][c].w)
      end
    end
    colw[c] = w
    if node.env == "cases" then
      align[c] = "left"
    elseif ALIGN_ALTERNATE[node.env] then
      align[c] = (c % 2 == 1) and "right" or "left"
    else
      align[c] = "center"
    end
  end
  -- each row: cells padded to their column, joined by a 2-space gap column
  local rowboxes = {}
  for r = 1, #cells do
    local parts = {}
    for c = 1, ncol do
      parts[#parts + 1] = pad_cell(cells[r][c] or text_box(""), colw[c], align[c])
      if c < ncol then
        parts[#parts + 1] = { lines = { "  " }, w = 2, h = 1, axis = 0 }
      end
    end
    rowboxes[r] = hcat(parts)
  end
  -- stack the rows; the grid's axis is its vertical centre
  local w = 0
  for _, b in ipairs(rowboxes) do
    w = math.max(w, b.w)
  end
  local lines = {}
  for _, b in ipairs(rowboxes) do
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = pad_to(l, w)
    end
  end
  -- centre the grid on the row shared by all even-height stacks: the LOWER of
  -- the two middle rows (ceil), matching binom_box and bigop_box
  local grid = { lines = lines, w = w, h = #lines, axis = math.ceil((#lines - 1) / 2) }
  local d = ENV_DELIMS[node.env]
  if not d then
    return grid
  end
  local parts = {}
  if d[1] ~= "" then
    local lg = fence_lines(d[1], grid.h)
    parts[#parts + 1] = { lines = lg, w = dw(lg[1]), h = grid.h, axis = grid.axis }
  end
  parts[#parts + 1] = grid
  if d[2] ~= "" then
    local rg = fence_lines(d[2], grid.h)
    parts[#parts + 1] = { lines = rg, w = dw(rg[1]), h = grid.h, axis = grid.axis }
  end
  return hcat(parts)
end

local function box_of(node, upright)
  if node.kind == "sym" then
    -- a plain atom (with its scripts) is one inline row
    return text_box(render_single({ node }, upright))
  end
  if node.kind == "bigop" then
    return bigop_box(node, 1) -- fallback size; render_stack sizes to the summand
  end
  if node.kind == "matrix" then
    return attach_scripts(matrix_box(node), node)
  end
  -- \overbrace / \underbrace: a horizontal brace hugging the content, with the
  -- optional ^/_ label set beyond the brace (consumed here, not by attach_scripts).
  if node.kind == "overbrace" or node.kind == "underbrace" then
    local body = render_stack(node.body, upright)
    local label = nil
    if node.kind == "overbrace" and node.sup then
      label = render_stack(node.sup, upright)
    elseif node.kind == "underbrace" and node.sub then
      label = render_stack(node.sub, upright)
    end
    local w = math.max(body.w, label and label.w or 0)
    local brace = ((node.kind == "overbrace") and "⏞" or "⏟"):rep(w)
    local lines = {}
    local axis
    if node.kind == "overbrace" then
      if label then
        for _, l in ipairs(label.lines) do
          lines[#lines + 1] = center(l, w)
        end
      end
      lines[#lines + 1] = brace
      axis = #lines - 1 + body.axis
      for _, l in ipairs(body.lines) do
        lines[#lines + 1] = center(l, w)
      end
    else
      axis = body.axis
      for _, l in ipairs(body.lines) do
        lines[#lines + 1] = center(l, w)
      end
      lines[#lines + 1] = brace
      if label then
        for _, l in ipairs(label.lines) do
          lines[#lines + 1] = center(l, w)
        end
      end
    end
    return { lines = lines, w = w, h = #lines, axis = axis }
  end
  local b
  if node.kind == "frac" then
    b = frac_box(render_stack(node.num, upright), render_stack(node.den, upright))
  elseif node.kind == "sqrt" then
    b = sqrt_box(render_stack(node.body, upright), node.index)
  elseif node.kind == "binom" then
    b = binom_box(render_stack(node.num, upright), render_stack(node.den, upright))
  elseif node.kind == "group" then
    b = render_stack(node.body, upright)
  elseif node.kind == "styled" then
    b = render_stack(node.body, true)
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
    b = render_stack(node.body, upright)
    local top = center(node.accent.glyph, b.w)
    local lines = { top }
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = l
    end
    b = { lines = lines, w = b.w, h = b.h + 1, axis = b.axis + 1 }
  elseif node.kind == "overline" then
    -- a bar row hugging the top of the content (▁ sits at the bottom of its cell)
    b = render_stack(node.body, upright)
    local lines = { ("▁"):rep(b.w) }
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = l
    end
    b = { lines = lines, w = b.w, h = b.h + 1, axis = b.axis + 1 }
  elseif node.kind == "wideaccent" then
    -- a mark row spanning the content width (an arrow for the vector forms)
    b = render_stack(node.body, upright)
    local w, shape = b.w, node.accent.shape
    local top
    -- the stem is an em dash (U+2014), which meets the arrowhead's baseline in
    -- Iosevka; the box-drawing rule "─" sits too high and detaches from the head
    if shape == "aright" then
      top = ("—"):rep(math.max(w - 1, 0)) .. "→"
    elseif shape == "aleft" then
      top = "←" .. ("—"):rep(math.max(w - 1, 0))
    elseif shape == "aboth" then
      top = "←" .. ("—"):rep(math.max(w - 2, 0)) .. "→"
    elseif shape == "tilde" then
      top = center("~", w)
    else
      top = center("^", w)
    end
    local lines = { top }
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = l
    end
    b = { lines = lines, w = w, h = b.h + 1, axis = b.axis + 1 }
  elseif node.kind == "overset" or node.kind == "underset" then
    local base = render_stack(node.base, upright)
    local extra = render_stack(node.kind == "overset" and node.over or node.under, upright)
    local w = math.max(base.w, extra.w)
    local lines = {}
    local top = (node.kind == "overset") and extra or base
    local bot = (node.kind == "overset") and base or extra
    for _, l in ipairs(top.lines) do
      lines[#lines + 1] = center(l, w)
    end
    for _, l in ipairs(bot.lines) do
      lines[#lines + 1] = center(l, w)
    end
    -- keep the base atom on the math axis (over sets ride above it, under below)
    local axis = (node.kind == "overset") and (extra.h + base.axis) or base.axis
    b = { lines = lines, w = w, h = #lines, axis = axis }
  elseif node.kind == "pmod" then
    b = hcat({ text_box("(mod "), render_stack(node.body, upright), text_box(")") })
  elseif node.kind == "overlay" then
    -- \not: overlay the combining mark on the base's axis row (width unchanged)
    b = render_stack(node.body, upright)
    local lines = {}
    for i, l in ipairs(b.lines) do
      lines[i] = (i == b.axis + 1) and (l .. node.mark) or l
    end
    b = { lines = lines, w = b.w, h = b.h, axis = b.axis }
  elseif node.kind == "delim" then
    -- fences sized to the content height, drawn to the left/right of its box
    local inner = render_stack(node.body, upright)
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
  return attach_scripts(b, node)
end

render_stack = function(nodes, upright)
  if #nodes == 0 then
    return text_box("")
  end
  -- render everything except big operators first; a big operator's glyph is
  -- sized to its summand, which is the content to its right (look-ahead).
  local boxes = {}
  for idx, node in ipairs(nodes) do
    boxes[idx] = (node.kind ~= "bigop") and box_of(node, upright) or false
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

-- Cached PROXIED display render (lines with variable proxies); M.stack and
-- M.stack_spans derive plain lines and per-line run lists from it.
local function proxied_stack(tex)
  local hit = stack_cache[tex]
  if hit == nil then
    hit = render_stack(parse(tex), false).lines
    stack_cache[tex] = hit
    bump()
  end
  return hit
end

-- Render `tex` as a 2D block of Unicode lines (display math).
---@param tex string
---@return string[] lines
function M.stack(tex)
  local out = {}
  for i, l in ipairs(proxied_stack(tex)) do
    out[i] = strip_proxies(l)
  end
  return out
end

-- Display math as a list of per-line run lists ({ text, var }); `var` runs are
-- the variables to italicise. Each line's plain text is its runs concatenated.
---@param tex string
---@return { text: string, var: boolean }[][]
function M.stack_spans(tex)
  local out = {}
  for i, l in ipairs(proxied_stack(tex)) do
    out[i] = to_runs(l)
  end
  return out
end

return M
