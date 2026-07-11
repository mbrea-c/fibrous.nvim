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
  for _, provider in pairs(providers) do
    local ok, list = pcall(provider)
    if ok and list then
      for _, t in ipairs(list) do
        if
          (not opts.winid or t.winid == opts.winid)
          and (not kinds or kinds[t.kind])
          and (not opts.predicate or opts.predicate(t))
        then
          out[#out + 1] = t
        end
      end
    end
  end
  return out
end

return M
