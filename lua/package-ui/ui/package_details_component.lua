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
    title = " Package details ",
    zindex = 50,
  }

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, false, opts)

  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "filetype", "package-ui")

  api.nvim_win_set_option(win, "winhl", "Normal:PackageUiNormal")
  api.nvim_win_set_option(win, "number", false)
  api.nvim_win_set_option(win, "relativenumber", false)
  api.nvim_win_set_option(win, "cursorline", false)
  api.nvim_win_set_option(win, "signcolumn", "no")
  api.nvim_win_set_option(win, "foldcolumn", "0")

  component_state.win = win
  component_state.buf = buf

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

function M.updateContent(lines)
  if not M.isValid() then
    return false
  end

  api.nvim_buf_set_option(component_state.buf, "modifiable", true)
  api.nvim_buf_set_lines(component_state.buf, 0, -1, false, lines or {})
  api.nvim_buf_set_option(component_state.buf, "modifiable", false)

  return true
end

function M.updateWithPackageDetails(info)
  if not info then
    M.updateContent({ "Select a package to view details" })
    return
  end

  local lines = {}
  local labels = {}

  local function add_field(label, value)
    if value and value ~= "unknown" and value ~= "" then
      table.insert(lines, label .. ":")
      table.insert(labels, #lines)
      table.insert(lines, value)
      table.insert(lines, "")
    end
  end

  local function add_multiline_field(label, value, max_width)
    max_width = max_width or 45
    table.insert(lines, label .. ":")
    table.insert(labels, #lines)

    if #value > max_width then
      local words = vim.split(value, " ")
      local current_line = ""
      for _, word in ipairs(words) do
        if #current_line + #word + 1 <= max_width then
          current_line = current_line == "" and word or current_line .. " " .. word
        else
          if current_line ~= "" then
            table.insert(lines, current_line)
          end
          current_line = word
        end
      end
      if current_line ~= "" then
        table.insert(lines, current_line)
      end
    else
      table.insert(lines, value)
    end
    table.insert(lines, "")
  end

  local function add_dependencies_field(label, deps)
    if deps and type(deps) == "table" then
      local dep_count = 0
      for _ in pairs(deps) do
        dep_count = dep_count + 1
      end

      if dep_count > 0 then
        table.insert(lines, label .. ":")
        table.insert(labels, #lines)
        for name, version in pairs(deps) do
          table.insert(lines, string.format("%s: %s", name, version))
        end
        table.insert(lines, "")
      end
    end
  end

  for _, field in ipairs(info.fields or {}) do
    if field.type == "simple" then
      add_field(field.label, field.value)
    elseif field.type == "multiline" then
      if field.value and field.value ~= "" then
        add_multiline_field(field.label, field.value, field.max_width)
      end
    elseif field.type == "keywords" then
      if field.value and type(field.value) == "table" and #field.value > 0 then
        local keywords_str = table.concat(field.value, ", ")
        add_multiline_field(field.label, keywords_str, field.max_width or 43)
      end
    elseif field.type == "dependencies" then
      add_dependencies_field(field.label, field.value)
    end
  end

  M.updateContent(lines)

  if M.isValid() then
    api.nvim_buf_clear_namespace(component_state.buf, -1, 0, -1)
    for _, line_num in ipairs(labels) do
      api.nvim_buf_add_highlight(component_state.buf, -1, "PackageUiDetailLabel", line_num - 1, 0, -1)
    end
  end
end

function M.clear()
  component_state.win = nil
  component_state.buf = nil
end

return M
