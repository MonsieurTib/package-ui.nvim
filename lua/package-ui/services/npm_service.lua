local M = {}
local current_search_job = nil

function M.parse_package(raw_string)
  if not raw_string or raw_string == "" then
    return nil
  end

  if
      raw_string:match("^%s*No ")
      or raw_string:match("^%s*Type ")
      or raw_string:match("^%s*Check ")
      or raw_string:match("^%s*Searching ")
      or raw_string:match("^%s*Run ")
      or raw_string:match("^%s*loading")
      or raw_string:match("^%s*Select ")
      or raw_string:match("^%s*Loading ")
      or raw_string:match("^%s*Failed ")
  then
    return nil
  end

  local clean_line = raw_string:gsub("%s*→.*$", ""):gsub("%s+$", "")

  local last_at_pos = clean_line:find("@[^@]*$")
  if last_at_pos then
    local package_name = clean_line:sub(1, last_at_pos - 1):gsub("^%s+", ""):gsub("%s+$", "")
    local version = clean_line:sub(last_at_pos + 1):gsub("^%s+", ""):gsub("%s+$", "")

    if package_name and package_name ~= "" and version and version ~= "" then
      return {
        name = package_name,
        version = version,
      }
    end
  end

  return nil
end

function M.search_packages_async(query, callback)
  if current_search_job and current_search_job > 0 then
    vim.fn.jobstop(current_search_job)
    current_search_job = nil
  end

  if not query or query == "" then
    callback({})
    return
  end

  local cmd = { "npm", "search", query, "--json", "--searchlimit", "50" }
  local output = {}

  current_search_job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        current_search_job = nil

        if exit_code ~= 0 then
          callback({})
          return
        end

        local result = table.concat(output, "\n")
        local packages = {}

        if result and result ~= "" then
          result = result:gsub("%s+$", "")

          local success, data = pcall(vim.fn.json_decode, result)
          if success and data and type(data) == "table" then
            local count = 0
            for _, pkg in ipairs(data) do
              if count >= 50 then
                break
              end

              local package_entry = {
                name = pkg.name or "unknown",
                version = pkg.version or "latest",
                description = pkg.description or "",
                author = pkg.publisher and pkg.publisher.username
                    or pkg.maintainers and pkg.maintainers[1] and pkg.maintainers[1].username
                    or "unknown",
                type = "available",
              }

              table.insert(packages, package_entry)
              count = count + 1
            end
          end
        end

        callback(packages)
      end)
    end,
  })

  if current_search_job <= 0 then
    current_search_job = nil
    callback({})
  end
end

function M.get_package_details_async(package_name, callback, version)
  if not package_name or package_name == "" then
    callback(nil)
    return
  end

  local package_spec = version and string.format("%s@%s", package_name, version) or package_name
  local cmd = { "npm", "view", package_spec, "--json" }
  local output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          callback(nil)
          return
        end

        local result = table.concat(output, "\n")

        if result and result ~= "" then
          local success, data = pcall(vim.fn.json_decode, result)
          if success and data then
            local package_info = {
              fields = {
                { type = "simple",    label = "Name",        value = data.name or package_name },
                { type = "simple",    label = "Version",     value = data.version or version or "unknown" },
                { type = "multiline", label = "Description", value = data.description or "" },
                { type = "simple",    label = "Author",      value = data.author and data.author.name or "" },
                { type = "simple",    label = "License",     value = data.license or "" },
                { type = "simple",    label = "Homepage",    value = data.homepage or "" },
                {
                  type = "simple",
                  label = "Repository",
                  value = data.repository and data.repository.url or "",
                },
                { type = "keywords",     label = "Keywords",     value = data.keywords or {} },
                { type = "dependencies", label = "Dependencies", value = data.dependencies or {} },
                {
                  type = "dependencies",
                  label = "Dev Dependencies",
                  value = data.devDependencies or {},
                },
              },
            }
            callback(package_info)
          else
            callback(nil)
          end
        else
          callback(nil)
        end
      end)
    end,
  })
end

function M.get_package_versions_async(package_name, callback)
  if not package_name or package_name == "" then
    callback({})
    return
  end

  local cmd = { "npm", "view", package_name, "versions", "--json" }
  local output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local versions = {}

        if exit_code == 0 then
          local result = table.concat(output, "\n")

          if result and result ~= "" then
            local success, data = pcall(vim.fn.json_decode, result)
            if success and data then
              if type(data) == "table" then
                for i = #data, 1, -1 do
                  table.insert(versions, {
                    version = data[i],
                    package_name = package_name,
                  })
                end
              else
                table.insert(versions, {
                  version = data,
                  package_name = package_name,
                })
              end
            end
          end
        end

        callback(versions)
      end)
    end,
  })
end

function M.get_installed_packages_with_updates_async(callback)
  local cmd = { "npm", "list", "--depth=0", "--json" }
  local output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local packages = {}

        if exit_code == 0 then
          local result = table.concat(output, "\n")

          if result and result ~= "" then
            local success, data = pcall(vim.fn.json_decode, result)
            if success and data and data.dependencies then
              local remaining_checks = 0
              local total_packages = 0

              for _ in pairs(data.dependencies) do
                total_packages = total_packages + 1
              end

              if total_packages == 0 then
                callback(packages)
                return
              end

              remaining_checks = total_packages

              for name, info in pairs(data.dependencies) do
                local pkg = {
                  name = name,
                  version = info.version or "unknown",
                  description = info.description or "",
                  type = "dependency",
                  has_update = false,
                  latest_version = nil,
                }

                local update_cmd = { "npm", "view", name, "version" }
                vim.fn.jobstart(update_cmd, {
                  stdout_buffered = true,
                  on_stdout = function(_, update_data)
                    if update_data and update_data[1] and update_data[1] ~= "" then
                      local latest_version = update_data[1]:gsub("%s+", "")
                      pkg.latest_version = latest_version

                      if latest_version ~= pkg.version then
                        pkg.has_update = true
                      end
                    end
                  end,
                  on_exit = function()
                    table.insert(packages, pkg)
                    remaining_checks = remaining_checks - 1

                    if remaining_checks == 0 then
                      vim.schedule(function()
                        callback(packages)
                      end)
                    end
                  end,
                })
              end
            else
              callback(packages)
            end
          else
            callback(packages)
          end
        else
          callback(packages)
        end
      end)
    end,
  })
end

function M.uninstall_package_async(package_name, callback)
  if not package_name or package_name == "" then
    callback(false, "Invalid package name")
    return
  end

  local cmd = { "npm", "uninstall", package_name }
  local output = {}
  local error_output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
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
          callback(true, "Package uninstalled successfully")
        else
          local error_msg = #error_output > 0 and table.concat(error_output, "\n") or "Unknown error"
          callback(false, error_msg)
        end
      end)
    end,
  })
end

function M.install_package_async(package_name, version, callback)
  if not package_name or package_name == "" then
    callback(false, "Invalid package name")
    return
  end

  local package_spec = version and string.format("%s@%s", package_name, version) or package_name
  local cmd = { "npm", "install", package_spec }
  local output = {}
  local error_output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
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
          callback(true, "Package installed successfully")
        else
          local error_msg = #error_output > 0 and table.concat(error_output, "\n") or "Unknown error"
          callback(false, error_msg)
        end
      end)
    end,
  })
end

return M
