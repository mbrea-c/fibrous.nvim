-- Built-in host primitives: the leaf/container descriptors a component tree
-- bottoms out in. Each is plain data (`{ __host = <tag> }`) — pure to the
-- reactive layer, given meaning by the Nui Bridge (dom/nui_host.lua), which
-- arranges them with nui.layout's flexbox Box model.
--
-- Geometry props understood on any node (read by the bridge when building its
-- parent's Box):
--   size   number | "<n>%" | { width, height }   fixed/percentage size in parent
--   grow   integer                                flex-grow weight (default 1)
-- Outer geometry (where the whole tree sits) is supplied by the mount target.

---@type table<string, HostDescriptor>
local M = {}

-- Leaf: a buffer region. `props.lines` (string[]) is its content; `props.border`
-- an optional nui border spec. Its window/buffer are owned by the layout.
M.text = { __host = "text" }

-- Container: lays its children out horizontally (left → right).
M.row = { __host = "row" }

-- Container: stacks its children vertically (top → bottom).
M.col = { __host = "col" }

-- Leaf: a focusable, editable input. Uncontrolled (design.md §5.3): the buffer
-- is the source of truth while typing, the bridge sets `props.value` only on
-- mount, and edits are reported through `props.on_change(text)`. Keystrokes are
-- handled natively by Neovim, so typing stays latency-free.
M.text_input = { __host = "text_input" }

return M
