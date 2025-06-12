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
    title = " Versions ",
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

function M.getWindow()
  return component_state.win
end

function M.getBuf()
  return component_state.buf
end

function M.isValid()
  return component_state.win and api.nvim_win_is_valid(component_state.win)
end

function M.setup_cursor_detection()
  if not component_state.buf then
    return
  end

  api.nvim_create_autocmd("CursorMoved", {
    buffer = component_state.buf,
    callback = function()
      M.trigger_version_selection()
    end,
  })
end

function M.setup_key_mappings()
  if not component_state.buf then
    return
  end

  api.nvim_buf_set_keymap(component_state.buf, "n", "i", "", {
    callback = function()
      M.trigger_package_install()
    end,
    desc = "Install selected package version",
  })
end

function M.trigger_package_install()
  if not M.isValid() then
    return
  end

  local version_info = M.get_selected_version()
  if version_info and version_info.version and version_info.package_name then
    api.nvim_exec_autocmds("User", {
      pattern = "PackageUIInstallPackage",
      data = {
        package_name = version_info.package_name,
        version = version_info.version,
      },
    })
  end
end

function M.trigger_version_selection()
  if not M.isValid() then
    return
  end

  local version_info = M.get_selected_version()
  if version_info and version_info.version and version_info.package_name then
    api.nvim_exec_autocmds("User", {
      pattern = "PackageUIVersionSelected",
      data = {
        version = version_info.version,
        package_name = version_info.package_name,
      },
    })
  end
end

function M.get_selected_version()
  if not M.isValid() then
    return nil
  end

  local cursor = api.nvim_win_get_cursor(component_state.win)
  local line_num = cursor[1]

  local lines = api.nvim_buf_get_lines(component_state.buf, line_num - 1, line_num, false)
  if #lines > 0 then
    local line = lines[1]

    if line:match("^%s*No ") or line:match("^%s*Select ") or line:match("^%s*Loading ") or line == "" then
      return nil
    end

    local version = line:gsub("^%s+", ""):gsub("%s+$", "")
    if version and version ~= "" then
      return {
        version = version,
        package_name = component_state.current_package_name,
      }
    end
  end

  return nil
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

function M.setCurrentPackage(package_name)
  component_state.current_package_name = package_name
end

function M.selectVersion(version)
  if not M.isValid() or not version then
    return false
  end

  local lines = api.nvim_buf_get_lines(component_state.buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_version = line:gsub("^%s+", ""):gsub("%s+$", "")

    if line_version == version then
      api.nvim_win_set_cursor(component_state.win, { i, 0 })

      M.trigger_version_selection()

      return true
    end
  end

  return false
end

function M.clear()
  component_state.win = nil
  component_state.buf = nil
end

return M
