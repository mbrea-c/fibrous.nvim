-- One render per dispatch (design-set-batching.md): every place fibrous
-- invokes an app callback — button on_press, checkbox on_toggle, span
-- on_click, routed on_key, text_input on_change/on_submit, subwindow
-- on_focus/on_blur — runs inside runtime.batch, so a handler touching several
-- states costs ONE render + flush at handler exit instead of one per set.
-- Each test's handler performs multiple sets and asserts the app component
-- rendered exactly once more, with the final values on screen.

local mount = require("fibrous.inline.mount")
local ui = require("fibrous.inline.components")

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function move_cursor(handle, row, col)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
end

local function press(handle, key)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- The (only) subwindow float anchored to the handle's root window.
local function subwin_of(handle)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].fibrous_anchor == handle.winid then
      return win
    end
  end
end

describe("inline batched dispatch", function()
  it("a button on_press doing three sets renders the app once", function()
    local renders = 0
    local a_handle, b_handle, c_handle
    local function App(ctx)
      local a = ctx.use_state(0)
      local b = ctx.use_state(0)
      local c = ctx.use_state(0)
      a_handle, b_handle, c_handle = a, b, c
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          { comp = ui.label, props = { text = ("%d %d %d"):format(a.get(), b.get(), c.get()) } },
          {
            comp = ui.button,
            props = {
              label = "go",
              on_press = function()
                a.set(1)
                b.set(2)
                c.set(3)
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 3 })
    assert.equal(1, renders)

    move_cursor(handle, 2, 0)
    press(handle, "<CR>")

    assert.equal(2, renders, "three sets in on_press must cost one render")
    assert.same({ 1, 2, 3 }, { a_handle.get(), b_handle.get(), c_handle.get() })
    assert.equal("1 2 3", lines_of(handle.bufnr)[1]:gsub("%s+$", ""))
    handle.unmount()
  end)

  it("a checkbox on_toggle doing two sets renders the app once", function()
    local renders = 0
    local function App(ctx)
      local checked = ctx.use_state(false)
      local count = ctx.use_state(0)
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.checkbox,
            props = {
              label = "opt",
              checked = checked.get(),
              on_toggle = function(v)
                checked.set(v)
                count.set(count.get() + 1)
              end,
            },
          },
          { comp = ui.label, props = { text = "toggles: " .. count.get() } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 14, height = 3 })
    assert.equal(1, renders)

    move_cursor(handle, 1, 0)
    press(handle, "<CR>")

    assert.equal(2, renders, "two sets in on_toggle must cost one render")
    assert.equal("toggles: 1", lines_of(handle.bufnr)[2]:gsub("%s+$", ""))
    handle.unmount()
  end)

  it("an interactive span's on_click doing two sets renders the app once", function()
    local renders = 0
    local function App(ctx)
      local a = ctx.use_state("a")
      local b = ctx.use_state("b")
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.paragraph,
            props = {
              text = {
                "go ",
                {
                  "link",
                  on_click = function()
                    a.set("A")
                    b.set("B")
                  end,
                },
              },
            },
          },
          { comp = ui.label, props = { text = a.get() .. b.get() } },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 10, height = 3 })

    move_cursor(handle, 1, 4) -- on "link"
    press(handle, "<CR>")

    assert.equal(2, renders, "two sets in on_click must cost one render")
    assert.equal("AB", lines_of(handle.bufnr)[2]:gsub("%s+$", ""))
    handle.unmount()
  end)

  it("a routed on_key handler doing two sets renders the app once", function()
    local renders = 0
    local function App(ctx)
      local x = ctx.use_state(0)
      local y = ctx.use_state(0)
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.label,
            props = {
              text = ("%d,%d"):format(x.get(), y.get()),
              on_key = {
                K = function()
                  x.set(5)
                  y.set(6)
                end,
              },
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 8, height = 2, keys = { "K" } })

    move_cursor(handle, 1, 0)
    press(handle, "K")

    assert.equal(2, renders, "two sets in on_key must cost one render")
    assert.equal("5,6", lines_of(handle.bufnr)[1]:gsub("%s+$", ""))
    handle.unmount()
  end)

  it("text_input on_change doing two sets renders the app once per change", function()
    local renders = 0
    local mirror
    local function App(ctx)
      local text = ctx.use_state("")
      local edits = ctx.use_state(0)
      mirror = text
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              width = 10,
              on_change = function(v)
                text.set(v)
                edits.set(edits.get() + 1)
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 2 })
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    local before = renders

    vim.api.nvim_feedkeys("iab", "xt", false)
    vim.wait(200, function()
      return mirror.get() == "ab"
    end)

    assert.equal("ab", mirror.get())
    -- The burst of keys coalesces into ONE scheduled on_change dispatch, and
    -- its two sets into ONE render.
    assert.equal(before + 1, renders, "one on_change dispatch must cost one render")
    handle.unmount()
  end)

  it("text_input on_submit doing two sets renders the app once", function()
    local renders = 0
    local submitted
    local function App(ctx)
      local last = ctx.use_state("")
      local count = ctx.use_state(0)
      submitted = last
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              width = 10,
              value = "seed",
              on_submit = function(v)
                last.set(v)
                count.set(count.get() + 1)
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 2 })
    local sub = subwin_of(handle)
    vim.api.nvim_set_current_win(sub)
    local before = renders

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)

    assert.equal("seed", submitted.get())
    assert.equal(before + 1, renders, "two sets in on_submit must cost one render")
    handle.unmount()
  end)

  it("on_focus and on_blur doing two sets each render the app once each", function()
    local renders = 0
    local log = {}
    local function App(ctx)
      local focused = ctx.use_state(false)
      local transitions = ctx.use_state(0)
      renders = renders + 1
      return {
        comp = ui.col,
        props = {},
        children = {
          {
            comp = ui.text_input,
            props = {
              width = 10,
              on_focus = function()
                focused.set(true)
                transitions.set(transitions.get() + 1)
                log[#log + 1] = "focus"
              end,
              on_blur = function()
                focused.set(false)
                transitions.set(transitions.get() + 1)
                log[#log + 1] = "blur"
              end,
            },
          },
        },
      }
    end
    local handle = mount.floating(App, {}, { width = 12, height = 2 })
    local sub = subwin_of(handle)
    local root_win = handle.winid

    local before = renders
    vim.api.nvim_set_current_win(sub)
    vim.wait(200, function()
      return #log >= 1
    end)
    assert.same({ "focus" }, log)
    assert.equal(before + 1, renders, "two sets in on_focus must cost one render")

    before = renders
    vim.api.nvim_set_current_win(root_win)
    vim.wait(200, function()
      return #log >= 2
    end)
    assert.same({ "focus", "blur" }, log)
    assert.equal(before + 1, renders, "two sets in on_blur must cost one render")
    handle.unmount()
  end)
end)
