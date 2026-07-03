-- The inline HostConfig (tracker "NEW UI HOST" task 3): the concrete bridge
-- the reconciler drives for the inline UI host. Rather than giving every
-- leaf its own window, the WHOLE committed fiber tree becomes one layout
-- tree (layout.compute), one painted canvas (render.paint), and one flush into
-- a single host-owned scratch buffer — full lines plus extmark highlight
-- spans. A mount target (inline/mount.lua) shows that buffer in the root float
-- and owns all window concerns; this module never touches windows.
--
-- Sizing is injected via `opts.get_size`, read at every flush so the mount
-- target's window is the single source of truth. height = nil is scroll mode
-- (canvas height = content height; the window is a viewport over the buffer),
-- a number is app mode (fixed canvas). `relayout()` re-runs layout + paint at
-- the current size from the last committed tree without re-rendering any
-- component — the mount target's resize-sync entry point.
--
-- Per the perf posture (tracker Decisions): a commit is a full function of
-- (fiber tree, size) — full measure + repaint every time, no diffing yet.
-- Instances are therefore just tag markers; the tree is rebuilt from the
-- committed fibers at flush time.

local layout = require("fibrous.inline.layout")
local render = require("fibrous.inline.render")
local style = require("fibrous.inline.style")
local theme = require("fibrous.inline.theme")

local M = {}

local CONTAINERS = { col = true, row = true }
-- text_input is a subwindow leaf: laid out (and its border/background painted)
-- inline like any node, but its content box is covered by a real float that
-- subwin.lua manages — the node carries `subwin` so the manager can find it.
local LEAVES = { text = true, text_input = true, raw_buffer = true }

-- One namespace for all inline hosts; each host only ever clears its own buffer.
local ns = vim.api.nvim_create_namespace("fibrous_inline")

-- Attach the node's normalized style plus its state-applied resolution
-- ("Style rework"): normalize once per commit, seeding the theme defaults the
-- node's `theme` prop keys into (components tag themselves; `theme = false`
-- opts out); when the fiber has active interaction states, apply them so
-- layout/paint see the overridden style. With no states the base IS the
-- resolution — shared, no copy.
---@param node table
---@param states table<Fiber, table>
local function attach_style(node, states)
  local props = node.props or {}
  local defaults = nil
  if props.theme then
    defaults = theme.styles[props.theme]
    if not defaults then
      error("fibrous: unknown theme key '" .. tostring(props.theme) .. "'")
    end
  elseif props.theme == nil then
    -- No explicit key: host primitives default to their own tag (text_input,
    -- text, col, row, raw_buffer), so theme.styles can target a whole node
    -- kind. A missing entry is simply unthemed; `theme = false` opts out.
    defaults = theme.styles[node.subwin or node.kind]
  end
  local norm = style.normalize(props, defaults)
  node.style = norm
  local active = states[node.fiber]
  node.style_resolved = active and style.apply(norm, active) or norm.base
  return node
end

-- Build the layout-tree node for a fiber, descending through function
-- components to the host nodes they render. Each node keeps a `fiber` backref
-- (the hit-map ground truth for cursor interaction, task 6).
---@param fiber Fiber
---@param states table<Fiber, table>  active interaction states, keyed by fiber
---@return table|nil node
local function build_node(fiber, states)
  if type(fiber.type) == "function" then
    local child = fiber.child_fibers and fiber.child_fibers[1]
    return child and build_node(child, states) or nil
  end

  local tag = fiber.type.__host
  local props = fiber.props or {}
  if CONTAINERS[tag] then
    local children = {}
    for _, cf in ipairs(fiber.child_fibers or {}) do
      local node = build_node(cf, states)
      if node then
        children[#children + 1] = node
      end
    end
    return attach_style({ kind = tag, props = props, children = children, fiber = fiber }, states)
  end
  if tag == "text_input" or tag == "raw_buffer" then
    -- Subwindow leaves measure as text (one content row unless props size
    -- them); the float shows the real content, so nothing is painted in the
    -- content box — but border/background still render inline in the root
    -- buffer. A raw_buffer without an explicit height sizes itself to its
    -- buffer's line count: N-1 newlines measure as N empty rows.
    local text = ""
    if tag == "raw_buffer" and not props.height then
      local count = props.bufnr
          and vim.api.nvim_buf_is_valid(props.bufnr)
          and vim.api.nvim_buf_line_count(props.bufnr)
        or 1
      text = ("\n"):rep(count - 1)
    end
    return attach_style({ kind = "text", props = props, text = text, subwin = tag, fiber = fiber }, states)
  end
  return attach_style({ kind = "text", props = props, text = props.text or "", fiber = fiber }, states)
end

-- Collect the laid-out subwindow nodes of `tree` (document order).
---@param node table
---@param out table[]
local function collect_subwins(node, out)
  if node.subwin then
    out[#out + 1] = node
  end
  for _, child in ipairs(node.children or {}) do
    collect_subwins(child, out)
  end
end

---@class InlineHostOpts
---@field get_size fun(): { width: integer, height: integer|nil }  read at every flush; nil height = scroll mode
---@field on_flush? fun()  called after every flush (commit or relayout) so the subwin manager can resync its floats

---@class InlineHost : HostConfig
---@field bufnr integer   the host-owned scratch buffer mount targets display
---@field ns integer      extmark namespace of the highlight spans
---@field tree table|nil  the last laid-out tree (rects are buffer coordinates)
---@field subwins table[] laid-out subwindow nodes of the last flush (document order)
---@field set_state fun(fiber: Fiber, name: "hover"|"focus", on: boolean?)  record an interaction state (structural style overrides only)

-- Construct a fresh inline HostConfig around its own scratch buffer.
---@param opts InlineHostOpts
---@return InlineHost
function M.new(opts)
  theme.apply()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = false

  ---@type Fiber|nil  the most recently committed root, so relayout can re-flush
  local last_root = nil

  -- Active interaction states per fiber ({ hover?, focus? }), set by the
  -- interaction layers (interact.lua, subwin.lua) — only for STRUCTURAL
  -- overrides, which must flow through layout; hl-only overrides paint as
  -- overlay extmarks and never come through here. Weak keys: unmounted
  -- fibers drop out on their own.
  local states = setmetatable({}, { __mode = "k" })

  ---@type InlineHost
  local host

  -- Rebuild, lay out, paint and write the committed tree at the current size.
  local function flush()
    if not last_root or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local tree = build_node(last_root, states)
    local size = opts.get_size()
    local canvas_lines, canvas_hls = {}, {}
    local subwins = {}
    if tree then
      layout.compute(tree, { width = size.width, height = size.height })
      local canvas = render.paint(tree, size.width, size.height or tree.size.h)
      canvas_lines, canvas_hls = canvas:lines(), canvas:highlights()
      collect_subwins(tree, subwins)
    end
    host.tree = tree
    host.subwins = subwins

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, canvas_lines)
    vim.bo[bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, s in ipairs(canvas_hls) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, s.row, s.start_col, {
        end_col = s.end_col,
        hl_group = s.hl,
      })
    end

    if opts.on_flush then
      opts.on_flush()
    end
  end

  host = {
    bufnr = bufnr,
    ns = ns,
    tree = nil,
    subwins = {},

    create_instance = function(tag)
      if not (CONTAINERS[tag] or LEAVES[tag]) then
        error("fibrous.inline: unknown host primitive '" .. tostring(tag) .. "'")
      end
      return { tag = tag }
    end,

    -- The flush works wholesale from the committed fiber tree, so per-instance
    -- update/destroy have nothing to do.
    update_instance = function() end,
    destroy_instance = function() end,

    commit = function(root_fiber)
      last_root = root_fiber
      flush()
    end,

    relayout = flush,

    -- Flip one interaction state for a fiber. The caller decides when a
    -- relayout is due — set_state only records.
    set_state = function(fiber, name, on)
      local s = states[fiber]
      if on then
        if not s then
          s = {}
          states[fiber] = s
        end
        s[name] = true
      elseif s then
        s[name] = nil
        if next(s) == nil then
          states[fiber] = nil
        end
      end
    end,

    teardown = function()
      last_root = nil
      host.tree = nil
      host.subwins = {}
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end,
  }
  return host
end

return M
