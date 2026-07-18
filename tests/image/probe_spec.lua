-- Terminal capability probing (fibrous.image.probe): the pure response
-- classifier and the serialized query engine, with writer/timer/TermResponse
-- all injected so no probe ever reaches a real terminal.

local probe = require("fibrous.image.probe")

describe("image.probe", function()
  describe("classify", function()
    it("recognizes a kitty graphics (APC) reply with its query id", function()
      local e = probe.classify("\27_Gi=31;OK")
      assert.same({ kind = "graphics", id = 31, msg = "OK" }, e)
    end)

    it("recognizes a graphics error reply too (protocol is present either way)", function()
      local e = probe.classify("\27_Gi=31;EBADPNG:bad")
      assert.equal("graphics", e.kind)
      assert.equal(31, e.id)
    end)

    it("recognizes an XTVERSION (DCS) reply and extracts the version text", function()
      local e = probe.classify("\27P>|kitty(0.47.4)")
      assert.same({ kind = "xtversion", version = "kitty(0.47.4)" }, e)
    end)

    it("recognizes a DA1 (CSI ? ... c) reply", function()
      assert.same({ kind = "da1" }, probe.classify("\27[?62;4c"))
      assert.same({ kind = "da1" }, probe.classify("\27[?1;2c"))
    end)

    it("recognizes an OSC 5522 clipboard reply and extracts the status", function()
      local e = probe.classify("\27]5522;type=write:status=DONE")
      assert.same({ kind = "clipboard", status = "DONE" }, e)
    end)

    it("ignores unrelated responses", function()
      assert.is_nil(probe.classify("\27]11;rgb:1e1e/1e1e/1e1e"))
      assert.is_nil(probe.classify("\27]52;c;aGVsbG8="))
      assert.is_nil(probe.classify("\27[38:2::1:2:3m"))
      assert.is_nil(probe.classify("plain text"))
    end)
  end)

  describe("engine", function()
    local written, timers, on_seq, armed
    local function make()
      written, timers, armed = {}, {}, 0
      return probe.new({
        writer = function(data)
          written[#written + 1] = data
        end,
        arm = function(cb)
          on_seq = cb
          armed = armed + 1
          return function()
            on_seq = nil
          end
        end,
        defer = function(_, cb)
          timers[#timers + 1] = { fire = cb, cancelled = false }
          local t = timers[#timers]
          return function()
            t.cancelled = true
          end
        end,
      })
    end

    it("writes the job's escapes and finishes on the reducing response", function()
      local eng = make()
      local result
      eng:run({
        escapes = "QUERY",
        timeout = 100,
        reduce = function(evt)
          return evt.kind == "da1" and "saw-da1" or nil
        end,
        done = function(r)
          result = r
        end,
      })
      assert.same({ "QUERY" }, written)
      on_seq("\27]11;ignored")
      assert.is_nil(result)
      on_seq("\27[?62;4c")
      assert.equal("saw-da1", result)
      assert.is_true(timers[1].cancelled)
      assert.is_nil(on_seq) -- disarmed once idle
    end)

    it("times out with a nil result", function()
      local eng = make()
      local called, result = false, "sentinel"
      eng:run({
        escapes = "Q",
        timeout = 100,
        reduce = function()
          return nil
        end,
        done = function(r)
          called, result = true, r
        end,
      })
      timers[1].fire()
      assert.is_true(called)
      assert.is_nil(result)
    end)

    it("serializes jobs: the second writes only after the first finishes", function()
      local eng = make()
      local order = {}
      eng:run({
        escapes = "FIRST",
        timeout = 100,
        reduce = function(evt)
          return evt.kind == "da1" and true or nil
        end,
        done = function()
          order[#order + 1] = "first-done"
        end,
      })
      eng:run({
        escapes = "SECOND",
        timeout = 100,
        reduce = function(evt)
          return evt.kind == "da1" and true or nil
        end,
        done = function()
          order[#order + 1] = "second-done"
        end,
      })
      assert.same({ "FIRST" }, written)
      on_seq("\27[?62;4c")
      assert.same({ "FIRST", "SECOND" }, written)
      assert.same({ "first-done" }, order)
      on_seq("\27[?62;4c")
      assert.same({ "first-done", "second-done" }, order)
    end)

    it("a reducer sees every classified event until it returns non-nil", function()
      local eng = make()
      local seen = {}
      eng:run({
        escapes = "Q",
        timeout = 100,
        reduce = function(evt)
          seen[#seen + 1] = evt.kind
          return evt.kind == "da1" and seen or nil
        end,
        done = function() end,
      })
      on_seq("\27_Gi=31;OK")
      on_seq("\27P>|kitty(0.47.4)")
      on_seq("\27[?62;4c")
      assert.same({ "graphics", "xtversion", "da1" }, seen)
    end)

    it("teardown cancels the active timer and disarms", function()
      local eng = make()
      local called = false
      eng:run({
        escapes = "Q",
        timeout = 100,
        reduce = function()
          return nil
        end,
        done = function()
          called = true
        end,
      })
      eng:teardown()
      assert.is_true(timers[1].cancelled)
      assert.is_nil(on_seq)
      assert.is_false(called) -- torn down, not timed out
    end)
  end)
end)

describe("image.probe capability_job", function()
  local kitty = require("fibrous.image.kitty")

  it("volleys graphics query + XTVERSION + DA1, each wrapped", function()
    local job = probe.capability_job({
      query = kitty.query(31),
      wrap = function(esc)
        return "<" .. esc .. ">"
      end,
    })
    assert.equal("<" .. kitty.query(31) .. "><" .. probe.XTVERSION .. "><" .. probe.DA1 .. ">", job.escapes)
  end)

  it("collects graphics + version until the DA1 bracket lands", function()
    local job = probe.capability_job({ query = kitty.query(31) })
    assert.is_nil(job.reduce({ kind = "graphics", id = 31, msg = "OK" }))
    assert.is_nil(job.reduce({ kind = "xtversion", version = "kitty(0.47.4)" }))
    local r = job.reduce({ kind = "da1" })
    assert.same({ graphics = true, version = "kitty(0.47.4)" }, r)
  end)

  it("DA1 alone reports graphics=false and no version", function()
    local job = probe.capability_job({ query = kitty.query(31) })
    local r = job.reduce({ kind = "da1" })
    assert.is_false(r.graphics)
    assert.is_nil(r.version)
  end)

  it("ignores a graphics reply for someone else's query id", function()
    local job = probe.capability_job({ query = kitty.query(31) })
    assert.is_nil(job.reduce({ kind = "graphics", id = 7, msg = "OK" }))
    local r = job.reduce({ kind = "da1" })
    assert.is_false(r.graphics)
  end)
end)
