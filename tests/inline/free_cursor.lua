-- For interactions that deliberately place the cursor on inert text or padding.
return function(name, test)
  it(name, function()
    local mode = require("fibrous.inline.widget_mode")
    local enabled = mode.enabled
    if enabled then mode.toggle() end
    local ok, err = pcall(test)
    if enabled then mode.toggle() end
    if not ok then error(err, 0) end
  end)
end
