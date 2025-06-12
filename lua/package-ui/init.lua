local M = {}
local api = vim.api
local main = require("package-ui.main")

function M.setup(opts)
  opts = opts or {}
  vim.cmd([[
        highlight default PackageUiNormal guibg=#1e1e2e guifg=#cdd6f4
        highlight default PackageUiInput guibg=#313244 guifg=#f38ba8
        highlight default PackageUiBackdrop guibg=#000000 guifg=#000000
        highlight default PackageUiFocusedBorder guifg=#F9B387 gui=bold
        highlight default PackageUiUnfocusedBorder guifg=#8AB4FA
        highlight default PackageUiUpdateIndicator guifg=#A6E3A1
        highlight default PackageUiCursorLine guibg=#313244 guifg=#cdd6f4
        highlight default PackageUiDetailLabel guifg=#31B3FA gui=bold
    ]])
  api.nvim_create_user_command("PackageUI", function()
    main.setup()
  end, { desc = "Open Package UI" })
end

return M
