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

function M.get_installed_packages_with_updates_async(callback)
  local poetry_cmd = { "poetry", "show", "--top-level" }
  local poetry_output = {}

  vim.fn.jobstart(poetry_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(poetry_output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local packages = {}

        if exit_code == 0 then
          for _, line in ipairs(poetry_output) do
            local name, version = line:match("^([^%s]+)%s+([^%s]+)")
            if name and version then
              table.insert(packages, {
                name = name,
                version = version,
                has_update = false,
                latest_version = nil,
              })
            end
          end

          if #packages > 0 then
            get_packages_with_latest_versions_async(packages, callback)
          else
            callback(packages)
          end
        else
          callback({})
        end
      end)
    end,
  })
end

function M.install_package_async(package_name, version, callback)
  vim.schedule(function()
    local version_spec = version and ("==" .. version) or ""
    local package_spec = package_name .. version_spec
    local poetry_cmd = { "poetry", "add", package_spec }
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(poetry_cmd, {
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
            callback(true, "Package " .. package_name .. " installed successfully with Poetry")
          else
            local error_msg = "Failed to install " .. package_name .. " with Poetry"
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
    local poetry_cmd = { "poetry", "remove", package_name }
    local error_output = {}
    local stdout_output = {}

    vim.fn.jobstart(poetry_cmd, {
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
            callback(true, "Package " .. package_name .. " uninstalled successfully with Poetry")
          else
            local error_msg = "Failed to uninstall " .. package_name .. " with Poetry"
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

