-- ui.animation: a time-driven text leaf. `value(progress)` maps progress in
-- [0, 1) — elapsed time modulo `duration`, i.e. an implicit loop — to the
-- text/spans to show; a uv timer ticks at `fps` (default 30) and commits ONLY
-- when the rendered value actually changed, so buffer writes scale with
-- visible motion, not with the frame rate. Each commit is a subtree-scoped
-- update (the memoized fast path). Frame 0 renders synchronously at mount;
-- `play = false` freezes without unmounting.

local runtime = require("fibrous.reactive.runtime")
local inline_host = require("fibrous.inline.host")
local ui = require("fibrous.inline.components")

local function host_of(w)
  return inline_host.new({
    get_size = function()
      return { width = w }
    end,
  })
end

local function line_of(host)
  return vim.api.nvim_buf_get_lines(host.bufnr, 0, 1, false)[1]
end

-- Mount an animation whose value quantizes progress into `buckets` frames
-- ("f0", "f1", …): deterministic observables out of nondeterministic timing.
local function mount_frames(opts)
  local calls = 0
  local host = host_of(6)
  local function App()
    return {
      comp = ui.animation,
      props = {
        duration = opts.duration,
        fps = opts.fps,
        play = opts.play,
        value = function(progress)
          calls = calls + 1
          return "f" .. math.floor(progress * opts.buckets)
        end,
      },
    }
  end
  local root = runtime.create_root(App, {}, { host = host }):render()
  return host, root, function()
    return calls
  end
end

describe("inline.components animation", function()
  it("renders value(0) synchronously at mount, no timer needed", function()
    local host, root, calls = mount_frames({ duration = 60, buckets = 4 })
    assert.same("f0    ", line_of(host))
    assert.equal(1, calls())
    root:unmount()
  end)

  it("advances through the frames and wraps back around (loop)", function()
    local host, root = mount_frames({ duration = 0.12, fps = 60, buckets = 4 })

    local seen_late = vim.wait(2000, function()
      return line_of(host):find("f2", 1, true) ~= nil or line_of(host):find("f3", 1, true) ~= nil
    end, 5)
    assert.is_true(seen_late, "never reached a later frame")

    local wrapped = vim.wait(2000, function()
      return line_of(host):find("f0", 1, true) ~= nil
    end, 5)
    assert.is_true(wrapped, "progress never wrapped back to frame 0")
    root:unmount()
  end)

  it("ticks that render the same value commit nothing", function()
    -- 2 buckets over 0.4s at 60fps: plenty of ticks, at most a few distinct
    -- frames — the buffer must only change when the frame does
    local host, root, calls = mount_frames({ duration = 0.4, fps = 60, buckets = 2 })
    local tick0 = vim.api.nvim_buf_get_changedtick(host.bufnr)

    vim.wait(300, function()
      return false
    end, 10)

    local commits = vim.api.nvim_buf_get_changedtick(host.bufnr) - tick0
    assert.is_true(calls() >= 8, "timer barely ran (" .. calls() .. " value calls)")
    assert.is_true(commits <= 4, "committed " .. commits .. " times for ~2 distinct frames")
    root:unmount()
  end)

  it("unmount stops the timer", function()
    local host, root, calls = mount_frames({ duration = 0.1, fps = 60, buckets = 4 })
    root:unmount()
    local after = calls()
    vim.wait(100, function()
      return false
    end, 10)
    assert.equal(after, calls())
  end)

  it("play = false freezes at the current frame without a timer", function()
    local host, root, calls = mount_frames({ duration = 0.05, fps = 60, buckets = 4, play = false })
    assert.same("f0    ", line_of(host))
    vim.wait(120, function()
      return false
    end, 10)
    assert.same("f0    ", line_of(host))
    assert.equal(1, calls())
    root:unmount()
  end)

  it("styles pass through to the text leaf", function()
    local host = host_of(6)
    local function App()
      return {
        comp = ui.animation,
        props = {
          duration = 60,
          style = { text_hl = "Title" },
          value = function()
            return "hi"
          end,
        },
      }
    end
    local root = runtime.create_root(App, {}, { host = host }):render()
    local mark = vim.api.nvim_buf_get_extmarks(host.bufnr, -1, 0, -1, { details = true })[1]
    assert.equal("Title", mark[4].hl_group)
    root:unmount()
  end)

  it("a missing or non-positive duration and a missing value error loudly", function()
    for _, props in ipairs({
      { value = function() end },
      { duration = 0, value = function() end },
      { duration = 1 },
    }) do
      local function App()
        return { comp = ui.animation, props = props }
      end
      local host = host_of(6)
      assert.has_error(function()
        runtime.create_root(App, {}, { host = host }):render()
      end, "animation")
    end
  end)
end)
