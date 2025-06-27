local base_service = require("package-ui.services.python.base_service")
local M = {}

-- Inherit all base functionality
for k, v in pairs(base_service) do
  M[k] = v
end

local function get_packages_with_latest_versions_async(packages, callback)
  if #packages == 0 then
    vim.schedule(function()
      callback(packages)
    end)
    return
  end

  local completed = 0
  local total = #packages

  for i, package in ipairs(packages) do
    M.get_package_latest_version_async(package.name, function(latest_version)
      if latest_version and latest_version ~= package.version then
        package.has_update = true
        package.latest_version = latest_version
      end

      completed = completed + 1
      if completed >= total then
        vim.schedule(function()
          callback(packages)
        end)
      end
    end)
  end
end

local function parse_pipfile_packages(pipfile_path)
  local packages = {}
  local file = io.open(pipfile_path, "r")
  if not file then
    return packages
  end

  local content = file:read("*a")
  file:close()

  local in_packages_section = false
  local in_dev_packages_section = false

  for line in content:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "") -- trim whitespace

    if line == "[packages]" then
      in_packages_section = true
      in_dev_packages_section = false
    elseif line == "[dev-packages]" then
      in_packages_section = false
      in_dev_packages_section = true
    elseif line:match("^%[") then
      in_packages_section = false
      in_dev_packages_section = false
    elseif in_packages_section and line ~= "" and not line:match("^#") then
      -- Parse package lines like: package = "version" or package = "*"
      local name, version = line:match("^([%w%-_]+)%s*=%s*[\"']([^\"']*)[\"']")
      if name and version then
        if version == "*" then
          version = nil -- Will be filled by pipenv list
        end
        table.insert(packages, { name = name, version = version })
      else
        -- Handle complex package specs like: package = {version = ">=1.0", extras = ["dev"]}
        name = line:match("^([%w%-_]+)%s*=%s*{")
        if name then
          table.insert(packages, { name = name, version = nil })
        end
      end
    end
  end

  return packages
end

local function get_installed_versions_async(pipfile_packages, callback)
  local pipenv_cmd = { "pipenv", "run", "pip", "list", "--format=freeze" }
  local pipenv_output = {}

  vim.fn.jobstart(pipenv_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(pipenv_output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local installed_versions = {}

        if exit_code == 0 then
          for _, line in ipairs(pipenv_output) do
            local name, version = line:match("^([^=]+)==([^%s]+)")
            if name and version then
              installed_versions[name:lower()] = version
            end
          end
        end

        -- Match pipfile packages with installed versions
        local packages = {}
        for _, pkg in ipairs(pipfile_packages) do
          local installed_version = installed_versions[pkg.name:lower()]
          if installed_version then
            table.insert(packages, {
              name = pkg.name,
              version = installed_version,
              has_update = false,
              latest_version = nil,
            })
          end
        end

        callback(packages)
      end)
    end,
  })
end

function M.get_installed_packages_with_updates_async(callback)
  local pipfile_path = vim.fn.getcwd() .. "/Pipfile"

  local file = io.open(pipfile_path, "r")
  if not file then
    vim.schedule(function()
      callback({})
    end)
    return
  end
  file:close()

  local pipfile_packages = parse_pipfile_packages(pipfile_path)

  if #pipfile_packages == 0 then
    vim.schedule(function()
      callback({})
    end)
    return
  end

  get_installed_versions_async(pipfile_packages, function(packages)
    if #packages > 0 then
      get_packages_with_latest_versions_async(packages, callback)
    else
      callback(packages)
    end
  end)
end

function M.install_package_async(package_name, version, callback)
  vim.schedule(function()
    local package_spec = version and (package_name .. "==" .. version) or package_name
    local pipenv_cmd = { "pipenv", "install", package_spec }
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(pipenv_cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stdout_output, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(error_output, line)
            end
          end
        end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if exit_code == 0 then
            callback(true, "Package " .. package_name .. " installed successfully with Pipenv")
          else
            local error_msg = "Failed to install " .. package_name .. " with Pipenv"
            if #error_output > 0 then
              error_msg = error_msg .. ":\n" .. table.concat(error_output, "\n")
            end
            callback(false, error_msg)
          end
        end)
      end,
    })
  end)
end

function M.uninstall_package_async(package_name, callback)
  vim.schedule(function()
    local pipenv_cmd = { "pipenv", "uninstall", package_name }
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(pipenv_cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(stdout_output, line)
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(error_output, line)
            end
          end
        end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if exit_code == 0 then
            callback(true, "Package " .. package_name .. " uninstalled successfully with Pipenv")
          else
            local error_msg = "Failed to uninstall " .. package_name .. " with Pipenv"
            if #error_output > 0 then
              error_msg = error_msg .. ":\n" .. table.concat(error_output, "\n")
            end
            callback(false, error_msg)
          end
        end)
      end,
    })
  end)
end

return M

