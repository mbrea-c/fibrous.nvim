-- Native Split Window Anchoring (design.md §3B): embeds the reactive tree inside
-- a standard Neovim split (`:vsplit`/`:split`) by overlaying it as floating nui
-- widgets anchored `relative="win"` to a dedicated *host pane*. The split itself
-- holds an empty scratch buffer and only provides geometry; everything the user
-- sees is the overlay, giving the illusion of a unified native window.
--
-- The Layout Layer here acts as an absolute window/coordinate manager via three
-- engine-level mechanisms, all keyed off the host pane's winid:
--   * Geometry Sync   — WinResized/VimResized → host:relayout() (nvim_win_set_config)
--   * Lifecycle       — WinClosed on the host pane → deferred unmount (auto_unmount)
--   * Traversal Shims — buffer-local <C-w>{h,j,k,l,w} on overlays redirect focus
--                       through the host pane before leaving the app (intercept_wincmd)
--
-- The bulk of the rendering is identical to the floating target — the only
-- difference is the layout is anchored to a window rather than the editor, so we
-- reuse the same nui_host bridge with a window-relative layout_config.

local runtime = require("nui-reactive.reactive.runtime")
local nui_host = require("nui-reactive.dom.nui_host")

local M = {}

---@class SplitOpts
---@field direction? "vertical"|"horizontal"   split orientation; default "vertical"
---@field position? "left"|"right"|"top"|"bottom"   which edge to open at; default "left"
---@field size? integer   columns (vertical) or rows (horizontal) for the host pane; default 40

---@class WindowHostBehavior
---@field intercept_wincmd? boolean   shim <C-w> motions so focus never strands in an overlay; default true
---@field auto_unmount? boolean       unmount when the user closes the host pane; default true

---@class WindowHostOpts
---@field split? SplitOpts
---@field behavior? WindowHostBehavior

---@class WindowAppHandle : AppHandle
---@field host_winid integer   the native split pane the app is anchored to

local WINCMD_MOTIONS = { "h", "j", "k", "l", "w" }

-- Open a native split pane and return its winid. The pane is given a throwaway
-- scratch buffer; the overlay does the real drawing.
---@param split SplitOpts
---@return integer host_winid
local function open_host_pane(split)
  local direction = split.direction or "vertical"
  local position = split.position or (direction == "vertical" and "left" or "top")
  local vertical = direction == "vertical"
  -- topleft/botright place the new split at the far edge, spanning the full
  -- height (vertical) or width (horizontal) — a true sidebar/panel.
  local anchor = (position == "left" or position == "top") and "topleft" or "botright"
  vim.cmd(anchor .. " " .. (vertical and "vsplit" or "split"))

  local host_winid = vim.api.nvim_get_current_win()
  local host_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[host_bufnr].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(host_winid, host_bufnr)

  local size = split.size or 40
  if vertical then
    vim.api.nvim_win_set_width(host_winid, size)
  else
    vim.api.nvim_win_set_height(host_winid, size)
  end
  return host_winid
end

-- Mount `component` as an application anchored over a native split pane.
---@param component Component
---@param props? table
---@param opts? WindowHostOpts
---@return WindowAppHandle
function M.mount(component, props, opts)
  opts = opts or {}
  local split = opts.split or {}
  local behavior = opts.behavior or {}
  local intercept_wincmd = behavior.intercept_wincmd ~= false
  local auto_unmount = behavior.auto_unmount ~= false

  local origin_winid = vim.api.nvim_get_current_win()
  local host_winid = open_host_pane(split)

  -- Anchor the whole overlay tree to the host pane, filling it edge to edge.
  local layout_config = {
    relative = { type = "win", winid = host_winid },
    position = { row = 0, col = 0 },
    size = { width = "100%", height = "100%" },
  }

  local host = nui_host.new(layout_config)
  local root = runtime.create_root(component, props, { host = host })
  root:render()

  -- Engine-level autocmds live in one group so teardown is a single clear.
  local group = vim.api.nvim_create_augroup("NuiReactiveWindowHost_" .. host_winid, { clear = true })

  local unmounted = false
  local function teardown()
    if unmounted then
      return
    end
    unmounted = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    root:unmount()
    -- Drop the now-empty host pane too, unless the user already closed it.
    if vim.api.nvim_win_is_valid(host_winid) then
      pcall(vim.api.nvim_win_close, host_winid, true)
    end
  end

  -- Geometry Sync Engine: realign overlays whenever window dimensions change.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if not unmounted and vim.api.nvim_win_is_valid(host_winid) and host.relayout then
        host.relayout()
      end
    end,
  })

  -- Lifecycle: a user `:q`/`<C-w>q` on the host pane unmounts the whole app.
  -- Windows cannot be closed from inside WinClosed, so defer the teardown.
  if auto_unmount then
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(host_winid),
      callback = function()
        vim.schedule(teardown)
      end,
    })
  end

  -- Traversal Shims: catch structural window motions on every overlay buffer so
  -- focus is routed back through the host pane before leaving the app layout,
  -- never stranding the user inside a hidden internal float.
  if intercept_wincmd then
    host.each_overlay_buffer(function(bufnr)
      for _, motion in ipairs(WINCMD_MOTIONS) do
        vim.keymap.set("n", "<C-w>" .. motion, function()
          if vim.api.nvim_win_is_valid(host_winid) then
            vim.api.nvim_set_current_win(host_winid)
          end
          vim.cmd("wincmd " .. motion)
        end, { buffer = bufnr, nowait = true, desc = "nui-reactive: leave app pane" })
      end
    end)
  end

  ---@type WindowAppHandle
  return {
    host_winid = host_winid,
    set_props = function(new_props)
      root:set_props(new_props)
    end,
    focus = function()
      if vim.api.nvim_win_is_valid(host_winid) then
        vim.api.nvim_set_current_win(host_winid)
      end
      if host.focus then
        host.focus()
      end
    end,
    unmount = function()
      teardown()
      if vim.api.nvim_win_is_valid(origin_winid) then
        pcall(vim.api.nvim_set_current_win, origin_winid)
      end
    end,
  }
end

return M
