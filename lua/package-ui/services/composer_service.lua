local M = {}

local current_search_job = nil
local PACKAGIST_BASE_URL = "https://packagist.org"

local function format_date(iso_date)
  if not iso_date or iso_date == "" then
    return ""
  end

  local date_part = iso_date:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date_part or iso_date
end

function M.get_installed_packages_with_updates_async(callback)
  local cwd = vim.fn.getcwd()
  local composer_json_path = cwd .. "/composer.json"

  if vim.fn.filereadable(composer_json_path) ~= 1 then
    callback({})
    return
  end

  local composer_json_content = vim.fn.readfile(composer_json_path)
  if not composer_json_content or #composer_json_content == 0 then
    callback({})
    return
  end

  local composer_json_str = table.concat(composer_json_content, "\n")
  local success, composer_json = pcall(vim.fn.json_decode, composer_json_str)

  if not success or not composer_json or not composer_json.require then
    callback({})
    return
  end

  local direct_packages = {}
  for package_name, version_constraint in pairs(composer_json.require) do
    if package_name ~= "php" then
      table.insert(direct_packages, {
        name = package_name,
        version_constraint = version_constraint,
      })
    end
  end

  if #direct_packages == 0 then
    callback({})
    return
  end

  local packages = {}
  local completed = 0
  local total = #direct_packages

  if total == 0 then
    callback({})
    return
  end

  for _, direct_pkg in ipairs(direct_packages) do
    local cmd = { "composer", "show", "--format=json", direct_pkg.name }
    local output = {}

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
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if exit_code == 0 then
            local result = table.concat(output, "\n")
            local success_parse, composer_data = pcall(vim.fn.json_decode, result)

            if success_parse and composer_data and composer_data.name then
              local version = composer_data.versions and composer_data.versions[1] or "unknown"
              local pkg = {
                name = composer_data.name,
                version = version,
                description = composer_data.description or "",
                type = "dependency",
                has_update = false,
                latest_version = nil,
              }
              table.insert(packages, pkg)
            end
          else
            table.insert(packages, {
              name = direct_pkg.name,
              version = direct_pkg.version_constraint,
              description = "",
              type = "dependency",
              has_update = false,
              latest_version = nil,
            })
          end

          completed = completed + 1

          if completed >= total then
            if #packages > 0 then
              local update_completed = 0
              local update_total = #packages

              for _, package in ipairs(packages) do
                M.get_package_latest_version_async(package.name, function(latest_version)
                  if latest_version and latest_version ~= package.version then
                    package.has_update = true
                    package.latest_version = latest_version
                  end

                  update_completed = update_completed + 1
                  if update_completed >= update_total then
                    vim.schedule(function()
                      callback(packages)
                    end)
                  end
                end)
              end
            else
              callback(packages)
            end
          end
        end)
      end,
    })
  end
end

function M.get_package_latest_version_async(package_name, callback)
  if not package_name or package_name == "" then
    callback(nil)
    return
  end

  local encoded_package = package_name:gsub("/", "%%2F")
  local package_url = string.format("%s/packages/%s.json", PACKAGIST_BASE_URL, encoded_package)
  local output = {}

  vim.fn.jobstart({ "curl", "-s", package_url }, {
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
          local success, package_data = pcall(vim.fn.json_decode, result)

          if success and package_data and package_data.package then
            -- Get the latest version from versions list
            local versions = package_data.package.versions
            if versions then
              -- Find the highest stable version
              for version, _ in pairs(versions) do
                if
                    not version:match("dev")
                    and not version:match("alpha")
                    and not version:match("beta")
                    and not version:match("rc")
                then
                  if not latest_version or version > latest_version then
                    latest_version = version
                  end
                end
              end
            end
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
  local search_url = string.format("%s/search.json?q=%s", PACKAGIST_BASE_URL, encoded_query)
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
          local result = table.concat(output, "\n")
          local success, search_data = pcall(vim.fn.json_decode, result)

          if success and search_data and search_data.results then
            for _, package_data in ipairs(search_data.results) do
              if package_data.name then
                local description = package_data.description or ""
                if description:len() > 100 then
                  description = description:sub(1, 97) .. "..."
                end

                table.insert(packages, {
                  name = package_data.name,
                  version = "latest",
                  description = description,
                  author = package_data.name:match("^([^/]+)") or "",
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

  local clean_package_name = package_name:gsub("@.*", "")
  local encoded_package = clean_package_name:gsub("/", "%%2F")
  local package_url = string.format("%s/packages/%s.json", PACKAGIST_BASE_URL, encoded_package)
  local output = {}

  vim.fn.jobstart({ "curl", "-s", package_url }, {
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
        local package_info = {
          fields = {
            { type = "simple", label = "Name",    value = clean_package_name },
            { type = "simple", label = "Version", value = version or "latest" },
            { type = "simple", label = "Type",    value = "Composer Package" },
          },
        }

        if exit_code == 0 then
          local result = table.concat(output, "\n")
          local success, package_data = pcall(vim.fn.json_decode, result)

          if success and package_data and package_data.package then
            local pkg = package_data.package

            if pkg.description then
              table.insert(
                package_info.fields,
                { type = "multiline", label = "Description", value = pkg.description }
              )
            end

            local repository = pkg.repository or ""
            if repository ~= "" then
              table.insert(
                package_info.fields,
                { type = "simple", label = "Repository", value = repository }
              )
            end

            local version_data = nil
            if pkg.versions then
              if version and version ~= "latest" and pkg.versions[version] then
                version_data = pkg.versions[version]
              else
                local stable_versions = {}

                for ver, ver_data in pairs(pkg.versions) do
                  if
                      not ver:match("dev")
                      and not ver:match("alpha")
                      and not ver:match("beta")
                      and not ver:match("RC")
                  then
                    table.insert(stable_versions, { version = ver, data = ver_data })
                  end
                end

                table.sort(stable_versions, function(a, b)
                  return a.version > b.version
                end)

                if #stable_versions > 0 then
                  version_data = stable_versions[1].data
                end
              end
            end

            if version_data then
              if version_data.license then
                local license = type(version_data.license) == "table"
                    and table.concat(version_data.license, ", ")
                    or version_data.license
                table.insert(
                  package_info.fields,
                  { type = "simple", label = "License", value = license }
                )
              end

              if version_data.authors and #version_data.authors > 0 then
                local authors = {}
                for _, author in ipairs(version_data.authors) do
                  table.insert(authors, author.name or "Unknown")
                end
                table.insert(
                  package_info.fields,
                  { type = "simple", label = "Authors", value = table.concat(authors, ", ") }
                )
              end

              if
                  version_data.keywords
                  and type(version_data.keywords) == "table"
                  and #version_data.keywords > 0
              then
                table.insert(
                  package_info.fields,
                  { type = "keywords", label = "Keywords", value = version_data.keywords }
                )
              end

              if version_data.time then
                local formatted_date = format_date(version_data.time)
                if formatted_date ~= "" then
                  table.insert(
                    package_info.fields,
                    { type = "simple", label = "Published", value = formatted_date }
                  )
                end
              end

              if version_data.require and type(version_data.require) == "table" then
                local deps = {}
                for name, constraint in pairs(version_data.require) do
                  if name ~= "php" then
                    deps[name] = constraint
                  end
                end
                if next(deps) then -- Only add if there are non-PHP dependencies
                  table.insert(
                    package_info.fields,
                    { type = "dependencies", label = "Dependencies", value = deps }
                  )
                end
              end

              if version_data["require-dev"] and type(version_data["require-dev"]) == "table" then
                local dev_deps = {}
                for name, constraint in pairs(version_data["require-dev"]) do
                  dev_deps[name] = constraint
                end
                if next(dev_deps) then
                  table.insert(
                    package_info.fields,
                    { type = "dependencies", label = "Dev Dependencies", value = dev_deps }
                  )
                end
              end
            end

            if pkg.downloads and pkg.downloads.total then
              table.insert(
                package_info.fields,
                { type = "simple", label = "Downloads", value = tostring(pkg.downloads.total) }
              )
            end
          end
        end

        callback(package_info)
      end)
    end,
  })
end

function M.get_package_versions_async(package_name, callback)
  if not package_name or package_name == "" then
    callback({})
    return
  end

  local clean_package_name = package_name:gsub("@.*", "")
  local encoded_package = clean_package_name:gsub("/", "%%2F")
  local package_url = string.format("%s/packages/%s.json", PACKAGIST_BASE_URL, encoded_package)
  local output = {}

  vim.fn.jobstart({ "curl", "-s", package_url }, {
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
            local success, package_data = pcall(vim.fn.json_decode, result)

            if success and package_data and package_data.package and package_data.package.versions then
              local version_list = {}
              for version, _ in pairs(package_data.package.versions) do
                table.insert(version_list, version)
              end

              table.sort(version_list, function(a, b)
                return a > b -- Latest first
              end)

              for _, version in ipairs(version_list) do
                table.insert(versions, { version = version })
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
  if not package_name or package_name == "" then
    callback(false, "Package name is required")
    return
  end

  local clean_package_name = package_name:gsub("@.*", "")

  local cwd = vim.fn.getcwd()
  local composer_json_path = cwd .. "/composer.json"

  if vim.fn.filereadable(composer_json_path) ~= 1 then
    callback(false, "No composer.json found in current directory")
    return
  end

  local package_spec = clean_package_name
  if version and version ~= "latest" then
    package_spec = clean_package_name .. ":" .. version
  end

  local function try_install(cmd_args, attempt_name)
    local output = {}
    local error_output = {}

    return vim.fn.jobstart(cmd_args, {
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
          if exit_code == 0 then
            callback(true, string.format("Successfully installed %s", package_spec))
          else
            local error_msg = table.concat(error_output, "\n")

            -- If this was the first attempt and it failed due to dependency conflicts, try with --with-all-dependencies
            if
                attempt_name == "normal"
                and (
                  error_msg:match("partial update")
                  or error_msg:match("locked to specific versions")
                  or error_msg:match("could not be resolved to an installable set")
                  or error_msg:match("Make sure you list it as an argument for the update command")
                )
            then
              -- Retry with --with-all-dependencies flag
              local retry_cmd = { "composer", "require", package_spec, "--with-all-dependencies" }
              try_install(retry_cmd, "with-dependencies")
            else
              -- Final failure
              local final_msg = attempt_name == "with-dependencies"
                  and string.format(
                    "Failed to install %s (tried with --with-all-dependencies): %s",
                    package_spec,
                    error_msg
                  )
                  or string.format("Failed to install %s: %s", package_spec, error_msg)
              callback(false, final_msg)
            end
          end
        end)
      end,
    })
  end

  try_install({ "composer", "require", package_spec }, "normal")
end

function M.uninstall_package_async(package_name, callback)
  if not package_name or package_name == "" then
    callback(false, "Package name is required")
    return
  end

  local clean_package_name = package_name:gsub("@.*", "")

  local cwd = vim.fn.getcwd()
  local composer_json_path = cwd .. "/composer.json"

  if vim.fn.filereadable(composer_json_path) ~= 1 then
    callback(false, "No composer.json found in current directory")
    return
  end

  local cmd = { "composer", "remove", clean_package_name }
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
        if exit_code == 0 then
          callback(true, string.format("Successfully removed %s", clean_package_name))
        else
          local error_msg = table.concat(error_output, "\n")
          callback(false, string.format("Failed to remove %s: %s", clean_package_name, error_msg))
        end
      end)
    end,
  })
end

function M.parse_package(package_string)
  if not package_string or package_string == "" then
    return nil
  end

  local vendor, package, version = package_string:match("^([^/]+)/([^:]+):?([^:]*)$")
  if vendor and package then
    return {
      name = vendor .. "/" .. package,
      version = version and version ~= "" and version or nil,
    }
  end

  return nil
end

return M

