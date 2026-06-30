local nr = require("nui-reactive")
local el = require("nui-reactive.components")

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- A minimal sidebar app exposing its single leaf's live handle via `ref` so the
-- test can observe the real overlay window/buffer the bridge created.
local function make_app(ref_box)
  return function(ctx)
    ref_box.ref = ref_box.ref or ctx.use_ref()
    return {
      comp = el.col,
      props = {},
      children = {
        { comp = el.text, props = { lines = { "sidebar" }, ref = ref_box.ref } },
      },
    }
  end
end

describe("mount_as_window_host", function()
  it("anchors the app over a dedicated native split pane", function()
    local wins_before = #vim.api.nvim_list_wins()
    local box = {}

    local handle = nr.mount_as_window_host(make_app(box), {}, {
      split = { direction = "vertical", position = "left", size = 30 },
    })

    -- A new host pane exists, and it is a real, valid window.
    assert.is_true(#vim.api.nvim_list_wins() > wins_before)
    assert.is_true(vim.api.nvim_win_is_valid(handle.host_winid))

    -- The app rendered into an overlay buffer anchored to that pane.
    assert.equal("sidebar", buf_text(box.ref.current.bufnr))
    assert.equal("win", vim.api.nvim_win_get_config(box.ref.current.winid).relative)

    handle.unmount()
    assert.is_false(vim.api.nvim_win_is_valid(box.ref.current.winid))
  end)

  it("geometry sync: WinResized realigns overlays to the host pane width", function()
    local box = {}
    local handle = nr.mount_as_window_host(make_app(box), {}, {
      split = { direction = "vertical", position = "left", size = 20 },
    })

    local float_winid = box.ref.current.winid
    local narrow = vim.api.nvim_win_get_config(float_winid).width

    -- Manually widen the host pane (as `<C-w>>` would) and announce it. The
    -- relayout is coalesced onto the scheduler (debounced against resize bursts),
    -- so wait for it to land before observing the overlay's new width.
    vim.api.nvim_win_set_width(handle.host_winid, 50)
    vim.api.nvim_exec_autocmds("WinResized", {})

    vim.wait(200, function()
      return vim.api.nvim_win_get_config(float_winid).width > narrow
    end)
    local wide = vim.api.nvim_win_get_config(float_winid).width
    assert.is_true(wide > narrow, "overlay should widen with the host pane")

    handle.unmount()
  end)

  it("auto_unmount: closing the host pane tears the whole app down", function()
    local box = {}
    local handle = nr.mount_as_window_host(make_app(box), {}, {
      split = { direction = "vertical", position = "left", size = 30 },
      behavior = { auto_unmount = true },
    })

    local float_winid = box.ref.current.winid
    assert.is_true(vim.api.nvim_win_is_valid(float_winid))

    vim.api.nvim_win_close(handle.host_winid, false)
    -- Teardown is deferred (you cannot close windows from inside WinClosed).
    vim.wait(200, function()
      return not vim.api.nvim_win_is_valid(float_winid)
    end)

    assert.is_false(vim.api.nvim_win_is_valid(float_winid))
  end)
end)
