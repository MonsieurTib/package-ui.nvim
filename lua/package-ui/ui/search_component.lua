local M = {}
local api = vim.api

local component_state = {
  win = nil,
  buf = nil,
  search_timer = nil,
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
    title = " Search ",
    zindex = 50,
  }

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, opts)

  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "filetype", "package-ui")
  api.nvim_buf_set_option(buf, "modifiable", true)

  api.nvim_win_set_option(win, "winhl", "Normal:PackageUiInput")
  api.nvim_win_set_option(win, "number", false)
  api.nvim_win_set_option(win, "relativenumber", false)
  api.nvim_win_set_option(win, "cursorline", false)

  component_state.win = win
  component_state.buf = buf

  M.setup_search_autocmd()
  M.setup_key_mappings()

  return { buf = buf, win = win }
end

function M.setup_search_autocmd()
  if not component_state.buf then
    return
  end

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = component_state.buf,
    callback = function()
      M.debounced_trigger_search()
    end,
  })
end

function M.setup_key_mappings()
  if not component_state.buf then
    return
  end

  api.nvim_buf_set_keymap(component_state.buf, "n", "<CR>", "", {
    callback = function()
      M.navigate_to_first_result()
    end,
    desc = "Navigate to first search result",
  })

  api.nvim_buf_set_keymap(component_state.buf, "i", "<CR>", "", {
    callback = function()
      M.navigate_to_first_result()
    end,
    desc = "Navigate to first search result",
  })
end

function M.debounced_trigger_search()
  if not M.isValid() then
    return
  end

  if component_state.search_timer then
    component_state.search_timer:stop()
    component_state.search_timer = nil
  end

  component_state.search_timer = vim.defer_fn(function()
    M.trigger_search()
    component_state.search_timer = nil
  end, 300)
end

function M.trigger_search()
  if not M.isValid() then
    return
  end

  local search_term = M.get_search_term()
  api.nvim_exec_autocmds("User", {
    pattern = "PackageUISearch",
    data = { search_term = search_term },
  })
end

function M.get_search_term()
  if not M.isValid() then
    return ""
  end

  local lines = api.nvim_buf_get_lines(component_state.buf, 0, -1, false)
  if #lines > 0 then
    return lines[1] or ""
  end
  return ""
end

function M.reset()
  if not M.isValid() then
    return false
  end

  local current_term = M.get_search_term()
  if current_term and current_term ~= "" then
    api.nvim_buf_set_option(component_state.buf, "modifiable", true)
    api.nvim_buf_set_lines(component_state.buf, 0, -1, false, { "" })
    api.nvim_buf_set_option(component_state.buf, "modifiable", true)

    M.trigger_search()
    return true
  end

  return false
end

function M.navigate_to_first_result()
  if not M.isValid() then
    return
  end

  vim.cmd("stopinsert")

  api.nvim_exec_autocmds("User", {
    pattern = "PackageUISearchNavigate",
    data = {},
  })
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

function M.clear()
  if component_state.search_timer then
    component_state.search_timer:stop()
    component_state.search_timer = nil
  end

  component_state.win = nil
  component_state.buf = nil
end

return M
