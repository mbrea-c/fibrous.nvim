-- fibrous.targets: a GLOBAL registry of the interactive elements currently
-- visible on screen, across every live mount and all its windows/floats. The
-- output is PURE GEOMETRY, shaped to drop into flash.nvim's custom matcher:
--
--   { winid, pos = { row, col }, end_pos = { row, col }, kind, role }
--
-- row is 1-based, col 0-based byte (nvim/flash convention). `targets(opts)`
-- collects from every registered mount and filters; each mount registers a
-- provider on creation and unregisters on teardown (see inline/mount.lua). A
-- mount's provider gathers its ROOT elements (this module) plus its subwindow
-- elements (subwin.lua's collect_targets, which reuses `collect` below with a
-- resolver per float — native float coords when shown, parent MIRROR cells when
-- an unfocused container is standing in as a mirror).
--
-- Why fibrous can hand these out cheaply: the inline host already keeps each
-- flush target's laid-out tree (rects in buffer cells) and the cursor IS the
-- pointer, so "jump to a widget" is just "move the cursor to a cell" — flash
-- jumps there and <CR>/click activates through the existing interaction layer.

local width = require("fibrous.inline.width")

local M = {}

-- token -> provider fn. A provider returns this mount's current visible targets.
local providers = {}

--- Register a target provider (a mount). Returns an opaque token for unregister.
--- @param fn fun(): table[]  returns the mount's currently-visible targets
--- @return table token
function M.register(fn)
  local token = {}
  providers[token] = fn
  return token
end

--- Deregister a provider (on mount teardown).
--- @param token table
function M.unregister(token)
  providers[token] = nil
end

--- The kind label for an interactive node: its subwindow type, else its role.
--- @param node table
--- @return string|nil
function M.node_kind(node)
  if node.subwin then
    return node.subwin -- "text_input" | "raw_buffer" | "container"
  end
  return node.props and node.props.role or nil
end

--- Line `row` (0-based) of `bufnr`, or "".
--- @param bufnr integer
--- @param row integer
--- @return string
function M.line_at(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

--- The inclusive 1-based [top, bot] buffer lines visible in `winid`, or nil.
--- @param winid integer
--- @return integer?, integer?
function M.visible_range(winid)
  local info = vim.fn.getwininfo(winid)[1]
  if not info then
    return nil
  end
  return info.topline, info.botline
end

--- Walk `tree`; for each ROLE-carrying (non-subwindow) node, call
--- `resolve(content_box) -> { winid, pos, end_pos } | nil` and, when it resolves,
--- emit a target. `resolve` owns coordinate mapping + on-screen filtering, so the
--- same walk serves the root buffer, a visible float, and a parent mirror.
--- @param tree table|nil
--- @param resolve fun(box: {x:integer,y:integer,w:integer,h:integer}): table|nil
--- @return table[]
function M.collect(tree, resolve)
  local out = {}
  local function walk(node)
    if node.props and node.props.role and not node.subwin then
      -- rect is the full border-box (themed padding/background included) so the
      -- flash label spans the WHOLE widget, not just its inner text.
      local box = node.rect or node.content
      if box then
        local geo = resolve(box)
        if geo then
          out[#out + 1] = {
            winid = geo.winid,
            pos = geo.pos,
            end_pos = geo.end_pos,
            kind = M.node_kind(node),
            role = node.props.role,
          }
        end
      end
    end
    -- Interactive spans (links) inside a text leaf: one target per logical span,
    -- anchored at its first VISIBLE fragment's cell (resolve viewport-filters).
    if node.kind == "text" and node.line_runs then
      local content = node.content
      local seen = {}
      for li, runs in ipairs(node.line_runs) do
        local cx = content.x
        for _, run in ipairs(runs) do
          local w = width.str(run.text)
          if run.id and (run.on_click or run.role) and not seen[run.id] then
            local geo = resolve({ x = cx, y = content.y + li - 1, w = w, h = 1 })
            if geo then
              seen[run.id] = true
              out[#out + 1] = {
                winid = geo.winid,
                pos = geo.pos,
                end_pos = geo.end_pos,
                kind = run.role or "span",
                role = run.role,
              }
            end
          end
          cx = cx + w
        end
      end
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  if tree then
    walk(tree)
  end
  return out
end

--- A resolver that maps a content box straight to buffer coords in `winid`
--- (buffer `bufnr`), dropping rows outside the window's viewport. For the root
--- and for VISIBLE floats, where the buffer is shown directly so box coords ARE
--- the display coords.
--- @param winid integer
--- @param bufnr integer
--- @return fun(box: table): table|nil
function M.window_resolver(winid, bufnr)
  local top, bot = M.visible_range(winid)
  return function(box)
    local row = box.y -- 0-based buffer row
    if top and (row + 1 < top or row + 1 > bot) then
      return nil -- off-screen
    end
    -- Single-LINE match, on the box's TOP row. flash is line-oriented: a match
    -- whose pos/end_pos straddle rows (a bordered or tall widget's border-box)
    -- mislabels and mis-highlights. Anchoring at the top row keeps flash happy;
    -- the cursor still lands on the widget (hover/activation is by cell), so
    -- jump-to-activate is unaffected. The label sits at the widget's top-left.
    local line = M.line_at(bufnr, row)
    return {
      winid = winid,
      pos = { row + 1, width.cell_to_byte(line, box.x) },
      end_pos = { row + 1, width.cell_to_byte(line, box.x + box.w) },
    }
  end
end

--- Extract the role-carrying elements of a flush `target` (its laid-out tree) as
--- geometry targets shown in window `winid` (buffer target.bufnr).
--- @param target { tree: table, bufnr: integer }
--- @param winid integer
--- @return table[]
function M.extract(target, winid)
  if not (target and target.tree and winid and vim.api.nvim_win_is_valid(winid)) then
    return {}
  end
  return M.collect(target.tree, M.window_resolver(winid, target.bufnr))
end

--- flash.nvim renders the jump label one cell AFTER end_pos (label.after ->
--- offset {0,1}) as an overlay, and an overlay cannot leave the window: a
--- span reaching the window's right edge pushes the label off-screen, and a
--- span ending at the line's very end trips flash's char math (charidx past
--- the end returns -1) and strands the label at column 0. Either way the
--- target has no readable label and cannot be jumped to. Every emitter is
--- exposed — full-width widgets in the root, content-sized input floats
--- (whose line IS the window width), mirrors against the parent's edge — so
--- the clamp lives here in the one funnel they all pass through: pull
--- end_pos back until the label cell is a real, visible character cell. The
--- match highlight understates the widget by a cell or two at the edge,
--- which is invisible next to a target that cannot be jumped to at all.
--- @param t table target ({ winid, pos, end_pos }, single-line by contract)
--- @param wins table per-call cache of window metrics, keyed by winid
local function clamp_label(t, wins)
  local win = wins[t.winid]
  if win == nil then
    local info = vim.fn.getwininfo(t.winid)[1]
    win = info
        and {
          wrap = vim.wo[t.winid].wrap,
          bufnr = info.bufnr,
          textw = info.width - info.textoff,
          leftcol = vim.api.nvim_win_call(t.winid, function()
            return vim.fn.winsaveview().leftcol
          end),
        }
      or false
    wins[t.winid] = win
  end
  if not win or win.wrap then
    return -- wrapped lines always give the label a cell to land on
  end
  local row = t.end_pos[1]
  local line = M.line_at(win.bufnr, row - 1)
  local endcell = width.str(line:sub(1, t.end_pos[2]))
  -- Rightmost end cell whose label cell (one further) is still a real
  -- character inside the viewport: bounded by the window's last text column
  -- and by the line's last character (the after-end-of-line position is
  -- exactly the window edge in a content-sized float).
  local max_end = math.min(win.leftcol + win.textw, width.str(line)) - 2
  if endcell > max_end then
    -- never pull the end before the start; a widget living entirely in the
    -- last two columns stays as it is (only a before-style label could serve
    -- it, and that is the consumer's flash config, not geometry)
    local startcell = width.str(line:sub(1, t.pos[2]))
    t.end_pos = { row, width.cell_to_byte(line, math.max(max_end, startcell)) }
  end
end

--- Collect all currently-visible interactive targets across every mount.
--- @param opts? { winid?: integer, kinds?: string[], predicate?: fun(t: table): boolean }
--- @return table[]
function M.targets(opts)
  opts = opts or {}
  local kinds
  if opts.kinds then
    kinds = {}
    for _, k in ipairs(opts.kinds) do
      kinds[k] = true
    end
  end

  local out = {}
  local wins = {}
  for _, provider in pairs(providers) do
    local ok, list = pcall(provider)
    if ok and list then
      for _, t in ipairs(list) do
        if
          (not opts.winid or t.winid == opts.winid)
          and (not kinds or kinds[t.kind])
          and (not opts.predicate or opts.predicate(t))
        then
          clamp_label(t, wins)
          out[#out + 1] = t
        end
      end
    end
  end
  return out
end

return M
