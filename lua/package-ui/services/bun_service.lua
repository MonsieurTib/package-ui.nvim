local M = {}

local NPM_REGISTRY = "https://registry.npmjs.org"
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

  local search_url = string.format("%s/-/v1/search?text=%s&size=50", NPM_REGISTRY, vim.uri_encode(query))
  local cmd = { "curl", "-s", search_url }
  local output = {}

  current_search_job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
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
          local success, data = pcall(vim.fn.json_decode, result)
          if success and data and data.objects then
            for _, obj in ipairs(data.objects) do
              local pkg = obj.package
              if pkg then
                table.insert(packages, {
                  name = pkg.name or "unknown",
                  version = pkg.version or "latest",
                  description = pkg.description or "",
                  author = pkg.publisher and pkg.publisher.username or "",
                  type = "available",
                })
              end
              if #packages >= 50 then
                break
              end
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

function M.get_package_versions_async(package_name, callback)
  if not package_name or package_name == "" then
    callback({})
    return
  end

  local url = string.format("%s/%s", NPM_REGISTRY, package_name)
  local cmd = { "curl", "-s", url }
  local output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
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
            if success and data and data.versions then
              local version_list = {}
              for version, _ in pairs(data.versions) do
                table.insert(version_list, version)
              end

              table.sort(version_list, function(a, b)
                local a_parts = { a:match("(%d+)%.(%d+)%.(%d+)") }
                local b_parts = { b:match("(%d+)%.(%d+)%.(%d+)") }
                if #a_parts == 3 and #b_parts == 3 then
                  for i = 1, 3 do
                    local a_num = tonumber(a_parts[i]) or 0
                    local b_num = tonumber(b_parts[i]) or 0
                    if a_num ~= b_num then
                      return a_num > b_num
                    end
                  end
                end
                return a > b
              end)

              for _, version in ipairs(version_list) do
                table.insert(versions, {
                  version = version,
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

function M.get_package_details_async(package_name, callback, version)
  if not package_name or package_name == "" then
    callback(nil)
    return
  end

  local url = version and string.format("%s/%s/%s", NPM_REGISTRY, package_name, version)
    or string.format("%s/%s/latest", NPM_REGISTRY, package_name)
  local cmd = { "curl", "-s", url }
  local output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
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
        if not result or result == "" then
          callback(nil)
          return
        end

        local success, data = pcall(vim.fn.json_decode, result)
        if not success or not data then
          callback(nil)
          return
        end

        local author_name = ""
        if data.author then
          if type(data.author) == "string" then
            author_name = data.author
          elseif type(data.author) == "table" then
            author_name = data.author.name or ""
          end
        end

        local package_info = {
          fields = {
            { type = "simple", label = "Name", value = data.name or package_name },
            { type = "simple", label = "Version", value = data.version or version or "unknown" },
            { type = "multiline", label = "Description", value = data.description or "" },
            { type = "simple", label = "Author", value = author_name },
            { type = "simple", label = "License", value = data.license or "" },
            { type = "simple", label = "Homepage", value = data.homepage or "" },
            {
              type = "simple",
              label = "Repository",
              value = data.repository and data.repository.url or "",
            },
            { type = "keywords", label = "Keywords", value = data.keywords or {} },
            { type = "dependencies", label = "Dependencies", value = data.dependencies or {} },
            { type = "dependencies", label = "Dev Dependencies", value = data.devDependencies or {} },
          },
        }

        callback(package_info)
      end)
    end,
  })
end

local function parse_package_json()
  local package_json_path = vim.fn.getcwd() .. "/package.json"
  local success, content = pcall(vim.fn.readfile, package_json_path)
  if not success or not content then
    return {}
  end

  local json_str = table.concat(content, "\n")
  local ok, data = pcall(vim.fn.json_decode, json_str)
  if not ok or not data then
    return {}
  end

  local packages = {}

  if data.dependencies then
    for name, version in pairs(data.dependencies) do
      local clean_version = version:gsub("^[%^~>=<]+", "")
      table.insert(packages, {
        name = name,
        version = clean_version,
        type = "dependency",
        has_update = false,
        latest_version = nil,
      })
    end
  end

  if data.devDependencies then
    for name, version in pairs(data.devDependencies) do
      local clean_version = version:gsub("^[%^~>=<]+", "")
      table.insert(packages, {
        name = name,
        version = clean_version,
        type = "dev-dependency",
        has_update = false,
        latest_version = nil,
      })
    end
  end

  return packages
end

local function parse_bun_outdated_output(lines)
  local updates = {}

  for _, line in ipairs(lines) do
    local name, current, _, latest = line:match("|%s*([^|]+)%s*|%s*([^|]+)%s*|%s*([^|]+)%s*|%s*([^|]+)%s*|")
    if name and current and latest then
      name = name:gsub("^%s+", ""):gsub("%s+$", "")
      current = current:gsub("^%s+", ""):gsub("%s+$", "")
      latest = latest:gsub("^%s+", ""):gsub("%s+$", "")

      if name ~= "Package" and name ~= "" and not name:match("^%-+$") then
        updates[name] = {
          current = current,
          latest = latest,
        }
      end
    end
  end

  return updates
end

function M.get_installed_packages_with_updates_async(callback)
  local packages = parse_package_json()

  if #packages == 0 then
    callback({})
    return
  end

  local cmd = { "bun", "outdated" }
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
    on_exit = function()
      vim.schedule(function()
        local updates = parse_bun_outdated_output(output)

        for _, pkg in ipairs(packages) do
          local update_info = updates[pkg.name]
          if update_info and update_info.latest ~= update_info.current then
            pkg.has_update = true
            pkg.latest_version = update_info.latest
          end
        end

        callback(packages)
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
  local cmd = { "bun", "add", package_spec }
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

function M.uninstall_package_async(package_name, callback)
  if not package_name or package_name == "" then
    callback(false, "Invalid package name")
    return
  end

  local cmd = { "bun", "remove", package_name }
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

return M
