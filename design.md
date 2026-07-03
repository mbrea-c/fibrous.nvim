# fibrous: A React-like UI Framework for Neovim

> **Status (2026-07-03):** this is the ORIGINAL design document. The reactive
> layer (§1, §2: fibers, hooks, reconciliation) is accurate and shipped as
> described. The host layer it describes (nui.nvim popups, one window per
> leaf) has since been **replaced by the inline host** — component trees now
> render as text + extmarks into one unmodifiable buffer with a CSS-like box
> model, cursor-driven interaction, and editable floats only for text inputs /
> raw buffers (`lua/fibrous/inline/`). The vendored nui and the nui host are
> deleted. See the "NEW UI HOST" section of `open_tasks_and_issues.md` for the
> inline host's design decisions until this document is rewritten.

A declarative, component-based, component-scoped UI framework. It brings the
mental model of React (VDOM, Hooks, Subtree Reconciliation, Top-Down Data
Flow) to Neovim plugin development, abstracting away manual buffer
manipulation, layout calculations, and window lifecycles.

______________________________________________________________________

## 1. Core Architecture

The framework is strictly divided into two independent execution layers: the
**Reactive Layer** and the **Layout/DOM Layer**.

```
[ External / Internal State Mutator ]
                 │
                 ▼
   ┌─────────────────────────────────┐
   │ 1. REACTIVE LAYER (Pure Lua)    │
   │    - Manages Hooks & Fiber Context
   │    - Computes VDOM Subtree Diff  │
   └─────────────────────────────────┘
                 │
                 │ Generates Minimal Patch
                 ▼
   ┌─────────────────────────────────┐
   │ 2. LAYOUT/DOM LAYER (Nui Bridge)│
   │    - Geometry Re-calculations   │
   │    - Physical Window Mutations  │
   └─────────────────────────────────┘
                 │
                 ▼
          [ Neovim Screen ]

```

### A. The Reactive Layer (The Brain)

- **Fiber Execution Context:** Keeps track of the currently executing component
  using an internal pointer (`CURRENT_FIBER`). This ensures hooks map to the
  exact persistent data slot across render cycles.

- **Component-Scoped Subtree Reconciliation:** When a state setter fires, the
  framework re-runs *only* the component function that owns that state. It
  computes a localized Virtual DOM (VDOM) diff, avoiding full-tree traversal.

- **Pure Logic Isolation:** This layer has no awareness of Neovim buffers,
  layout lines, or windows. It works exclusively with plain Lua tables, making
  it completely unit-testable outside of Neovim.

### B. The Layout / DOM Layer (The Muscle)

- **Nui Bridge:** Converts VDOM node specifications into active instances of
  `nui.popup` or native layout elements.

- **Geometry Reflow:** Translates declarative props (e.g., width, direction)
  into concrete row/column configurations. When a leaf component changes
  dimensions, layout reflow boundaries bubble up or are strictly enforced by the
  container.

______________________________________________________________________

## 2. API Specification

### Component Blueprint Example

Components are standard Lua functions that accept a framework context (`ctx`)
and a configuration table (`props`). They return a virtual node definition
separating configuration properties from structural layout children.

```lua
local checkbox = require("fibrous.components.checkbox")
local layout = require("fibrous.layout")

-- This is a component
local function hello_world(ctx, props)
  -- 1. State Management
  local checkbox_state = ctx.use_state(false)
  
  -- 2. Lifecycle Effects
  ctx.use_effect(function()
    -- Executed on component mount
    print("Component mounted with title: " .. props.title)
    
    return function()
      -- Cleanup callback executed on unmount
      print("Component unmounted")
    end
  end, { props.title }) -- Dependency array

  -- 3. Declarative Virtual Node Specification
  return {
    comp = layout.row,
    props = {
      size = "100%",
      margin = 1,
    },
    children = {
      {
        comp = checkbox,
        props = {
          label = "Enable feature",
          checked = checkbox_state.get(),
          on_toggle = function(is_checked)
            checkbox_state.set(is_checked)
          end
        }
      }
    }
  }
end

```

### Core Hooks Interface

- `ctx.use_state(initial_value)`: Returns a table with `.get()` and
  `.set(new_value)` closures. Invoking `.set()` flags the containing component
  for immediate evaluation and diffing.

- `ctx.use_effect(callback, dependencies)`: Runs the callback on mount and
  whenever items inside the dependency array change value. Supports an optional
  returned cleanup function.

- `ctx.use_host_window()`: Available within Native Split Mode. Returns active
  layout data (width, height) bound to the parent host pane.

______________________________________________________________________

## 3. Mounting Paradigms & Window Orchestration

To support both modal dialogs and seamless integration into custom sidebar panes
without visual layout breakages, the framework implements specialized mounting
targets.

### A. Standalone Floating Targets

The simplest mode where the root VNode is instantiated as an independent
`nui.popup`, anchored globally or relative to the current cursor position.

### B. Native Split Window Anchoring ("Native Split Mode")

To embed UI structures directly inside standard Neovim layouts (`:vsplit`,
`:split`) while bypassing the geometric constraints of native layout buffers,
the framework layers Nui widgets as floating window overlays anchored
specifically to a **host window pane**.

```
    [ Native Split Window Pane ] (Host Window Context)
                 │
                 ├──► [ Floating Widget A ] (relative = "win")
                 └──► [ Floating Widget B ] (relative = "win")

```

To maintain the perfect illusion of a unified native window interface, the
**Layout Layer** acts as an absolute window and coordinate manager via the
following core mechanisms:

1. **Relative Window Constraints:** When generating Nui components for this
   target, the framework forces them to render with `relative = "win"` and binds
   them directly to the `winid` of the host split window pane.

1. **The Geometry Sync Engine (`WinResized`):** Because Neovim does not
   automatically reposition relative floating windows if their parent window is
   manually resized (e.g., via `<C-w>>`), the framework registers an
   engine-level autocommand for `WinResized` and `VimResized`. When a mutation
   is caught, it shifts layout matrices and applies updates via
   `nvim_win_set_config` to instantly realign all floats.

1. **Window Traversal Interception (`<C-w>` Shims):** To prevent focus loops
   from stranding users inside hidden internal structural floats, the framework
   injects buffer-local keymaps on all active text nodes catching structural
   window switches (`<C-w>h`, `<C-w>j`, `<C-w>k`, `<C-w>l`, `<C-w>w`). When
   triggered, focus is programmatically shifted back to the host window
   container before issuing the final native movement command out of the
   application layout.

1. **Lifecycle Hooks (`WinClosed`):** If a user explicitly executes a `:q` or
   `<C-w>q` while focused on the host window pane, the framework intercepts the
   `WinClosed` event for that explicit `winid` and triggers an active
   top-to-bottom `unmount` sequence to clean up all orphaned floating layers
   immediately.

______________________________________________________________________

## 4. Mounting Execution & Imperative Handle Control

To mount an application over a native split pane, the entry-point lifecycle
method abstracts window initialization and returns a controller handle allowing
external event loops to feed top-down state changes into the root fiber.

### Mounting Execution Signature

```lua
local framework = require("fibrous")
local My_Sidebar_App = require("my-plugin.ui.sidebar")

local app_handle = framework.mount_as_window_host(My_Sidebar_App, {
  title = "Project Explorer"
}, {
  split = {
    direction = "vertical",
    position = "left",
    size = 40,
  },
  behavior = {
    intercept_wincmd = true,
    auto_unmount = true,
  }
})

```

### Imperative Handle Interface

The returned `app_handle` acts as an external authority block over the reactive
application:

- `app_handle.set_props(new_props)`: Updates the top-level configuration values
  passed to the root component. This acts as an external state injector, forcing
  a top-down reconciliation pass. Useful for syncing the UI with native editor
  updates (e.g., `DiagnosticChanged` or Git status transitions).

- `app_handle.focus()`: Directs active editor focus explicitly into the core
  interactive widget of the application tree.

- `app_handle.unmount()`: Forcibly dismantles the Virtual DOM tree, purges
  active state hooks registers, and wipes overlay windows from memory.

______________________________________________________________________

## 5. Technical & Architectural Requirements

### VNode Tree Definition

Each component initialization evaluates to a structured Virtual Node (VNode)
tracking metadata and state bindings:

```lua
local vnode = {
  type = component_function,      -- Pointer to the functional definition
  props = { ... },                -- Configuration attributes passed by parent
  children = { ... },             -- Array of nested child VNodes
  _nui_instance = nil,            -- Instance pointer to the mapped Nui object
  _hooks_registry = {},           -- Sequential array tracking use_state and use_effect
}

```

### Operational Constraints & Mitigation

1. **Lua Resource Management:** To avoid heavy garbage collection pauses
   generated by recreating nested tables, the reconciliation engine must reuse
   existing `_hooks_registry` and VNode shells whenever the component `type`
   matches during a diff.

1. **Layout Boundaries:** Since Neovim lacks a native layout engine like CSS,
   layout containers (`layout.row`, `layout.col`) must serve as strict geometry
   boundaries. If a component changes size dynamically, it must bubble layout
   update events up to its parent Nui container to compute cell reflows.

1. **Typing Bypass:** Interactive inputs (`n.text_input` equivalents) must
   capture updates via buffer events (`TextChanged` / `TextChangedI`). Text
   synchronization happens asynchronously into the state manager, ensuring
   individual keystrokes are processed natively by Neovim's C core for
   latency-free typing.

## 6. UI dependency

`nui` can be used as the "base" UI layer; we will vendor the library in our
plugin in case we need to add any patches (hard-fork, deleting the .git
diretory).

## 7. Final notes

With the exception of the API, the contents of this doc are open to discussion
if you have any better ideas.
