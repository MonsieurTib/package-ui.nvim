local M = {}
local api = vim.api

function M.navigate_next()
  api.nvim_exec_autocmds("User", { pattern = "PackageUINavigateNext" })
end

function M.navigate_previous()
  api.nvim_exec_autocmds("User", { pattern = "PackageUINavigatePrevious" })
end

function M.close_ui()
  api.nvim_exec_autocmds("User", { pattern = "PackageUIClose" })
end

function M.dispatch(event_name, data)
  api.nvim_exec_autocmds("User", {
    pattern = "PackageUI" .. event_name,
    data = data,
  })
end

return M

