-- Global <MouseMove> router: the MOUSE POINTER half of inline interaction.
-- One editor-wide pair of <MouseMove> mappings (normal + insert — insert is
-- what makes "hover the transcript while typing in a prompt" work) shared by
-- every interact layer: a layer registers its window, each pointer event is
-- routed to the layer owning getmousepos().winid, and layers the pointer left
-- get their mouse hover cleared. Refcounted: the mappings exist only while at
-- least one layer is registered, and a pre-existing user mapping is saved on
-- install and restored on the last unregister.
--
-- The router never touches 'mousemoveevent'. With the option enabled in the
-- user's config the events flow and hover tracks the pointer; with it off the
-- mappings simply never fire and interaction stays cursor-only, exactly as
-- before. No polling, no per-commit bookkeeping: events in, one screen-cell
-- dedupe (most motion events land in the cell of the previous one), one table
-- lookup out.

local M = {}

-- winid → { mouse_at = fun(row, col, coladd), mouse_clear = fun() }
local layers = {}
local installed = false
-- pre-existing user <MouseMove> mappings (maparg dicts), restored on uninstall
local saved = nil
-- screen-cell dedupe: the previous event's cell
local last_row, last_col = nil, nil

-- Injectable for tests: headless nvim has no real pointer to move.
M._getmousepos = vim.fn.getmousepos

-- The current pointer position (getmousepos dict). Interact layers re-read it
-- through here — not vim.fn directly — after a flush or scroll moved content
-- under a parked pointer, so the test seam covers those paths too.
function M.pos()
  return M._getmousepos()
end

function M._on_move()
  local mp = M.pos()
  if mp.screenrow == last_row and mp.screencol == last_col then
    return
  end
  last_row, last_col = mp.screenrow, mp.screencol
  local target = layers[mp.winid]
  for _, layer in pairs(layers) do
    if layer ~= target then
      layer.mouse_clear()
    end
  end
  if target then
    -- line/column are 1-based (column in BYTES); coladd is display cells past
    -- the end of the line, where only a pointer can be.
    target.mouse_at(mp.line - 1, mp.column - 1, mp.coladd or 0)
  end
end

local MODES = { "n", "i" }

local function install()
  saved = {}
  for _, mode in ipairs(MODES) do
    local prior = vim.fn.maparg("<MouseMove>", mode, false, true)
    saved[mode] = (prior and prior.lhs) and prior or false
    vim.keymap.set(mode, "<MouseMove>", M._on_move, { desc = "fibrous: mouse pointer hover" })
  end
  installed = true
end

local function uninstall()
  for _, mode in ipairs(MODES) do
    pcall(vim.keymap.del, mode, "<MouseMove>")
    if saved and saved[mode] then
      vim.fn.mapset(mode, false, saved[mode])
    end
  end
  saved = nil
  installed = false
  last_row, last_col = nil, nil
end

---@param winid integer  the window the layer draws in (root float or a container's)
---@param layer { mouse_at: fun(row: integer, col: integer, coladd: integer), mouse_clear: fun() }
function M.register(winid, layer)
  layers[winid] = layer
  if not installed then
    install()
  end
end

---@param winid integer
function M.unregister(winid)
  if not layers[winid] then
    return
  end
  layers[winid] = nil
  if installed and next(layers) == nil then
    uninstall()
  end
end

return M
