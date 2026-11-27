if vim.g.loaded_fibrous_widget_mode then return end
vim.g.loaded_fibrous_widget_mode = true

vim.api.nvim_create_user_command("FibrousToggleWidgetMode", function()
  require("fibrous.inline.widget_mode").toggle()
end, { desc = "Toggle widget navigation across Fibrous views" })
