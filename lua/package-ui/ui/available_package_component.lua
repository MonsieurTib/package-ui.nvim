local M = {}
local api = vim.api

local component_state = {
  win = nil,
  buf = nil,
}

function M.create(height, width, row, col)
  local opts = {
    style = "minimal",
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = " Available packages ",
    zindex = 50,
  }

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, false, opts)

  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "filetype", "package-ui")

  api.nvim_win_set_option(win, "winhl", "Normal:PackageUiNormal,CursorLine:PackageUiCursorLine")
  api.nvim_win_set_option(win, "number", false)
  api.nvim_win_set_option(win, "relativenumber", false)
  api.nvim_win_set_option(win, "cursorline", true)
  api.nvim_win_set_option(win, "signcolumn", "no")
  api.nvim_win_set_option(win, "foldcolumn", "0")

  component_state.win = win
  component_state.buf = buf

  M.setup_cursor_detection()
  M.setup_key_mappings()

  return { buf = buf, win = win }
end

function M.setup_cursor_detection()
  if not component_state.buf then
    return
  end

  api.nvim_create_autocmd("CursorMoved", {
    buffer = component_state.buf,
    callback = function()
      M.trigger_package_selection()
    end,
  })
end

function M.setup_key_mappings()
  if not component_state.buf then
    return
  end

  api.nvim_buf_set_keymap(component_state.buf, "n", "<CR>", "", {
    callback = function()
      M.trigger_navigate_to_versions()
    end,
    desc = "Navigate to versions window",
  })
end

function M.trigger_package_selection()
  if not M.isValid() then
    return
  end

  local package_line = M.get_selected_package_line()
  if package_line and package_line ~= "" then
    api.nvim_exec_autocmds("User", {
      pattern = "PackageUIPackageSelected",
      data = {
        package_line = package_line,
        source = "available",
      },
    })
  end
end

function M.trigger_navigate_to_versions()
  if not M.isValid() then
    return
  end

  local package_line = M.get_selected_package_line()
  if package_line and package_line ~= "" then
    api.nvim_exec_autocmds("User", {
      pattern = "PackageUINavigateToVersions",
      data = {
        package_line = package_line,
      },
    })
  end
end

function M.get_selected_package_line()
  if not M.isValid() then
    return nil
  end

  local cursor = api.nvim_win_get_cursor(component_state.win)
  local line_num = cursor[1]

  local lines = api.nvim_buf_get_lines(component_state.buf, line_num - 1, line_num, false)
  if #lines > 0 then
    return lines[1]
  end

  return nil
end

function M.getWindow()
  return component_state.win
end

function M.getBuf()
  return component_state.buf
end

function M.isValid()
  return component_state.win and api.nvim_win_is_valid(component_state.win)
end

function M.updateContent(lines)
  if not M.isValid() then
    return false
  end

  api.nvim_buf_set_option(component_state.buf, "modifiable", true)
  api.nvim_buf_set_lines(component_state.buf, 0, -1, false, lines or {})
  api.nvim_buf_set_option(component_state.buf, "modifiable", false)

  return true
end

function M.has_results()
  if not M.isValid() then
    return false
  end

  local lines = api.nvim_buf_get_lines(component_state.buf, 0, -1, false)
  if not lines or #lines == 0 then
    return false
  end

  local first_line = lines[1] and lines[1]:gsub("^%s+", ""):gsub("%s+$", "")
  if not first_line or first_line == "" then
    return false
  end

  if
      first_line:match("^No ")
      or first_line:match("^Type to search ")
      or first_line:match("^Searching ")
      or first_line:match("^Check your search term")
      or first_line:match("^Package service not available")
      or first_line:match("^No package manager detected")
  then
    return false
  end

  return true
end

function M.get_first_result()
  if not M.has_results() then
    return nil
  end

  local lines = api.nvim_buf_get_lines(component_state.buf, 0, -1, false)
  if lines and #lines > 0 then
    return lines[1]:gsub("^%s+", ""):gsub("%s+$", "")
  end

  return nil
end

function M.clear()
  component_state.win = nil
  component_state.buf = nil
end

return M
