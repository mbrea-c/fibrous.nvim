-- text_input change/submit wiring (tracker "NEW UI HOST" task 7). The float's
-- buffer is the source of truth while typing; edits report back through
-- props.on_change(value) — asynchronously: buffer changes are watched with
-- nvim_buf_attach (whose callback runs under textlock), so the handler fires
-- on the next main-loop tick, coalesced per edit burst. <CR> — normal or
-- insert mode — calls props.on_submit(value) synchronously when the component
-- provides one; without on_submit, insert-mode <CR> falls through to a plain
-- newline so multi-line inputs still work. Handlers are read from the latest
-- committed props at fire time, and a re-render triggered from on_change must
-- not clobber the focused input's buffer or cursor.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function subwin_of(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid then
      return win
    end
  end
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

describe("inline.input", function()
  it("typing fires on_change with the buffer content", function()
    local got
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              value = "",
              height = 1,
              on_change = function(v)
                got = v
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 1 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("ihello")
    vim.wait(200, function()
      return got ~= nil
    end)
    assert.equal("hello", got)

    handle.unmount()
  end)

  it("<CR> submits in NORMAL mode only; in insert it is a plain newline", function()
    local submitted = {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              value = "abc",
              height = 2,
              on_submit = function(v)
                submitted[#submitted + 1] = v
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(sub)
    press("<CR>") -- normal mode → submit
    assert.same({ "abc" }, submitted)

    -- in INSERT mode <CR> is a newline (multi-line compose), NOT a submit
    press("A!<CR>more")
    assert.same({ "abc" }, submitted) -- no extra submit from insert <CR>
    assert.same({ "abc!", "more" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    handle.unmount()
  end)

  it("insert-mode <CR> without on_submit inserts a plain newline", function()
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.text_input, props = { value = "ab", height = 2 } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("A<CR>cd")
    assert.same({ "ab", "cd" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))

    handle.unmount()
  end)

  it("clear_on_submit empties the buffer after on_submit fires", function()
    local submitted = {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              value = "abc",
              height = 1,
              clear_on_submit = true,
              on_submit = function(v)
                submitted[#submitted + 1] = v
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 1 })
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    press("<CR>")
    -- on_submit saw the pre-clear value; the buffer is empty afterwards.
    assert.same({ "abc" }, submitted)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))

    -- The cleared input keeps working: type fresh text, submit again. <CR>
    -- submits from insert mode too (wire_input maps it for {n,i}), so no <Esc>
    -- first -- and a normal-mode <Esc> now leaves the widget for the parent.
    press("inext")
    press("<CR>")
    assert.same({ "abc", "next" }, submitted)
    assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))

    handle.unmount()
  end)

  it("on_create hands the app the input's buffer once, at creation", function()
    local created = {}
    local function App()
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              value = "",
              height = 1,
              on_create = function(bufnr)
                created[#created + 1] = bufnr
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 1 })
    local sub = subwin_of(handle)

    -- Fired exactly once, with the subwin's own buffer — the hook exists so
    -- apps can wire buffer-local options/maps (completefunc, extra keymaps).
    assert.same({ vim.api.nvim_win_get_buf(sub) }, created)

    -- A prop change re-render must not re-fire it (the buffer persists).
    handle.set_props({ tick = 1 })
    assert.equal(1, #created)

    handle.unmount()
  end)

  it("a re-render triggered from on_change doesn't clobber the focused input", function()
    local function App(ctx)
      local text = ctx.use_state("")
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = "len " .. #text.get() } },
          {
            comp = ui.text_input,
            props = {
              value = "",
              height = 1,
              on_change = function(v)
                text.set(v) -- every change re-renders, flushes, resyncs
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 2 })
    local sub = subwin_of(handle)

    local function label_line()
      return vim.trim(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] or "")
    end

    vim.api.nvim_set_current_win(sub)
    press("ihello")
    vim.wait(200, function()
      return label_line() == "len 5"
    end)
    assert.equal("len 5", label_line())

    -- The resync above ran while the float was focused. It must not have
    -- reset the float's cursor: `a` appends after "o" — if the cursor got
    -- yanked to col 0, it appends after "h" and this reads "hxello".
    press("ax")
    vim.wait(200, function()
      return label_line() == "len 6"
    end)
    assert.same({ "hellox" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sub), 0, -1, false))

    handle.unmount()
  end)
end)

-- singleline = true pins the input to one line: insert-mode <CR> submits
-- (there is no newline to compose), and content that arrives multi-line
-- anyway (a paste, normal-mode o/O) is flattened back to one line, newlines
-- becoming spaces, before on_change reports it. on_focus/on_blur fire as the
-- float gains/loses the cursor — the dropdown's open-on-focus and
-- commit-on-unfocus hang off them.
describe("inline.input singleline + focus callbacks", function()
  local function input_app(props)
    return function()
      return {
        comp = ui.col,
        props = {},
        children = { { comp = ui.text_input, props = props } },
      }
    end
  end

  it("singleline: insert-mode <CR> submits instead of newlining", function()
    local submitted = {}
    local handle = mount.floating(
      input_app({
        value = "abc",
        height = 1,
        singleline = true,
        on_submit = function(v)
          submitted[#submitted + 1] = v
        end,
      }),
      {},
      { width = 10, height = 1 }
    )
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_set_current_win(sub)
    press("A!<CR>")
    assert.same({ "abc!" }, submitted)
    assert.same({ "abc!" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    handle.unmount()
  end)

  it("singleline: multi-line content flattens to one line, newlines to spaces", function()
    local got
    local handle = mount.floating(
      input_app({
        value = "abc",
        height = 1,
        singleline = true,
        on_change = function(v)
          got = v
        end,
      }),
      {},
      { width = 12, height = 1 }
    )
    local sub = subwin_of(handle)
    local buf = vim.api.nvim_win_get_buf(sub)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" }) -- a paste
    vim.wait(200, function()
      return got == "one two"
    end)
    assert.same({ "one two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equal("one two", got)

    handle.unmount()
  end)

  it("on_focus and on_blur fire as the float gains and loses the cursor", function()
    local events = {}
    local handle = mount.floating(
      input_app({
        value = "seed",
        height = 1,
        on_focus = function(v)
          events[#events + 1] = { "focus", v }
        end,
        on_blur = function(v)
          events[#events + 1] = { "blur", v }
        end,
      }),
      {},
      { width = 10, height = 1 }
    )
    local sub = subwin_of(handle)

    vim.api.nvim_set_current_win(sub)
    assert.same({ { "focus", "seed" } }, events)

    press("A!") -- edit while focused, so blur reports the LATEST value
    press("<Esc>")
    vim.api.nvim_set_current_win(handle.winid)
    assert.same({ { "focus", "seed" }, { "blur", "seed!" } }, events)

    handle.unmount()
  end)
end)
