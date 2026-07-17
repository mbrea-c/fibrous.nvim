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
