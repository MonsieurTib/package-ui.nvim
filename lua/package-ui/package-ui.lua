if vim.g.loaded_package_ui == 1 then
  return
end
vim.g.loaded_package_ui = 1

-- Create the main command
vim.api.nvim_create_user_command("PackageUI", function()
  require("package-ui.main").setup()
end, {
  desc = "Open Package UI search panel",
  nargs = 0,
})
