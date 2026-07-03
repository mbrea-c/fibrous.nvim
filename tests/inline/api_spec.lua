-- The public entry point (tracker "NEW UI HOST" task 9, migration): with the
-- legacy nui host gone, `require("fibrous")` exposes the inline host's mount
-- targets and component set directly.

describe("fibrous public API", function()
  it("exposes the inline mount targets and components", function()
    local fibrous = require("fibrous")
    local mount = require("fibrous.inline.mount")
    local ui = require("fibrous.inline.components")

    assert.rawequal(mount.floating, fibrous.mount)
    assert.rawequal(mount.split, fibrous.mount_split)
    assert.rawequal(mount.window, fibrous.mount_window)
    assert.rawequal(ui, fibrous.ui)
  end)

  it("no longer drags the legacy nui host along", function()
    require("fibrous")
    assert.is_nil(package.loaded["fibrous.dom.nui_host"])
    assert.is_nil(package.loaded["nui.popup"])
  end)
end)
