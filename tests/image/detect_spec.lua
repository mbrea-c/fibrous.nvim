-- Provider auto-detection (inline images): a pure function of an env table
-- plus injectable tmux/termguicolors facts, so every terminal combination is
-- testable headless.

local detect = require("fibrous.image.detect")

-- Defaults: a bare kitty session with termguicolors on.
local function probe(env, opts)
  opts = opts or {}
  if opts.termguicolors == nil then
    opts.termguicolors = true
  end
  return detect.provider(env, opts)
end

describe("image.detect", function()
  it("TERM=xterm-kitty means kitty", function()
    local r = probe({ TERM = "xterm-kitty" })
    assert.equal("kitty", r.provider)
    assert.is_false(r.tmux)
  end)

  it("KITTY_WINDOW_ID means kitty even under a generic TERM", function()
    assert.equal("kitty", probe({ TERM = "xterm-256color", KITTY_WINDOW_ID = "1" }).provider)
  end)

  it("ghostty supports placeholders", function()
    assert.equal("kitty", probe({ TERM = "xterm-ghostty" }).provider)
    assert.equal("kitty", probe({ TERM = "xterm-256color", TERM_PROGRAM = "ghostty" }).provider)
    assert.equal("kitty", probe({ TERM = "xterm-256color", GHOSTTY_RESOURCES_DIR = "/x" }).provider)
  end)

  it("an unknown terminal falls back to text", function()
    assert.equal("text", probe({ TERM = "xterm-256color" }).provider)
  end)

  it("WezTerm is excluded (no placeholder support)", function()
    assert.equal("text", probe({ TERM = "xterm-256color", TERM_PROGRAM = "WezTerm" }).provider)
  end)

  it("termguicolors off means text: the id encoding needs RGB foregrounds", function()
    local r = probe({ TERM = "xterm-kitty" }, { termguicolors = false })
    assert.equal("text", r.provider)
    assert.truthy(r.reason:find("termguicolors"))
  end)

  describe("inside tmux", function()
    it("asks tmux for the outer terminal and requires passthrough", function()
      local r = probe({ TERM = "tmux-256color", TMUX = "/tmp/tmux-1000/default,1,0" }, {
        tmux_info = function()
          return { term = "xterm-kitty", passthrough = "on" }
        end,
      })
      assert.equal("kitty", r.provider)
      assert.is_true(r.tmux)
    end)

    it("allow-passthrough all also qualifies", function()
      local r = probe({ TMUX = "y" }, {
        tmux_info = function()
          return { term = "xterm-kitty", passthrough = "all" }
        end,
      })
      assert.equal("kitty", r.provider)
    end)

    it("passthrough off means text, with a warning to surface once", function()
      local r = probe({ TMUX = "y" }, {
        tmux_info = function()
          return { term = "xterm-kitty", passthrough = "off" }
        end,
      })
      assert.equal("text", r.provider)
      assert.truthy(r.warn:find("allow%-passthrough"))
    end)

    it("a non-kitty outer terminal means text", function()
      local r = probe({ TMUX = "y" }, {
        tmux_info = function()
          return { term = "xterm-256color", passthrough = "on" }
        end,
      })
      assert.equal("text", r.provider)
    end)

    it("an unanswerable tmux query means text", function()
      local r = probe({ TMUX = "y" }, {
        tmux_info = function()
          return nil
        end,
      })
      assert.equal("text", r.provider)
    end)
  end)
end)

describe("image.detect probing", function()
  it("marks kitty resolutions probeable (confirmation) and text-with-signals not", function()
    assert.is_true(probe({ TERM = "xterm-kitty" }).probeable)
    assert.falsy(probe({ TERM = "x", TERM_PROGRAM = "WezTerm" }).probeable)
    assert.falsy(probe({ TERM = "xterm-kitty" }, { termguicolors = false }).probeable)
  end)

  it("marks an unidentified terminal probeable (promotion candidate)", function()
    assert.is_true(probe({ TERM = "xterm-256color" }).probeable)
  end)

  it("inside tmux, probing needs passthrough: unidentified outer is probeable only with it on", function()
    local function tmux(term, passthrough)
      return probe({ TMUX = "y" }, {
        tmux_info = function()
          return { term = term, passthrough = passthrough }
        end,
      })
    end
    assert.is_true(tmux("xterm-kitty", "on").probeable)
    assert.is_true(tmux("xterm-256color", "on").probeable)
    assert.falsy(tmux("xterm-256color", "off").probeable)
    assert.falsy(tmux("xterm-kitty", "off").probeable)
  end)

  describe("identity", function()
    it("extracts and normalizes the terminal name from an XTVERSION reply", function()
      assert.equal("kitty", detect.identity("kitty(0.47.4)"))
      assert.equal("ghostty", detect.identity("ghostty 1.1.3"))
      assert.equal("tmux", detect.identity("tmux 3.5a"))
      assert.equal("wezterm", detect.identity("WezTerm 20240203-110809-5046fc22"))
      assert.equal("xterm", detect.identity("XTerm(396)"))
    end)

    it("is nil for garbage", function()
      assert.is_nil(detect.identity(""))
      assert.is_nil(detect.identity("   "))
    end)
  end)

  describe("confirm (env resolution x probe result)", function()
    local kitty_env = { provider = "kitty", tmux = false, probeable = true }
    local text_env = { provider = "text", tmux = false, probeable = true, reason = "terminal not identified" }

    it("kitty identity + graphics reply confirms a kitty resolution (no change)", function()
      assert.is_nil(detect.confirm(kitty_env, { graphics = true, identity = "kitty" }))
    end)

    it("promotes text to kitty when the terminal identifies as kitty/ghostty", function()
      local r = detect.confirm(text_env, { graphics = true, identity = "ghostty" })
      assert.equal("kitty", r.provider)
      local r2 = detect.confirm(text_env, { graphics = true, identity = "kitty" })
      assert.equal("kitty", r2.provider)
    end)

    it("demotes kitty to text when the terminal identifies as something else", function()
      local r = detect.confirm(kitty_env, { graphics = nil, identity = "wezterm" })
      assert.equal("text", r.provider)
      assert.truthy(r.reason)
    end)

    it("demotes kitty to text when the bracket returns but graphics never answered", function()
      local r = detect.confirm(kitty_env, { graphics = false, identity = nil })
      assert.equal("text", r.provider)
      assert.truthy(r.reason)
    end)

    it("graphics without a placeholder-capable identity does not promote (WezTerm-shaped)", function()
      assert.is_nil(detect.confirm(text_env, { graphics = true, identity = nil }))
      assert.is_nil(detect.confirm(text_env, { graphics = true, identity = "konsole" }))
    end)

    it("a tmux identity means the queries never left tmux: no change either way", function()
      assert.is_nil(detect.confirm(kitty_env, { graphics = false, identity = "tmux" }))
      assert.is_nil(detect.confirm(text_env, { graphics = false, identity = "tmux" }))
    end)

    it("a timeout (nil probe) changes nothing", function()
      assert.is_nil(detect.confirm(kitty_env, nil))
      assert.is_nil(detect.confirm(text_env, nil))
    end)

    it("keeps the tmux flag across promotion and demotion", function()
      local r = detect.confirm({ provider = "text", tmux = true, probeable = true }, { graphics = true, identity = "kitty" })
      assert.is_true(r.tmux)
      local r2 = detect.confirm({ provider = "kitty", tmux = true, probeable = true }, { graphics = false, identity = nil })
      assert.is_true(r2.tmux)
    end)
  end)
end)
