local M = {}
local api = vim.api

function M.create()
	local screen_width = api.nvim_get_option("columns")
	local screen_height = api.nvim_get_option("lines")

	local opts = {
		style = "minimal",
		relative = "editor",
		width = screen_width,
		height = screen_height,
		row = 0,
		col = 0,
		focusable = false,
		zindex = 1,
	}

	local buf = api.nvim_create_buf(false, true)
	local win = api.nvim_open_win(buf, false, opts)

	api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(buf, "filetype", "package-ui-backdrop")

	api.nvim_win_set_option(win, "winhl", "Normal:PackageUiBackdrop")
	api.nvim_win_set_option(win, "winblend", 20)

	return { buf = buf, win = win }
end

return M

