-- Inline component primitives (tracker "NEW UI HOST" task 5). Everything
-- visible is a thin function component over the ONE `text` host leaf — the
-- reconciler and host know nothing new, and each component is just a props
-- mapping (unmodifiable inline content by construction; the host buffer is).
--
-- Styling lives in `props.style`, in the ONE node-level vocabulary:
-- `text_hl` = foreground, `hl` = background fill of the whole rect, plus
-- border/padding/margin and the `_hover`/`_focus` state overrides ("Style
-- rework"). Layout props (width, height, grow, align, justify, gap,
-- align_self) pass through untouched. The pre-style-table aliases (`hl` as
-- foreground, `bg`, `hover_hl`) are GONE — style.normalize errors on them.
--
-- Interactive components forward their handlers plus a `role` marker onto the
-- node props; the cursor-interaction hit-map (task 6) walks the laid-out tree
-- and reads exactly those.

local theme = require("fibrous.inline.theme")

local M = {}

-- Host primitives, re-exported so apps only import this module.
M.col = { __host = "col" }
M.row = { __host = "row" }
M.text = { __host = "text" }
M.text_input = { __host = "text_input" }
M.raw_buffer = { __host = "raw_buffer" }
-- A container boundary: a subwindow leaf whose CHILDREN render into the
-- container's own buffer (a host flush target), shown in an always-on float
-- over the boundary box — one fiber tree, N buffers. Children lay out as a
-- col (gap/align/justify apply); `height`/`grow` make it a viewport over the
-- content (props.mode = "scroll" (default) lets the buffer grow and the float
-- scroll natively; "fixed" lays the content out at exactly the viewport
-- height); without either it auto-sizes to its content.
M.container = { __host = "container" }
-- A zero-footprint overlay boundary: like container, children flush into the
-- popup's own buffer shown in a float — but the leaf occupies NO cells in the
-- parent layout. Its rect is an anchor point (directly below the preceding
-- sibling, same left edge) the float is placed at; the float escapes the
-- mount's box (it clips against the editor, not the root viewport), sits in a
-- reserved zindex band above any nesting depth, and is never focusable: a
-- popup is a display surface, driven through state by the widget that keeps
-- the focus. Style props travel to the popup's INNER tree, so borders and
-- backgrounds paint inside the float (nothing can paint inline in a zero
-- box). `flip_offset` (default 1) is how many rows the float clears above the
-- anchor when there is no room below (the anchoring widget's own height).
M.popup = { __host = "popup" }

-- Copy `props` and overlay the node-level keys (text, role, theme, …).
-- Styling passes through untouched as props.style.
---@param props table
---@param over table
---@return table
local function node_props(props, over)
  return vim.tbl_extend("force", {}, props, over)
end

-- `text` may be a rich-text span list ("Style rework" S4): bare strings or
-- { "chunk", hl = ... } tables, e.g. { "plain ", { "loud", hl = "Title" } }.

---@param _ table ctx (unused)
---@param props { text: string|Span[], hl?: string, bg?: string }
function M.label(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = false }) }
end

---@param _ table ctx (unused)
---@param props { text: string|Span[], hl?: string, bg?: string }
function M.paragraph(_, props)
  return { comp = M.text, props = node_props(props, { text = props.text, wrap = true }) }
end

-- Time-driven text. `value(progress)` maps progress in [0, 1) — elapsed time
-- modulo `duration`, i.e. an implicit loop — onto the text/spans to show
-- (bounce = a triangle wave inside value). A uv timer ticks at `fps` and the
-- frame commits ONLY when the rendered value changed, so buffer writes scale
-- with visible motion, not the frame rate — and each commit re-renders just
-- this leaf, the memoized fast path. Frame 0 renders synchronously at mount.
-- `play = false` freezes at the current frame; changing duration/fps/play
-- re-arms the timer (progress restarts at 0). The latest `value` closure is
-- kept in a ref, so defining it inline never re-arms anything.
---@param ctx table
---@param props { duration: number, value: fun(progress: number): string|Span[], fps?: number, play?: boolean, style?: table, theme?: string|false }
function M.animation(ctx, props)
  if type(props.duration) ~= "number" or props.duration <= 0 then
    error("fibrous: animation needs a positive `duration` (seconds)")
  end
  if type(props.value) ~= "function" then
    error("fibrous: animation needs a `value(progress)` function")
  end
  local frame = ctx.use_state(nil)
  local vf = ctx.use_ref()
  vf.current = props.value

  ctx.use_effect(function()
    if props.play == false then
      return
    end
    local duration = props.duration
    local interval = math.max(math.floor(1000 / (props.fps or 30)), 1)
    local start = vim.uv.now()
    local timer = vim.uv.new_timer()
    local stopped = false
    timer:start(
      interval,
      interval,
      vim.schedule_wrap(function()
        -- a fire can be in flight when the cleanup runs: never touch the
        -- closed timer or set state on the unmounted fiber
        if stopped then
          return
        end
        local progress = ((vim.uv.now() - start) / 1000 % duration) / duration
        local ok, next_frame = pcall(vf.current, progress)
        if not ok then
          stopped = true
          timer:stop()
          vim.notify("fibrous: animation value() failed: " .. tostring(next_frame), vim.log.levels.ERROR)
          return
        end
        if not vim.deep_equal(next_frame, frame.get()) then
          frame.set(next_frame)
        end
      end)
    )
    return function()
      stopped = true
      timer:stop()
      timer:close()
    end
  end, { props.duration, props.fps or 30, props.play ~= false })

  local current = frame.get()
  if current == nil then
    current = props.value(0)
  end
  return { comp = M.text, props = node_props(props, { text = current, wrap = false }) }
end

-- Interactive components tag themselves with their theme.styles key (S5) —
-- the host seeds those defaults below the instance's own props; pass
-- `theme = false` to opt out, or another key to restyle.

---@param props table
---@param key string
---@return string|false
local function theme_key(props, key)
  return props.theme == nil and key or props.theme
end

-- The button chip's brackets come from its theme.styles border (a transparent
-- left/right border), NOT from the text — restyle them per instance with a
-- border prop, or drop them with `theme = false` for a bare label.
---@param _ table ctx (unused)
---@param props { label: string, on_press?: fun(), hl?: string, bg?: string, theme?: string|false }
function M.button(_, props)
  return {
    comp = M.text,
    props = node_props(props, {
      text = props.label or "",
      role = "button",
      theme = theme_key(props, "button"),
      -- Shrink-wrap by default so hover/activation hug the visible widget;
      -- pass align_self = "stretch" (or a width) for a full-width button.
      align_self = props.align_self or "start",
    }),
  }
end

---@param _ table ctx (unused)
---@param props { label: string, checked?: boolean, on_toggle?: fun(checked: boolean), marks?: { checked?: string|Span, unchecked?: string|Span }, hl?: string, bg?: string, theme?: string|false }
function M.checkbox(_, props)
  -- Marks are content, so they default from theme.marks (not theme.styles)
  -- and override key-wise via the `marks` prop — bare strings or spans.
  local defaults = theme.marks.checkbox
  local marks = props.marks or {}
  local mark = props.checked and (marks.checked or defaults.checked)
    or (marks.unchecked or defaults.unchecked)
  return {
    comp = M.text,
    props = node_props(props, {
      text = { mark, " " .. (props.label or "") },
      role = "checkbox",
      theme = theme_key(props, "checkbox"),
      align_self = props.align_self or "start",
    }),
  }
end

-- A select field: a singleline text_input plus a ui.popup listing the
-- filtered options. Focus opens the popup (any mode) showing every option
-- with the selection on the current value; typing filters (fuzzy by default,
-- the `filter` prop overrides) and resets the selection to the best match;
-- <C-n>/<C-p> move it (wrapping), <CR>/<C-y> commit it into the field, <C-e>
-- closes the popup keeping the typed text uncommitted. Unfocus commits the
-- selection; free-standing typed text survives only with `free_text = true`
-- (default is strict select: no match on blur reverts the field to the last
-- committed value). on_select fires on every committed CHANGE (reverts and
-- re-commits of the same value stay silent); on_change mirrors the raw typed
-- text. The popup windows itself to `max_height` rows (default 8) around the
-- selection, so it never needs internal scroll.
---@param ctx table
---@param props { options: string[], value?: string, width?: integer, max_height?: integer, free_text?: boolean, filter?: fun(options: string[], text: string): string[], on_select?: fun(value: string), on_change?: fun(text: string), flip_offset?: integer, style?: table }
function M.dropdown(ctx, props)
  local dd = require("fibrous.inline.dropdown")
  local width = require("fibrous.inline.width")

  local open = ctx.use_state(false)
  local sel = ctx.use_state(1)
  local text = ctx.use_state(props.value or "")
  -- Non-rendering state, plus the latest props for the buffer-map closures
  -- (maps are wired once at input creation; handles and this ref are stable
  -- across renders, so nothing below closes over stale values).
  local r = ctx.use_ref({ committed = props.value or "", pristine = true }).current
  r.props = props

  -- `pristine` = no edit since focus: the popup shows ALL options then (the
  -- request's "focused shows available options"), with the selection resting
  -- on the current value; the first real edit switches to filtering.
  local function current_filter()
    local p = r.props
    local t = r.pristine and "" or text.get()
    return (p.filter or dd.filter)(p.options or {}, t)
  end

  local function sync_buf(value)
    if not (r.bufnr and vim.api.nvim_buf_is_valid(r.bufnr)) then
      return
    end
    local cur = table.concat(vim.api.nvim_buf_get_lines(r.bufnr, 0, -1, false), " ")
    if cur ~= value then
      r.suppress = true -- the write below must not reopen the popup
      vim.api.nvim_buf_set_lines(r.bufnr, 0, -1, false, { value })
      if vim.api.nvim_get_current_buf() == r.bufnr then
        pcall(vim.api.nvim_win_set_cursor, 0, { 1, #value })
      end
    end
  end

  local function commit(value)
    r.pristine = true -- before any .set: state sets re-render synchronously
    open.set(false)
    sync_buf(value)
    text.set(value)
    if value ~= r.committed then
      r.committed = value
      if r.props.on_select then
        r.props.on_select(value)
      end
    end
  end

  local function choose()
    local fil = current_filter()
    local i = math.min(math.max(sel.get(), 1), #fil)
    if open.get() and fil[i] then
      commit(fil[i])
    else
      open.set(false)
    end
  end

  local function move(d)
    local fil = current_filter()
    if #fil == 0 then
      return
    end
    if not open.get() then
      open.set(true)
      sel.set(d > 0 and 1 or #fil)
      return
    end
    local i = math.min(math.max(sel.get(), 1), #fil) + d
    if i < 1 then
      i = #fil
    elseif i > #fil then
      i = 1
    end
    sel.set(i)
  end

  local field_w = props.width or 20
  local max_h = props.max_height or 8
  -- Popup width: max(field, widest option) over ALL options, so it doesn't
  -- jump around as the filter narrows.
  local W = field_w
  for _, o in ipairs(props.options or {}) do
    W = math.max(W, width.str(o))
  end

  local fil = current_filter()
  local i = math.min(math.max(sel.get(), 1), #fil)

  local rows = {}
  if #fil == 0 then
    rows[1] = {
      comp = M.label,
      props = { text = "(no match)", width = W, style = { hl = "FibrousPopup", text_hl = "FibrousDim" } },
    }
  else
    local lo = dd.window(#fil, i, max_h)
    for k = lo, math.min(lo + max_h - 1, #fil) do
      rows[#rows + 1] = {
        comp = M.label,
        props = { text = fil[k], width = W, style = { hl = k == i and "FibrousPopupSel" or "FibrousPopup" } },
      }
    end
  end

  local children = {
    {
      comp = M.text_input,
      props = {
        value = props.value or "",
        singleline = true,
        width = field_w,
        height = 1,
        style = props.style,
        on_create = function(bufnr)
          r.bufnr = bufnr
          for _, m in ipairs({ "i", "n" }) do
            vim.keymap.set(m, "<C-n>", function()
              move(1)
            end, { buffer = bufnr, nowait = true, desc = "fibrous: dropdown next option" })
            vim.keymap.set(m, "<C-p>", function()
              move(-1)
            end, { buffer = bufnr, nowait = true, desc = "fibrous: dropdown previous option" })
            vim.keymap.set(m, "<C-y>", choose, { buffer = bufnr, nowait = true, desc = "fibrous: dropdown accept option" })
            vim.keymap.set(m, "<C-e>", function()
              open.set(false)
            end, { buffer = bufnr, nowait = true, desc = "fibrous: dropdown close popup" })
          end
        end,
        on_change = function(v)
          -- Refs first: state .set re-renders SYNCHRONOUSLY, so the render
          -- must already see the pristine flag flipped (a later no-op .set
          -- would not re-render again).
          local suppressed = r.suppress
          r.suppress = false
          if not suppressed then
            r.pristine = false
            open.set(true)
            sel.set(1)
          end
          text.set(v)
          if r.props.on_change then
            r.props.on_change(v)
          end
        end,
        on_submit = choose,
        on_focus = function()
          r.pristine = true
          open.set(true)
          sel.set(dd.index_of(r.props.options or {}, r.committed) or 1)
        end,
        on_blur = function(v)
          local p = r.props
          local chosen
          if open.get() then
            local bfil = current_filter()
            local bi = math.min(math.max(sel.get(), 1), #bfil)
            chosen = bfil[bi]
          end
          local value = dd.blur_value(v, chosen, p.free_text, p.options)
          if value ~= nil then
            commit(value)
          else
            r.pristine = true
            open.set(false)
            sync_buf(r.committed)
            text.set(r.committed)
          end
        end,
      },
    },
  }
  if open.get() then
    children[#children + 1] = {
      comp = M.popup,
      props = { flip_offset = props.flip_offset, min_width = W },
      children = rows,
    }
  end
  return { comp = M.col, props = {}, children = children }
end

-- The `image` host leaf: internal — apps go through M.image below, which owns
-- provider/spec resolution and the terminal-protocol lifecycle.
local image_leaf = { __host = "image" }

-- Inline image (kitty Unicode placeholders; see fibrous.image). Content is
-- `b64` (base64 PNG, ipynb-style whitespace tolerated) or `data` (raw PNG
-- bytes). Sizing: explicit `cols`/`rows` win (one given, the other derives
-- from the aspect ratio); otherwise natural size = pixel dims / cell size,
-- scaled down aspect-preserving to fit `max_cols`/`max_rows`. When the
-- provider resolves to "text" (unsupported terminal) or the content cannot be
-- decoded, renders `alt` styled as a comment instead — nothing regresses on
-- terminals without image support.
--
-- Lifecycle (the animation pattern): the spec is resolved at render, memoized
-- on content + sizing props; use_effect keyed on the image id retains on
-- mount / releases on unmount, so the same content shown N times transmits
-- once and deletes after the last unmount.
---@param ctx table
---@param props { b64?: string, data?: string, cols?: integer, rows?: integer, max_cols?: integer, max_rows?: integer, alt?: string }
function M.image(ctx, props)
  local image = require("fibrous.image")
  -- Wake on provider changes (capability-probe corrections, image.refresh()):
  -- the state set forces a re-render, the epoch in the memo key forces the
  -- spec to re-resolve under the new provider.
  local epoch = ctx.use_state(image.epoch())
  ctx.use_effect(function()
    return image.on_change(function()
      epoch.set(image.epoch())
    end)
  end, {})
  local memo = ctx.use_ref()
  local m = memo.current
  local same = m
    and m.content == (props.b64 or props.data)
    and m.cols == props.cols
    and m.rows == props.rows
    and m.max_cols == props.max_cols
    and m.max_rows == props.max_rows
    and m.epoch == image.epoch()
  if not same then
    local spec, err = image.spec(props)
    m = {
      content = props.b64 or props.data,
      cols = props.cols,
      rows = props.rows,
      max_cols = props.max_cols,
      max_rows = props.max_rows,
      epoch = image.epoch(),
      spec = spec,
      err = err,
    }
    memo.current = m
  end
  local spec = m.spec

  ctx.use_effect(function()
    if not spec then
      return
    end
    image.retain(spec)
    return function()
      image.release(spec)
    end
  end, { spec and spec.id or false })

  if not spec then
    return {
      comp = M.text,
      props = node_props(props, {
        text = props.alt or "<image>",
        wrap = false,
        style = props.style or { text_hl = "Comment" },
      }),
    }
  end
  return {
    comp = image_leaf,
    props = node_props(props, {
      image = { id = spec.id, hl = spec.hl, cols = spec.cols, rows = spec.rows },
    }),
  }
end

-- The markdown widget: renders markdown source as rich, interactive blocks. A
-- stateful builtin whose body lives in fibrous.markdown.component (next to the
-- parser); this is a lazy forwarder so importing this module never pulls the
-- parser/renderer onto the graph for apps that do not use it.
---@param ctx table
---@param props { text: string, live?: boolean, on_link?: fun(url: string), highlight?: fun(text: string, lang: string|nil): table, theme?: string|false }
function M.markdown(ctx, props)
  return require("fibrous.markdown.component")(ctx, props)
end

return M
