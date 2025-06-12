local M = {}
local api = vim.api

local search_component = require("package-ui.ui.search_component")
local installed_package_component = require("package-ui.ui.installed_package_component")
local available_package_component = require("package-ui.ui.available_package_component")
local versions_component = require("package-ui.ui.versions_component")
local package_details_component = require("package-ui.ui.package_details_component")
local backdrop_component = require("package-ui.ui.backdrop_component")

local backdrop_window = nil
local windows = {}
local event_group = nil

local function calculate_layout()
  local screen_width = api.nvim_get_option("columns")
  local screen_height = api.nvim_get_option("lines")

  local search_height = 1
  local gap = 3
  local column_gap = 4

  -- Total layout width is 80% of screen
  local total_width = math.ceil(screen_width * 0.8)
  local column_width = math.ceil((total_width - column_gap) / 2)

  -- Define a fixed total height for the columns, e.g., 80% of screen height
  local total_column_height = math.floor(screen_height * 0.8)

  -- Center the entire layout block
  local start_row = math.ceil((screen_height - total_column_height) / 2)
  local start_col = math.ceil((screen_width - total_width) / 2)

  -- Calculate heights to ensure both columns have equal total height
  -- Both columns should end at: start_row + total_column_height

  -- Right column: versions + gap + details = total_column_height
  local right_content_h = total_column_height - gap       -- Total height minus the gap between versions/details
  local versions_height = math.floor(right_content_h * 0.4)
  local details_height = right_content_h - versions_height -- Give remainder to details

  -- Left column: search + gap + installed + gap + available = total_column_height
  -- So: installed + available = total_column_height - search_height - 2*gap
  local left_content_h = total_column_height - search_height - (2 * gap) -- Available space after search and gaps
  local left_window_height = math.floor(left_content_h / 2)             -- Split evenly between installed and available

  -- Ensure any remainder goes to the available window to match total height exactly
  local left_window_height_remainder = left_content_h - (2 * left_window_height)
  local available_window_height = left_window_height + left_window_height_remainder

  -- Column X positions
  local left_col = start_col
  local right_col = start_col + column_width + column_gap

  return {
    column_width = column_width,
    search_height = search_height,
    left_window_height = left_window_height,
    available_window_height = available_window_height,
    versions_height = versions_height,
    details_height = details_height,

    -- First column (left): search, installed, available
    search_row = start_row,
    search_col = left_col,
    installed_row = start_row + search_height + gap,
    installed_col = left_col,
    available_row = start_row + search_height + gap + left_window_height + gap,
    available_col = left_col,

    -- Second column (right): versions (aligned with search), details
    versions_row = start_row, -- ALIGNED with search_row
    versions_col = right_col,
    details_row = start_row + versions_height + gap,
    details_col = right_col,
  }
end

local function create_backdrop_window()
  backdrop_window = backdrop_component.create()
  return backdrop_window
end

local function update_window_focus()
  local current_win = api.nvim_get_current_win()

  -- Update all windows - unfocus all first
  for _, window in ipairs(windows) do
    if window.win and api.nvim_win_is_valid(window.win) then
      if window.win == current_win then
        -- Focused window - bright border
        api.nvim_win_set_option(
          window.win,
          "winhl",
          "Normal:PackageUiNormal,FloatBorder:PackageUiFocusedBorder"
        )
      else
        -- Unfocused window - dim border
        api.nvim_win_set_option(
          window.win,
          "winhl",
          "Normal:PackageUiNormal,FloatBorder:PackageUiUnfocusedBorder"
        )
      end
    end
  end
end

local function setup_navigation_keys(buf)
  -- Tab to navigate to next window
  api.nvim_buf_set_keymap(buf, "n", "<Tab>", "", {
    callback = function()
      api.nvim_exec_autocmds("User", { pattern = "PackageUINavigateNext" })
    end,
    desc = "Navigate to next window",
  })

  api.nvim_buf_set_keymap(buf, "n", "<S-Tab>", "", {
    callback = function()
      api.nvim_exec_autocmds("User", { pattern = "PackageUINavigatePrevious" })
    end,
    desc = "Navigate to previous window",
  })

  api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
    callback = function()
      api.nvim_exec_autocmds("User", { pattern = "PackageUIClose" })
    end,
    desc = "Close Package UI",
  })
end

local function create_search_window()
  local layout = calculate_layout()
  local search_window =
      search_component.create(layout.search_height, layout.column_width, layout.search_row, layout.search_col)

  setup_navigation_keys(search_window.buf)

  table.insert(windows, {
    name = "search",
    win = search_window.win,
    buf = search_window.buf,
    order = 1,
  })

  return search_window
end

local function create_installed_package_window()
  local layout = calculate_layout()
  local installed_window = installed_package_component.create(
    layout.left_window_height,
    layout.column_width,
    layout.installed_row,
    layout.installed_col
  )

  setup_navigation_keys(installed_window.buf)

  table.insert(windows, {
    name = "installed",
    win = installed_window.win,
    buf = installed_window.buf,
    order = 2,
  })

  return installed_window
end

local function create_versions_window()
  local layout = calculate_layout()
  local versions_window =
      versions_component.create(layout.versions_height, layout.column_width, layout.versions_row, layout.versions_col)

  setup_navigation_keys(versions_window.buf)

  table.insert(windows, {
    name = "versions",
    win = versions_window.win,
    buf = versions_window.buf,
    order = 4,
  })

  return versions_window
end

local function create_available_package_window()
  local layout = calculate_layout()
  local available_window = available_package_component.create(
    layout.available_window_height,
    layout.column_width,
    layout.available_row,
    layout.available_col
  )

  setup_navigation_keys(available_window.buf)

  table.insert(windows, {
    name = "available",
    win = available_window.win,
    buf = available_window.buf,
    order = 3,
  })

  return available_window
end

local function create_package_details_window()
  local layout = calculate_layout()
  local details_window = package_details_component.create(
    layout.details_height,
    layout.column_width,
    layout.details_row,
    layout.details_col
  )

  setup_navigation_keys(details_window.buf)

  table.insert(windows, {
    name = "package_details",
    win = details_window.win,
    buf = details_window.buf,
    order = 5,
  })

  return details_window
end

local function setup_event_listeners()
  event_group = api.nvim_create_augroup("PackageUINavigation", { clear = true })

  api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "PackageUINavigateNext",
    callback = function()
      M.switch_to_next()
    end,
  })

  api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "PackageUINavigatePrevious",
    callback = function()
      M.switch_to_previous()
    end,
  })

  api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "PackageUIClose",
    callback = function()
      M.close_all_windows()
    end,
  })
end

function M.get_current_window_index()
  local current_win = api.nvim_get_current_win()
  for i, window in ipairs(windows) do
    if window.win == current_win then
      return i
    end
  end
  return nil
end

function M.switch_to_next()
  local current_index = M.get_current_window_index()
  if not current_index then
    return false
  end

  local next_index = current_index + 1
  if next_index > #windows then
    next_index = 1
  end

  local target_window = windows[next_index]
  if target_window and target_window.win and api.nvim_win_is_valid(target_window.win) then
    api.nvim_set_current_win(target_window.win)
    update_window_focus()
    return true
  end
  return false
end

function M.switch_to_previous()
  local current_index = M.get_current_window_index()
  if not current_index then
    return false
  end

  local prev_index = current_index - 1
  if prev_index < 1 then
    prev_index = #windows
  end

  local target_window = windows[prev_index]
  if target_window and target_window.win and api.nvim_win_is_valid(target_window.win) then
    api.nvim_set_current_win(target_window.win)
    update_window_focus()
    return true
  end
  return false
end

function M.switch_to_window(name)
  for _, window in ipairs(windows) do
    if window.name == name and window.win and api.nvim_win_is_valid(window.win) then
      api.nvim_set_current_win(window.win)
      update_window_focus()
      return true
    end
  end
  return false
end

function M.get_windows()
  return windows
end

function M.close_all_windows()
  if backdrop_window and backdrop_window.win and api.nvim_win_is_valid(backdrop_window.win) then
    api.nvim_win_close(backdrop_window.win, true)
  end

  for _, window in ipairs(windows) do
    if window.win and api.nvim_win_is_valid(window.win) then
      api.nvim_win_close(window.win, true)
    end
  end

  windows = {}
  backdrop_window = nil

  installed_package_component.clear()
  available_package_component.clear()
  versions_component.clear()
  package_details_component.clear()
  search_component.clear()

  if event_group then
    api.nvim_del_augroup_by_id(event_group)
    event_group = nil
  end
end

function M.setup()
  windows = {}

  setup_event_listeners()

  create_backdrop_window()
  create_installed_package_window()
  create_versions_window()
  create_available_package_window()
  create_package_details_window()
  create_search_window() -- Created last to get focus

  table.sort(windows, function(a, b)
    return a.order < b.order
  end)

  update_window_focus()
end

return M
