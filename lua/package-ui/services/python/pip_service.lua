local base_service = require("package-ui.services.python.base_service")
local M = {}

-- Inherit all base functionality
for k, v in pairs(base_service) do
  M[k] = v
end

local function read_requirements_file()
  local req_files = { "requirements.txt", "requirements/base.txt", "requirements/common.txt" }

  for _, req_file in ipairs(req_files) do
    local full_path = vim.fn.getcwd() .. "/" .. req_file
    if vim.fn.filereadable(full_path) == 1 then
      local lines = {}
      for line in io.lines(full_path) do
        table.insert(lines, line)
      end
      return lines, req_file, nil
    end
  end

  return nil, nil, "requirements.txt not found"
end

local function write_requirements_file(lines, filename)
  local req_file = vim.fn.getcwd() .. "/" .. (filename or "requirements.txt")
  local file = io.open(req_file, "w")
  if not file then
    return false, "Could not open " .. (filename or "requirements.txt") .. " for writing"
  end

  for _, line in ipairs(lines) do
    file:write(line .. "\n")
  end
  file:close()
  return true, nil
end

local function package_exists_in_requirements(lines, package_name)
  for i, line in ipairs(lines) do
    if line:match("^" .. package_name .. "[=<>!]") or line:match("^" .. package_name .. "$") then
      return true, i
    end
  end
  return false, nil
end

local function parse_pip_list_line(line)
  local name, version = line:match("^([^%s]+)%s+([^%s]+)")
  if name and version then
    return {
      name = name,
      version = version,
      has_update = false,
      latest_version = nil,
    }
  end
  return nil
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

function M.get_installed_packages_with_updates_async(callback)
  local req_lines, filename, err = read_requirements_file()

  if req_lines then
    local pip_base_cmd = M.get_pip_command()
    if not pip_base_cmd then
      vim.schedule(function()
        callback({})
      end)
      return
    end

    local pip_cmd = vim.deepcopy(pip_base_cmd)
    vim.list_extend(pip_cmd, { "list", "--format=columns" })
    local pip_output = {}

    vim.fn.jobstart(pip_cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(pip_output, line)
            end
          end
        end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          -- Get all installed packages
          local installed_packages = {}
          if exit_code == 0 then
            for i, line in ipairs(pip_output) do
              if i > 2 and line ~= "" and not line:match("^%-+") then
                local pkg = parse_pip_list_line(line)
                if pkg then
                  installed_packages[string.lower(pkg.name)] = pkg
                end
              end
            end
          end

          local packages = {}
          for _, line in ipairs(req_lines) do
            if line and line ~= "" and not line:match("^#") and not line:match("^%s*$") then
              local req_pkg = M.parse_package(line)
              if req_pkg and req_pkg.name then
                local installed_pkg = installed_packages[string.lower(req_pkg.name)]
                if installed_pkg then
                  table.insert(packages, {
                    name = installed_pkg.name,
                    version = installed_pkg.version,
                    has_update = false,
                    latest_version = nil,
                  })
                end
              end
            end
          end

          if #packages > 0 then
            get_packages_with_latest_versions_async(packages, callback)
          else
            callback({}) -- No packages from requirements.txt are installed
          end
        end)
      end,
    })
  else
    local pip_base_cmd = M.get_pip_command()
    if not pip_base_cmd then
      vim.schedule(function()
        callback({})
      end)
      return
    end

    local pip_cmd = vim.deepcopy(pip_base_cmd)
    vim.list_extend(pip_cmd, { "list", "--format=columns" })
    local pip_output = {}

    vim.fn.jobstart(pip_cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              table.insert(pip_output, line)
            end
          end
        end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          local packages = {}

          if exit_code == 0 then
            -- Skip header lines
            for i, line in ipairs(pip_output) do
              if i > 2 and line ~= "" and not line:match("^%-+") then
                local pkg = parse_pip_list_line(line)
                if pkg then
                  table.insert(packages, pkg)
                end
              end
            end
          end

          get_packages_with_latest_versions_async(packages, callback)
        end)
      end,
    })
  end
end

function M.install_package_async(package_name, version, callback)
  vim.schedule(function()
    local lines, filename, err = read_requirements_file()
    local update_requirements = lines ~= nil

    if not lines then
      lines = {}
      filename = "requirements.txt"
    end

    local version_spec
    if version then
      version_spec = "==" .. version
    else
      version_spec = ""
    end

    local package_spec = package_name .. version_spec
    local exists, line_num = package_exists_in_requirements(lines, package_name)

    if exists then
      lines[line_num] = package_spec
    else
      table.insert(lines, package_spec)
    end

    local pip_base_cmd = M.get_pip_command()
    if not pip_base_cmd then
      callback(false, "pip command not found. Please install pip or ensure it's in your PATH.")
      return
    end

    local pip_cmd = vim.deepcopy(pip_base_cmd)
    vim.list_extend(pip_cmd, { "install", package_spec })
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(pip_cmd, {
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
            if update_requirements then
              local success, write_err = write_requirements_file(lines, filename)
              if not success then
                callback(
                  true,
                  "Package "
                  .. package_name
                  .. " installed successfully, but failed to update "
                  .. filename
                )
                return
              end
            end

            local action = exists and "upgraded" or "installed"
            callback(true, "Package " .. package_name .. " " .. action .. " successfully")
          else
            local error_msg = "Failed to install " .. package_name
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
    local lines, filename, err = read_requirements_file()
    local update_requirements = lines ~= nil

    local pip_base_cmd = M.get_pip_command()
    if not pip_base_cmd then
      callback(false, "pip command not found. Please install pip or ensure it's in your PATH.")
      return
    end

    local pip_cmd = vim.deepcopy(pip_base_cmd)
    vim.list_extend(pip_cmd, { "uninstall", package_name, "-y" })
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(pip_cmd, {
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
            if update_requirements then
              local exists, line_num = package_exists_in_requirements(lines, package_name)
              if exists then
                table.remove(lines, line_num)
                local success, write_err = write_requirements_file(lines, filename)
                if not success then
                  callback(
                    true,
                    "Package "
                    .. package_name
                    .. " uninstalled successfully, but failed to update "
                    .. filename
                  )
                  return
                end
              end
            end

            callback(true, "Package " .. package_name .. " uninstalled successfully")
          else
            local error_msg = "Failed to uninstall " .. package_name
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

