local M = {}

local layout = require("package-ui.ui.layout")
local installed_package_component = require("package-ui.ui.installed_package_component")
local available_package_component = require("package-ui.ui.available_package_component")
local versions_component = require("package-ui.ui.versions_component")
local package_details_component = require("package-ui.ui.package_details_component")
local search_component = require("package-ui.ui.search_component")
local npm_service = require("package-ui.services.npm_service")
local cargo_service = require("package-ui.services.cargo_service")
local gem_service = require("package-ui.services.gem_service")

local current_package_manager = nil
local installed_packages_cache = {}
local current_versions_request = nil
local current_details_request = nil

local package_manager_services = {
  npm = npm_service,
  cargo = cargo_service,
  gem = gem_service,
}

local function detect_package_manager()
  local cwd = vim.fn.getcwd()

  if vim.fn.filereadable(cwd .. "/package.json") == 1 then
    return "npm"
  elseif vim.fn.filereadable(cwd .. "/Cargo.toml") == 1 then
    return "cargo"
  elseif vim.fn.filereadable(cwd .. "/Gemfile") == 1 then
    return "gem"
  end

  return nil
end

local function get_package_service()
  if current_package_manager then
    return package_manager_services[current_package_manager]
  end
  return nil
end

local function filter_installed_packages(search_term)
  if not search_term or search_term == "" then
    local lines = {}
    if #installed_packages_cache == 0 then
      table.insert(lines, string.format("No %s packages found", current_package_manager or ""))
    else
      for _, pkg in ipairs(installed_packages_cache) do
        local line = string.format("%s@%s", pkg.name, pkg.version)
        if pkg.has_update and pkg.latest_version then
          line = line .. string.format(" → %s", pkg.latest_version)
        end
        table.insert(lines, line)
      end
    end
    installed_package_component.updateContent(lines)
    return
  end

  local filtered_packages = {}
  local search_lower = string.lower(search_term)

  for _, pkg in ipairs(installed_packages_cache) do
    if string.find(string.lower(pkg.name), search_lower, 1, true) then
      local line = string.format("%s@%s", pkg.name, pkg.version)
      if pkg.has_update and pkg.latest_version then
        line = line .. string.format(" → %s", pkg.latest_version)
      end
      table.insert(filtered_packages, line)
    end
  end

  if #filtered_packages == 0 then
    installed_package_component.updateContent({
      string.format("No installed packages found matching '%s'", search_term),
    })
  else
    installed_package_component.updateContent(filtered_packages)
  end
end

local function search_package_registry(search_term)
  if not search_term or search_term == "" then
    available_package_component.updateContent({
      string.format("Type to search %s packages...", current_package_manager or ""),
    })
    return
  end

  if not current_package_manager then
    available_package_component.updateContent({ "No package manager detected" })
    return
  end

  local service = get_package_service()
  if not service then
    available_package_component.updateContent({ "Package service not available" })
    return
  end

  available_package_component.updateContent({
    string.format("Searching %s registry...", current_package_manager),
  })

  service.search_packages_async(search_term, function(packages)
    local lines = {}

    if #packages == 0 then
      table.insert(
        lines,
        string.format("No %s packages found matching '%s'", current_package_manager, search_term)
      )
      table.insert(lines, "Check your search term or try a different query")
    else
      for _, pkg in ipairs(packages) do
        local line = string.format("%s@%s", pkg.name, pkg.version)
        table.insert(lines, line)

        if #lines >= 50 then
          break
        end
      end
    end

    available_package_component.updateContent(lines)
  end)
end

local function load_package_versions(package_name)
  if not package_name or package_name == "" then
    current_versions_request = nil
    versions_component.updateContent({ "Select a package to view versions" })
    return
  end

  if not current_package_manager then
    current_versions_request = nil
    versions_component.updateContent({ "No package manager detected" })
    return
  end

  local service = get_package_service()
  if not service then
    current_versions_request = nil
    versions_component.updateContent({ "Package service not available" })
    return
  end

  -- Generate unique request ID to prevent race conditions
  local request_id = package_name .. "_" .. os.time() .. "_" .. math.random(1000)
  current_versions_request = request_id

  versions_component.updateContent({ string.format("Loading %s versions...", package_name) })
  versions_component.setCurrentPackage(package_name)

  service.get_package_versions_async(package_name, function(versions)
    -- Check if this is still the current request (prevent race condition)
    if current_versions_request ~= request_id then
      return -- Ignore stale response
    end

    local lines = {}

    if #versions == 0 then
      table.insert(lines, string.format("No versions found for %s", package_name))
    else
      for _, version_info in ipairs(versions) do
        table.insert(lines, version_info.version)
      end
    end

    versions_component.updateContent(lines)
  end)
end

local function load_package_details(package_name, version)
  if not package_name or package_name == "" then
    current_details_request = nil
    package_details_component.updateContent({ "Select a package to view details" })
    return
  end

  if not current_package_manager then
    current_details_request = nil
    package_details_component.updateContent({ "No package manager detected" })
    return
  end

  local service = get_package_service()
  if not service then
    current_details_request = nil
    package_details_component.updateContent({ "Package service not available" })
    return
  end

  local request_spec = version and (package_name .. "@" .. version) or package_name
  local request_id = request_spec .. "_" .. os.time() .. "_" .. math.random(1000)
  current_details_request = request_id

  local loading_text = version and string.format("Loading %s@%s details...", package_name, version)
      or string.format("Loading %s details...", package_name)
  package_details_component.updateContent({ loading_text })

  service.get_package_details_async(package_name, function(details)
    if current_details_request ~= request_id then
      return
    end

    if details then
      package_details_component.updateWithPackageDetails(details)
    else
      local error_text = version and string.format("Failed to load details for %s@%s", package_name, version)
          or string.format("Failed to load details for %s", package_name)
      package_details_component.updateContent({
        error_text,
        "Package may not exist or network error occurred",
      })
    end
  end, version)
end

local function populate_installed_packages(callback)
  if not installed_package_component.isValid() then
    if callback then
      callback()
    end
    return
  end

  installed_package_component.updateContent({ "loading packages..." })

  if not current_package_manager then
    local lines = {
      "No package manager detected",
      "",
      "Supported package managers:",
      "• npm (package.json)",
      "• Cargo (Cargo.toml)",
      "• Go modules (go.mod) - coming soon",
      "• Maven (pom.xml) - coming soon",
    }
    installed_package_component.updateContent(lines)
    available_package_component.updateContent({ "No package manager detected" })
    versions_component.updateContent({ "No package manager detected" })
    package_details_component.updateContent({ "No package manager detected" })
    if callback then
      callback()
    end
    return
  end

  local service = get_package_service()
  if not service then
    installed_package_component.updateContent({
      string.format("Service not available for %s", current_package_manager),
    })
    available_package_component.updateContent({ "Package service not available" })
    versions_component.updateContent({ "Package service not available" })
    package_details_component.updateContent({ "Package service not available" })
    if callback then
      callback()
    end
    return
  end

  service.get_installed_packages_with_updates_async(function(packages)
    installed_packages_cache = packages

    local lines = {}

    if #packages == 0 then
      table.insert(lines, string.format("No %s packages found", current_package_manager))
    else
      for _, pkg in ipairs(packages) do
        local line = string.format("%s@%s", pkg.name, pkg.version)
        if pkg.has_update and pkg.latest_version then
          line = line .. string.format(" → %s", pkg.latest_version)
        end
        table.insert(lines, line)
      end
    end

    installed_package_component.updateContent(lines)

    available_package_component.updateContent({
      string.format("Type to search %s packages...", current_package_manager),
    })

    versions_component.updateContent({ "Select a package to view versions" })
    package_details_component.updateContent({ "Select a package to view details" })

    if callback then
      callback()
    end
  end)
end

local function uninstall_package(package_name)
  if not current_package_manager then
    return
  end

  local service = get_package_service()
  if not service or not service.uninstall_package_async then
    return
  end

  installed_package_component.updateContent({
    string.format("Uninstalling %s...", package_name),
    "Please wait...",
  })

  service.uninstall_package_async(package_name, function(success, message)
    if success then
      populate_installed_packages()
    else
      installed_package_component.updateContent({
        string.format("Failed to uninstall %s", package_name),
        message or "Unknown error occurred",
      })

      vim.defer_fn(function()
        populate_installed_packages()
      end, 2000)
    end
  end)
end

local function install_package(package_name, version)
  if not current_package_manager then
    return
  end

  local service = get_package_service()
  if not service or not service.install_package_async then
    return
  end

  local package_spec = string.format("%s@%s", package_name, version)
  installed_package_component.updateContent({
    string.format("Installing %s...", package_spec),
    "Please wait...",
  })

  service.install_package_async(package_name, version, function(success, message)
    if success then
      search_component.reset()

      populate_installed_packages(function()
        local layout = require("package-ui.ui.layout")
        layout.switch_to_window("installed")

        if installed_package_component.isValid() then
          local win = installed_package_component.getWindow()
          vim.api.nvim_win_set_option(win, "number", false)
          vim.api.nvim_win_set_option(win, "relativenumber", false)
        end

        installed_package_component.selectPackage(package_name)
      end)
    else
      installed_package_component.updateContent({
        string.format("Failed to install %s", package_spec),
        message or "Unknown error occurred",
      })

      vim.defer_fn(function()
        populate_installed_packages()
      end, 2000)
    end
  end)
end

local function navigate_to_versions(package_name, installed_version)
  local layout = require("package-ui.ui.layout")
  layout.switch_to_window("versions")

  if versions_component.isValid() then
    local win = versions_component.getWindow()
    vim.api.nvim_win_set_option(win, "number", false)
    vim.api.nvim_win_set_option(win, "relativenumber", false)
  end

  if installed_version then
    versions_component.selectVersion(installed_version)
  end
end

local function setup_search_listener()
  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUISearch",
    callback = function(event)
      local search_term = event.data and event.data.search_term or ""
      filter_installed_packages(search_term)
      search_package_registry(search_term)
    end,
  })
end

local function setup_package_selection_listener()
  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUIPackageSelected",
    callback = function(event)
      local package_line = event.data and event.data.package_line
      local source = event.data and event.data.source

      if package_line then
        local service = get_package_service()
        if service and service.parse_package then
          local package_info = service.parse_package(package_line)
          if package_info and package_info.name then
            load_package_versions(package_info.name)
            load_package_details(package_info.name)
          end
        end
      end
    end,
  })
end

local function setup_version_selection_listener()
  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUIVersionSelected",
    callback = function(event)
      local package_name = event.data and event.data.package_name
      local version = event.data and event.data.version

      if package_name and version then
        load_package_details(package_name, version)
      end
    end,
  })
end

local function setup_package_actions_listeners()
  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUIUninstallPackage",
    callback = function(event)
      local package_line = event.data and event.data.package_line

      if package_line then
        local service = get_package_service()
        if service and service.parse_package then
          local package_info = service.parse_package(package_line)
          if package_info and package_info.name then
            uninstall_package(package_info.name)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUIInstallPackage",
    callback = function(event)
      local package_name = event.data and event.data.package_name
      local version = event.data and event.data.version

      if package_name and version then
        install_package(package_name, version)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUINavigateToVersions",
    callback = function(event)
      local package_line = event.data and event.data.package_line

      if package_line then
        local service = get_package_service()
        if service and service.parse_package then
          local package_info = service.parse_package(package_line)
          if package_info and package_info.name then
            navigate_to_versions(package_info.name, package_info.version)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "PackageUISearchNavigate",
    callback = function(event)
      local layout = require("package-ui.ui.layout")

      if installed_package_component.has_results() then
        layout.switch_to_window("installed")
        if installed_package_component.isValid() then
          local win = installed_package_component.getWindow()
          vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
        return
      end

      if available_package_component.has_results() then
        layout.switch_to_window("available")
        if available_package_component.isValid() then
          local win = available_package_component.getWindow()
          vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
        return
      end
    end,
  })
end

function M.setup()
  current_package_manager = detect_package_manager()

  setup_search_listener()
  setup_package_selection_listener()
  setup_version_selection_listener()
  setup_package_actions_listeners()

  layout.setup()
  if current_package_manager then
    populate_installed_packages()
  end
end

function M.get_current_package_manager()
  return current_package_manager
end

function M.get_package_service()
  return get_package_service()
end

return M
