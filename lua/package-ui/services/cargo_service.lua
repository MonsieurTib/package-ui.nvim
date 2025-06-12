local M = {}

local CRATES_IO_API_BASE = "https://crates.io/api/v1"

local get_packages_with_latest_versions_async
local get_package_latest_version_async

function M.get_installed_packages_with_updates_async(callback)
  local cargo_path = vim.fn.getcwd() .. "/Cargo.toml"
  local success, cargo_content = pcall(vim.fn.readfile, cargo_path)
  if not success or not cargo_content then
    callback({})
    return
  end

  local packages = {}
  local in_dependencies = false
  local in_dev_dependencies = false

  for _, line in ipairs(cargo_content) do
    local trimmed = line:match("^%s*(.-)%s*$")

    if trimmed:match("^%[dependencies%]") then
      in_dependencies = true
      in_dev_dependencies = false
    elseif trimmed:match("^%[dev%-dependencies%]") then
      in_dependencies = false
      in_dev_dependencies = true
    elseif trimmed:match("^%[.*%]") then
      in_dependencies = false
      in_dev_dependencies = false
    elseif in_dependencies or in_dev_dependencies then
      -- Parse dependency lines like: serde = "1.0"
      local package_name, version = trimmed:match("^([^%s=]+)%s*=%s*[\"']([^\"']+)[\"']")
      if package_name and version then
        table.insert(packages, {
          name = package_name,
          version = version,
          description = in_dev_dependencies and "dev-dependency" or "",
          type = "dependency",
        })
      else
        -- Try to parse complex dependency format like: serde = { version = "1.0", features = ["derive"] }
        local complex_name = trimmed:match("^([^%s=]+)%s*=%s*{")
        if complex_name then
          local version_match = trimmed:match("version%s*=%s*[\"']([^\"']+)[\"']")
          if version_match then
            table.insert(packages, {
              name = complex_name,
              version = version_match,
              description = in_dev_dependencies and "dev-dependency" or "",
              type = "dependency",
            })
          end
        end
      end
    end
  end
  get_packages_with_latest_versions_async(packages, callback)
end

get_packages_with_latest_versions_async = function(packages, callback)
  if #packages == 0 then
    vim.schedule(function()
      callback(packages)
    end)
    return
  end

  local completed = 0
  local total = #packages

  for i, package in ipairs(packages) do
    get_package_latest_version_async(package.name, function(latest_version)
      if latest_version and latest_version ~= package.version then
        -- Remove version prefix like "^1.0" or "~1.0" for comparison
        local current_clean = package.version:gsub("^[%^~]", "")
        if latest_version ~= current_clean then
          package.has_update = true
          package.latest_version = latest_version
        end
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

get_package_latest_version_async = function(package_name, callback)
  local details_url = string.format("%s/crates/%s", CRATES_IO_API_BASE, package_name)

  local cmd = { "curl", "-s", details_url }
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
        local latest_version = nil

        if exit_code == 0 then
          local result = table.concat(output, "\n")
          local success, json_data = pcall(vim.fn.json_decode, result)

          if success and json_data and json_data.crate then
            latest_version = json_data.crate.newest_version
          end
        end

        callback(latest_version)
      end)
    end,
  })
end

function M.search_packages_async(query, callback)
  local search_url = string.format("%s/crates?q=%s&per_page=50", CRATES_IO_API_BASE, vim.fn.shellescape(query))

  local cmd = { "curl", "-s", search_url }
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
          local success, json_data = pcall(vim.fn.json_decode, result)

          if success and json_data and json_data.crates then
            for _, crate in ipairs(json_data.crates) do
              if crate.name and crate.newest_version then
                table.insert(packages, {
                  name = crate.name,
                  version = crate.newest_version,
                  description = crate.description or "",
                  type = "available",
                })
              end
            end
          end
        end

        callback(packages)
      end)
    end,
  })
end

function M.get_package_details_async(package_name, callback, version)
  local details_url = string.format("%s/crates/%s", CRATES_IO_API_BASE, package_name)

  local cmd = { "curl", "-s", details_url }
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
        local raw_details = {
          name = package_name,
          version = version or "unknown",
          description = "",
          author = "",
          license = "",
          repository = "",
          dependencies = {},
        }

        if exit_code == 0 then
          local result = table.concat(output, "\n")
          local success, json_data = pcall(vim.fn.json_decode, result)

          if success and json_data and json_data.crate then
            local crate = json_data.crate
            raw_details.description = (crate.description and tostring(crate.description)) or package_name
            raw_details.repository = (crate.repository and tostring(crate.repository)) or ""

            if version and json_data.versions then
              for _, version_info in ipairs(json_data.versions) do
                if version_info.num == version then
                  raw_details.version = (version_info.num and tostring(version_info.num)) or "unknown"
                  raw_details.author = (
                        version_info.authors and type(version_info.authors) == "table"
                      )
                      and table.concat(version_info.authors, ", ")
                      or ""
                  raw_details.license = (version_info.license and tostring(version_info.license))
                      or ""

                  if version_info.dependencies then
                    for _, dep in ipairs(version_info.dependencies) do
                      if dep.kind == "normal" then -- Only normal dependencies, not dev/build
                        raw_details.dependencies[dep.crate_id] = dep.req
                      end
                    end
                  end
                  break
                end
              end
            else
              raw_details.version = (crate.newest_version and tostring(crate.newest_version)) or "unknown"
              if json_data.versions and #json_data.versions > 0 then
                local latest_version = json_data.versions[1]
                raw_details.author = (
                      latest_version.authors and type(latest_version.authors) == "table"
                    )
                    and table.concat(latest_version.authors, ", ")
                    or ""
                raw_details.license = (latest_version.license and tostring(latest_version.license))
                    or ""

                if latest_version.dependencies then
                  for _, dep in ipairs(latest_version.dependencies) do
                    if dep.kind == "normal" then
                      raw_details.dependencies[dep.crate_id] = dep.req
                    end
                  end
                end
              end
            end
          end
        end

        local package_info = {
          fields = {
            { type = "simple",       label = "Name",         value = raw_details.name },
            { type = "simple",       label = "Version",      value = raw_details.version },
            { type = "multiline",    label = "Description",  value = raw_details.description },
            { type = "simple",       label = "Author",       value = raw_details.author },
            { type = "simple",       label = "License",      value = raw_details.license },
            { type = "simple",       label = "Repository",   value = raw_details.repository },
            { type = "dependencies", label = "Dependencies", value = raw_details.dependencies },
          },
        }

        callback(package_info)
      end)
    end,
  })
end

function M.get_package_versions_async(package_name, callback)
  local versions_url = string.format("%s/crates/%s/versions", CRATES_IO_API_BASE, package_name)

  local cmd = { "curl", "-s", versions_url }
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
          local success, json_data = pcall(vim.fn.json_decode, result)

          if success and json_data and json_data.versions then
            for _, version_info in ipairs(json_data.versions) do
              if version_info.num and not version_info.yanked then
                table.insert(versions, { version = version_info.num })
              end
            end
          end
        end

        callback(versions)
      end)
    end,
  })
end

function M.install_package_async(package_name, version, callback)
  local package_spec = package_name
  if version and version ~= "" and version ~= "LATEST" then
    package_spec = package_name .. "@" .. version
  end

  local cmd = { "cargo", "add", package_spec }
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
    on_stderr = function(_, data)
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
        if exit_code == 0 then
          callback(true, "Package added to Cargo.toml")
        else
          local error_msg = table.concat(output, " ")
          callback(false, "Failed to add package: " .. (error_msg ~= "" and error_msg or "Unknown error"))
        end
      end)
    end,
  })
end

function M.uninstall_package_async(package_name, callback)
  local cmd = { "cargo", "remove", package_name }
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
        if exit_code == 0 then
          callback(true, "Package removed from Cargo.toml")
        else
          callback(false, "Failed to remove package")
        end
      end)
    end,
  })
end

function M.parse_package(raw_string)
  if not raw_string or raw_string == "" then
    return nil
  end

  -- Handle strings like "package_name@version" or "package_name@version → new_version"
  local package_name, version = raw_string:match("^([^@]+)@([^%s→]+)")
  if package_name and version then
    return {
      name = package_name,
      version = version,
    }
  end

  return nil
end

return M
