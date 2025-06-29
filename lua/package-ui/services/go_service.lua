local M = {}

local GO_PROXY_BASE = "https://proxy.golang.org"
local current_search_job = nil

function M.get_installed_packages_with_updates_async(callback)
  local cwd = vim.fn.getcwd()
  local go_mod_path = cwd .. "/go.mod"

  if vim.fn.filereadable(go_mod_path) ~= 1 then
    callback({})
    return
  end

  local cmd = { "go", "list", "-m", "-json", "all" }
  local output = {}
  local error_output = {}

  vim.fn.jobstart(cmd, {
    cwd = cwd,
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
        local packages = {}

        if exit_code == 0 then
          local result = table.concat(output, "\n")

          local json_objects = {}
          local current_object = ""
          local brace_count = 0

          for line in result:gmatch("[^\n]*") do
            if line:match("^%s*{") then
              if current_object ~= "" then
                table.insert(json_objects, current_object)
              end
              current_object = line
              brace_count = 1
            elseif brace_count > 0 then
              current_object = current_object .. "\n" .. line
              local open_braces = line:gsub("[^{]", "")
              local close_braces = line:gsub("[^}]", "")
              brace_count = brace_count + #open_braces - #close_braces

              if brace_count == 0 then
                table.insert(json_objects, current_object)
                current_object = ""
              end
            end
          end

          if current_object ~= "" then
            table.insert(json_objects, current_object)
          end

          for _, json_str in ipairs(json_objects) do
            local success, module_data = pcall(vim.fn.json_decode, json_str)
            if success and module_data and module_data.Path then
              -- Skip the main module (current project)
              if not module_data.Main and module_data.Path then
                local pkg = {
                  name = module_data.Path,
                  version = module_data.Version or "unknown",
                  description = "",
                  type = "dependency",
                  has_update = false,
                  latest_version = nil,
                }

                if module_data.Indirect then
                  pkg.description = "indirect dependency"
                end

                table.insert(packages, pkg)
              end
            end
          end
        end

        if #packages > 0 then
          local completed = 0
          local total = #packages

          for _, package in ipairs(packages) do
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
        else
          callback(packages)
        end
      end)
    end,
  })
end

function M.get_package_latest_version_async(package_name, callback)
  local latest_url = string.format("%s/%s/@latest", GO_PROXY_BASE, package_name)

  local cmd = { "curl", "-s", latest_url }
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

          if success and json_data and json_data.Version then
            latest_version = json_data.Version
          end
        end

        callback(latest_version)
      end)
    end,
  })
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

  local encoded_query = query:gsub("[^%w%-%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  local search_url = string.format("https://pkg.go.dev/search?q=%s", encoded_query)
  local output = {}

  current_search_job = vim.fn.jobstart({ "curl", "-s", search_url }, {
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
        local packages = {}

        if exit_code == 0 then
          local html_content = table.concat(output, "\n")

          local seen_packages = {}

          -- Look for links with data-gtmc="search result" - these are the actual search results
          for href in html_content:gmatch('<a[^>]*href="/?([^"]+)"[^>]*data%-gtmc="search result"') do
            -- Clean up the href path
            local package_path = href:gsub("^/?", "") -- remove leading slash
            package_path = package_path:gsub("@[^/]*", "") -- remove @version
            package_path = package_path:gsub("%?.*", "") -- remove query parameters
            package_path = package_path:gsub("#.*", "") -- remove anchors

            if package_path and not seen_packages[package_path] then
              -- Basic validation that it's a real Go module path
              if package_path:match("^[%w%-%.]+%.%w+/") then -- domain.tld/path format
                seen_packages[package_path] = true

                -- Try to find description in the surrounding context
                local escaped_path = package_path:gsub("([%.%-%+%*%?%[%]%^%$%(%)%%])", "%%%1")
                local description = html_content:match(
                  escaped_path .. ".-<p[^>]*>.-Package[^%.]*%.([^<%.]+)"
                ) or html_content:match(
                  "Package[^%.]*" .. escaped_path:match("[^/]*$") .. "[^%.]*%.([^<%.]+)"
                ) or ""

                if description then
                  description = description
                      :gsub("<[^>]*>", "")
                      :gsub("&[^;]*;", "")
                      :match("^%s*(.-)%s*$") or ""
                  if description:len() > 100 then
                    description = description:sub(1, 97) .. "..."
                  end
                end

                table.insert(packages, {
                  name = package_path,
                  version = "latest",
                  description = description,
                  author = "",
                  type = "available",
                })
              end
            end
          end

          if #packages > 25 then
            local limited_packages = {}
            for i = 1, 25 do
              table.insert(limited_packages, packages[i])
            end
            packages = limited_packages
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

  local raw_details = {
    name = package_name,
    version = version or "latest",
    description = "Go module: " .. package_name,
    repository = package_name:match("^([^/]+/[^/]+/[^/]+)") and ("https://" .. package_name:match(
      "^([^/]+/[^/]+/[^/]+)"
    )) or "",
  }

  local package_info = {
    fields = {
      { type = "simple",    label = "Name",        value = raw_details.name },
      { type = "simple",    label = "Version",     value = raw_details.version },
      { type = "multiline", label = "Description", value = raw_details.description },
      { type = "simple",    label = "Repository",  value = raw_details.repository },
      { type = "simple",    label = "Type",        value = "Go Module" },
    },
  }

  vim.schedule(function()
    callback(package_info)
  end)
end

function M.get_package_versions_async(package_name, callback)
  if not package_name or package_name == "" then
    callback({})
    return
  end

  local versions_url = string.format("%s/%s/@v/list", GO_PROXY_BASE, package_name)
  local output = {}

  vim.fn.jobstart({ "curl", "-s", versions_url }, {
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

          -- Parse versions from plain text response (one version per line)
          for version_line in result:gmatch("[^\n]+") do
            local version = version_line:match("^%s*(.-)%s*$") -- trim whitespace
            if version and version ~= "" then
              table.insert(versions, {
                version = version,
                package_name = package_name,
              })
            end
          end

          table.sort(versions, function(a, b)
            return a.version > b.version
          end)
        end

        callback(versions)
      end)
    end,
  })
end

function M.install_package_async(package_name, version, callback)
  if not package_name or package_name == "" then
    callback(false, "Invalid package name")
    return
  end

  local package_spec = package_name
  if version and version ~= "" and version ~= "latest" then
    package_spec = package_name .. "@" .. version
  end

  local cmd = { "go", "get", package_spec }
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

  local go_mod_path = vim.fn.getcwd() .. "/go.mod"
  local success, go_mod_content = pcall(vim.fn.readfile, go_mod_path)

  if not success or not go_mod_content then
    callback(false, "Cannot read go.mod file")
    return
  end

  local new_content = {}
  local package_removed = false

  for _, line in ipairs(go_mod_content) do
    if not line:match("^%s*" .. vim.pesc(package_name) .. "%s") then
      table.insert(new_content, line)
    else
      package_removed = true
    end
  end

  if not package_removed then
    callback(false, "Package not found in go.mod")
    return
  end

  local write_success = pcall(vim.fn.writefile, new_content, go_mod_path)
  if not write_success then
    callback(false, "Failed to write go.mod file")
    return
  end

  local cmd = { "go", "mod", "tidy" }
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
          callback(true, "Package removed successfully")
        else
          local error_msg = #error_output > 0 and table.concat(error_output, "\n") or "Unknown error"
          callback(false, "go mod tidy failed: " .. error_msg)
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
