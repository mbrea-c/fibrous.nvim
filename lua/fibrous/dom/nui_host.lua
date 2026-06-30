-- The Nui Bridge (design.md §1B): the concrete HostConfig that maps host
-- primitive descriptors onto live nui instances arranged by nui.layout, and
-- performs the physical buffer/window mutations. This is the ONLY layer that
-- talks to nui — the reactive core drives it through the HostConfig interface,
-- knowing nothing about it (mirrors React's renderer/HostConfig split).
--
-- Integration model (validated against nui.layout): leaf primitives become
-- *unmounted* nui components (their size lives in the enclosing Box, not the
-- component). The bridge owns a single nui.layout.Layout. After each reactive
-- render the runtime calls `commit`, which walks the committed fiber tree, builds
-- the Box tree, and either mounts the Layout (first time) or `update`s it —
-- `update` reuses the same component objects, so buffers/content survive a
-- reflow. Leaf contents are written straight to the bufnrs post-mount.

local Layout = require("nui.layout")
local Popup = require("nui.popup")

local M = {}

local CONTAINERS = { row = true, col = true }

-- Sizing options for how `fiber`'s box sits inside its parent. The root box
-- takes its size from the Layout config, so it gets none. Everything else flexes
-- (grow = 1) unless an explicit size/grow is given.
---@param fiber Fiber
---@param is_root boolean
---@return table
local function sizing(fiber, is_root)
  if is_root then
    return {}
  end
  local props = fiber.props or {}
  if props.size ~= nil then
    return { size = props.size }
  end
  if props.grow ~= nil then
    return { grow = props.grow }
  end
  return { grow = 1 }
end

-- Build a nui.layout Box for a fiber, descending through function components to
-- the host nodes they render. Containers recurse into their child fibers; leaves
-- wrap their backing nui component.
---@param fiber Fiber
---@param is_root boolean
---@return table|nil box
local function build_box(fiber, is_root)
  if type(fiber.type) == "function" then
    local child = fiber.child_fibers and fiber.child_fibers[1]
    return child and build_box(child, is_root) or nil
  end

  local tag = fiber.type.__host
  if CONTAINERS[tag] then
    local boxes = {}
    for _, child in ipairs(fiber.child_fibers or {}) do
      local box = build_box(child, false)
      if box then
        boxes[#boxes + 1] = box
      end
    end
    local opts = sizing(fiber, is_root)
    opts.dir = tag
    return Layout.Box(boxes, opts)
  end

  return Layout.Box(fiber.instance.nui, sizing(fiber, is_root))
end

-- A string capturing ONLY what affects the geometry of the Box tree: structure
-- (nesting, container direction) and sizing (size / grow), never content (lines,
-- border, focusable). Two commits with the same signature lay out identically,
-- so `commit` can skip nui's relayout when it is unchanged. This is the flicker
-- fix: content-only updates (typing, toggling a list item) no longer re-issue
-- nvim_win_set_config across every overlay, which momentarily collapsed columns.
---@param fiber Fiber
---@param is_root boolean
---@param out string[]
local function box_signature(fiber, is_root, out)
  if type(fiber.type) == "function" then
    local child = fiber.child_fibers and fiber.child_fibers[1]
    if child then
      box_signature(child, is_root, out)
    end
    return
  end

  local tag = fiber.type.__host
  local s = sizing(fiber, is_root)
  out[#out + 1] = tag .. ":" .. (s.size ~= nil and ("s=" .. vim.inspect(s.size)) or ("g=" .. tostring(s.grow)))
  if CONTAINERS[tag] then
    out[#out + 1] = "["
    for _, child in ipairs(fiber.child_fibers or {}) do
      box_signature(child, false, out)
    end
    out[#out + 1] = "]"
  end
end

-- Signature for the whole committed tree (see box_signature).
---@param root Fiber
---@return string
local function layout_signature(root)
  local out = {}
  box_signature(root, true, out)
  return table.concat(out, ",")
end

-- Walk all leaf fibers in the tree, invoking `fn(leaf_fiber)` on each. Descends
-- through function components and containers.
---@param fiber Fiber
---@param fn fun(leaf: Fiber)
local function for_each_leaf(fiber, fn)
  if type(fiber.type) == "function" or CONTAINERS[fiber.type.__host] then
    for _, child in ipairs(fiber.child_fibers or {}) do
      for_each_leaf(child, fn)
    end
    return
  end
  fn(fiber)
end

-- Write each declarative leaf's `lines` prop into its (now-mounted) buffer.
-- Leaves WITHOUT a `lines` prop are ref-managed (a component owns the buffer
-- imperatively, e.g. the transcript) and are deliberately left untouched.
---@param fiber Fiber
local function write_contents(fiber)
  for_each_leaf(fiber, function(leaf)
    if leaf.props.lines == nil then
      return
    end
    local bufnr = leaf.instance and leaf.instance.nui and leaf.instance.nui.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, leaf.props.lines)
    end
  end)
end

-- Point each leaf's `props.ref` at a handle to its live buffer/window so effects
-- (which run after commit) can drive it imperatively.
---@param fiber Fiber
local function populate_refs(fiber)
  for_each_leaf(fiber, function(leaf)
    local ref = leaf.props and leaf.props.ref
    if ref then
      local nui = leaf.instance.nui
      ref.current = { bufnr = nui.bufnr, winid = nui.winid, nui = nui }
    end
  end)
end

---@param bufnr integer
---@return string
local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Apply component-scoped keymaps (recorded by use_keymap, design.md §3B "scoped
-- keymaps"). Every fiber is visited; a fiber carrying `scoped_keymaps` has each
-- of them bound buffer-locally on EVERY leaf buffer in its own subtree, so a
-- keymap declared on a component fires wherever focus sits inside it — the
-- closest Neovim analogue to DOM event bubbling. Run on every commit: keymap.set
-- overwrites, so this is idempotent and refreshes each handler's closure.
---@param root Fiber
local function apply_scoped_keymaps(root)
  local function visit(fiber)
    if fiber.scoped_keymaps then
      for _, km in ipairs(fiber.scoped_keymaps) do
        for_each_leaf(fiber, function(leaf)
          local bufnr = leaf.instance and leaf.instance.nui and leaf.instance.nui.bufnr
          if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local opts = vim.tbl_extend("force", km.opts or {}, { buffer = bufnr })
            vim.keymap.set(km.mode, km.lhs, function()
              if km.rhs then
                km.rhs()
              end
            end, opts)
          end
        end)
      end
    end
    for _, child in ipairs(fiber.child_fibers or {}) do
      visit(child)
    end
  end
  visit(root)
end

-- Sync text_input leaves: refresh their change/submit handlers from the current
-- props every commit, and on first mount seed the initial value and wire the
-- native edit autocmd (design.md §5.3). The buffer is left as the source of
-- truth thereafter — never overwritten — so typing is never clobbered. Wired
-- inputs are recorded in `inputs` for focus().
---@param fiber Fiber
---@param inputs table[]
local function sync_inputs(fiber, inputs)
  for_each_leaf(fiber, function(leaf)
    if leaf.type.__host ~= "text_input" then
      return
    end
    local inst = leaf.instance
    inst.on_change = leaf.props.on_change
    inst.on_submit = leaf.props.on_submit

    local bufnr = inst.nui and inst.nui.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if inst.wired then
      return
    end
    inst.wired = true

    local value = leaf.props.value
    if value ~= nil and value ~= "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(value, "\n", { plain = true }))
    end

    local group = vim.api.nvim_create_augroup("FibrousInput_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        if inst.on_change then
          inst.on_change(buf_text(bufnr))
        end
      end,
    })

    -- <CR> submits the current buffer text (single-line input convention),
    -- from both insert and normal mode. The handler reads `inst.on_submit`
    -- live, so it always uses the latest committed prop.
    vim.keymap.set({ "i", "n" }, "<CR>", function()
      if inst.on_submit then
        inst.on_submit(buf_text(bufnr))
      end
    end, { buffer = bufnr, desc = "fibrous: submit input" })

    inputs[#inputs + 1] = inst
  end)
end

-- Construct a fresh HostConfig bound to a single Layout. `layout_config` is the
-- outer nui.layout geometry (relative / position / size) the whole tree sits in.
---@param layout_config table
---@return HostConfig
function M.new(layout_config)
  ---@type table|nil
  local layout = nil
  -- Wired text_input instances, in mount order, for focus().
  ---@type table[]
  local inputs = {}
  -- The most recently committed root fiber, for post-commit tree walks (e.g. a
  -- mount target installing buffer-local keymaps on every overlay).
  ---@type Fiber|nil
  local last_root = nil
  -- Geometry signature of the last laid-out tree, so content-only commits skip
  -- nui's relayout (the flicker fix; see layout_signature).
  ---@type string|nil
  local last_signature = nil

  -- Wipe the buffer when its window closes so a child removed from the tree
  -- (layout:update closes the window) doesn't leave an orphan buffer behind.
  -- Kept children retain their window across a reflow, so this only fires on
  -- genuine removal. User opts take precedence.
  local function leaf_buf_options(props)
    return vim.tbl_extend("keep", props.buf_options or {}, { bufhidden = "wipe" })
  end

  return {
    create_instance = function(tag, props)
      if CONTAINERS[tag] then
        return { tag = tag }
      end
      if tag == "text" then
        return {
          tag = tag,
          nui = Popup({
            border = props.border or "none",
            focusable = props.focusable or false,
            win_options = props.win_options,
            buf_options = leaf_buf_options(props),
          }),
        }
      end
      if tag == "text_input" then
        return {
          tag = tag,
          wired = false,
          nui = Popup({
            border = props.border or "none",
            focusable = true,
            enter = false,
            win_options = props.win_options,
            buf_options = leaf_buf_options(props),
          }),
        }
      end
      error("fibrous: unknown host primitive '" .. tostring(tag) .. "'")
    end,

    -- Content/geometry updates are applied wholesale in `commit` (which has the
    -- full committed tree), so per-instance update is a no-op here.
    update_instance = function() end,

    -- Leaf windows are owned by the Layout; tearing the Layout down closes them
    -- (see `teardown`). Nothing to do per-instance.
    destroy_instance = function() end,

    -- Apply the committed fiber tree to the screen: (re)build the Box tree and
    -- mount or relayout the Layout, then write leaf contents.
    commit = function(root_fiber)
      last_root = root_fiber
      local box = build_box(root_fiber, true)
      if not box then
        return
      end
      local signature = layout_signature(root_fiber)
      if not layout then
        layout = Layout(layout_config, box)
        layout:mount()
        last_signature = signature
      elseif signature ~= last_signature then
        -- Geometry changed (added/removed/resized region): relayout. Content-only
        -- commits fall through and just rewrite buffers below — no float reflow.
        layout:update(box)
        last_signature = signature
      end
      write_contents(root_fiber)
      populate_refs(root_fiber)
      sync_inputs(root_fiber, inputs)
      apply_scoped_keymaps(root_fiber)
    end,

    -- Re-apply the current layout without a reactive re-render. Used by the
    -- window-host geometry sync engine (design.md §3B): when the host pane is
    -- resized, `nvim_win_set_config` must be re-issued so the `relative="win"`
    -- overlays realign to the pane's new size.
    relayout = function()
      if layout then
        layout:update()
      end
    end,

    -- Invoke `fn(bufnr)` for every live overlay leaf buffer in the committed
    -- tree. A mount target uses this to install buffer-local behaviour (e.g. the
    -- window-host's <C-w> traversal shims, design.md §3B) on each overlay.
    ---@param fn fun(bufnr: integer)
    each_overlay_buffer = function(fn)
      if not last_root then
        return
      end
      for_each_leaf(last_root, function(leaf)
        local bufnr = leaf.instance and leaf.instance.nui and leaf.instance.nui.bufnr
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          fn(bufnr)
        end
      end)
    end,

    -- Direct editor focus into the core interactive widget (design.md §4
    -- `focus`): the first live text_input.
    focus = function()
      for _, inst in ipairs(inputs) do
        local winid = inst.nui and inst.nui.winid
        if winid and vim.api.nvim_win_is_valid(winid) then
          vim.api.nvim_set_current_win(winid)
          return
        end
      end
    end,

    teardown = function()
      if layout then
        layout:unmount()
        layout = nil
      end
    end,
  }
end

return M
