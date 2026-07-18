-- System-clipboard copy (fibrous.image.clipboard): pure OSC 5522 escape
-- building and tool choice, plus the probe-or-cached copy flow over a fake
-- engine/writer/runner/notify -- nothing reaches a real terminal or spawns.

local clipboard = require("fibrous.image.clipboard")
local probe = require("fibrous.image.probe")

local PNG_MIME_B64 = vim.base64.encode("image/png")

describe("image.clipboard", function()
  after_each(function()
    clipboard.reset()
  end)

  describe("osc_write", function()
    it("wraps the payload in a write transaction with the png mime", function()
      local esc = clipboard.osc_write("QUJD")
      assert.equal(3, #esc)
      assert.equal("\27]5522;type=write\27\\", esc[1])
      assert.equal("\27]5522;type=wdata:mime=" .. PNG_MIME_B64 .. ";QUJD\27\\", esc[2])
      assert.equal("\27]5522;type=wdata\27\\", esc[3])
    end)

    it("chunks at 4095 data bytes (5460 base64 chars) on 4-char boundaries", function()
      local b64 = string.rep("A", 5460 * 2 + 8)
      local esc = clipboard.osc_write(b64)
      assert.equal(5, #esc) -- start + 3 chunks + terminator
      local c1 = esc[2]:match(";(%u+)\27\\$")
      local c3 = esc[4]:match(";(%u+)\27\\$")
      assert.equal(5460, #c1)
      assert.equal(8, #c3)
      -- every chunk decodes independently: 5460 chars = 4095 bytes % 3 == 0
      assert.equal(0, 5460 % 4)
    end)
  end)

  describe("tool", function()
    local function has(list)
      return function(bin)
        return vim.tbl_contains(list, bin)
      end
    end

    it("prefers wl-copy on wayland", function()
      local t = clipboard.tool({ WAYLAND_DISPLAY = "wayland-1", DISPLAY = ":0" }, has({ "wl-copy", "xclip" }))
      assert.same({ "wl-copy", "-t", "image/png" }, t.argv)
    end)

    it("falls back to xclip on x11", function()
      local t = clipboard.tool({ DISPLAY = ":0" }, has({ "xclip" }))
      assert.same({ "xclip", "-selection", "clipboard", "-t", "image/png", "-i" }, t.argv)
    end)

    it("nil without a display or without the binary", function()
      assert.is_nil(clipboard.tool({}, has({ "wl-copy", "xclip" })))
      assert.is_nil(clipboard.tool({ DISPLAY = ":0" }, has({})))
    end)

    it("osascript on mac needs no display", function()
      local t = clipboard.tool({}, has({ "osascript" }), true)
      assert.is_true(t.osascript)
    end)
  end)

  describe("copy flow", function()
    local written, notified, ran, on_seq, on_timeout
    local function ctx(over)
      written, notified, ran = {}, {}, {}
      local eng = probe.new({
        writer = function(d)
          written[#written + 1] = d
        end,
        arm = function(cb)
          on_seq = cb
          return function()
            on_seq = nil
          end
        end,
        defer = function(_, cb)
          on_timeout = cb
          return function() end
        end,
      })
      return vim.tbl_extend("keep", over or {}, {
        backend = "auto",
        engine = eng,
        writer = function(d)
          written[#written + 1] = d
        end,
        wrap = false,
        notify = function(msg, level)
          notified[#notified + 1] = { msg = msg, level = level }
        end,
        runner = function(spec, bytes, cb)
          ran[#ran + 1] = { spec = spec, bytes = bytes }
          cb(true)
        end,
        env = {},
        has = function()
          return false
        end,
        env_says_kitty = false,
      })
    end

    local b64 = vim.base64.encode("png-bytes-here")

    it("first copy probes: DONE learns osc5522 and notifies success", function()
      clipboard.copy(b64, ctx())
      assert.equal(1, #written)
      assert.truthy(written[1]:find("5522", 1, true))
      assert.truthy(written[1]:find(probe.DA1, 1, true)) -- bracketed
      on_seq("\27]5522;type=write:status=DONE")
      assert.equal(1, #notified)
      assert.truthy(notified[1].msg:find("copied", 1, true))
      assert.equal("osc5522", clipboard.state.backend)
    end)

    it("a learned osc5522 backend skips the bracket and notifies straight away", function()
      clipboard.state.backend = "osc5522"
      clipboard.copy(b64, ctx())
      assert.equal(1, #written)
      assert.falsy(written[1]:find(probe.DA1, 1, true))
      assert.equal(1, #notified)
    end)

    it("bracket without DONE falls back to the tool within the same copy", function()
      local c = ctx({
        env = { WAYLAND_DISPLAY = "w" },
        has = function(bin)
          return bin == "wl-copy"
        end,
      })
      clipboard.copy(b64, c)
      on_seq("\27[?62;4c")
      assert.equal(1, #ran)
      assert.equal("wl-copy", ran[1].spec.argv[1])
      assert.equal(vim.base64.decode(b64), ran[1].bytes)
      assert.equal("tool", clipboard.state.backend)
      assert.equal(1, #notified)
    end)

    it("unsupported with no tool available notifies the failure with a hint", function()
      clipboard.copy(b64, ctx())
      on_seq("\27[?62;4c")
      assert.equal(1, #notified)
      assert.equal(vim.log.levels.WARN, notified[1].level)
      assert.truthy(notified[1].msg:find("wl%-copy"))
    end)

    it("timeout with kitty-shaped env trusts the write and caches the backend", function()
      clipboard.copy(b64, ctx({ env_says_kitty = true }))
      on_timeout()
      assert.equal(1, #notified)
      assert.truthy(notified[1].msg:find("copied", 1, true))
      assert.equal("osc5522", clipboard.state.backend)
    end)

    it("timeout without kitty signals tries the tool", function()
      local c = ctx({
        env = { DISPLAY = ":0" },
        has = function(bin)
          return bin == "xclip"
        end,
      })
      clipboard.copy(b64, c)
      on_timeout()
      assert.equal(1, #ran)
      assert.equal("xclip", ran[1].spec.argv[1])
    end)

    it("forced tool backend never writes escapes", function()
      local c = ctx({
        backend = "tool",
        env = { WAYLAND_DISPLAY = "w" },
        has = function()
          return true
        end,
      })
      clipboard.copy(b64, c)
      assert.equal(0, #written)
      assert.equal(1, #ran)
    end)

    it("a failing tool notifies at warn level", function()
      local c = ctx({
        backend = "tool",
        env = { WAYLAND_DISPLAY = "w" },
        has = function()
          return true
        end,
        runner = function(spec, bytes, cb)
          cb(false, "exit 1")
        end,
      })
      clipboard.copy(b64, c)
      assert.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it("tmux wrapping applies to the whole probe volley", function()
      clipboard.copy(b64, ctx({ wrap = true }))
      assert.truthy(written[1]:find("\27Ptmux;", 1, true))
    end)
  end)
end)
