local M = {}

local RUBYGEMS_API_BASE = "https://rubygems.org/api/v1"

function M.parse_package(raw_string)
  if not raw_string or raw_string == "" then
    return nil
  end

  if
      raw_string:match("^%s*No ")
      or raw_string:match("^%s*Type ")
      or raw_string:match("^%s*Check ")
      or raw_string:match("^%s*Searching ")
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

-- Helper function to format ISO date to YYYY-MM-DD
local function format_date(iso_date)
  if not iso_date or iso_date == "" then
    return ""
  end

  -- Extract date part from ISO format "2025-01-01T12:00:00.000Z"
  local date_part = iso_date:match("^(%d%d%d%d%-%d%d%-%d%d)")
  return date_part or iso_date
end

local get_packages_with_latest_versions_async
local get_package_latest_version_async

function M.get_installed_packages_with_updates_async(callback)
  local gemfile_path = vim.fn.getcwd() .. "/Gemfile"
  local gemfile_lock_path = vim.fn.getcwd() .. "/Gemfile.lock"

  local success, gemfile_content = pcall(vim.fn.readfile, gemfile_lock_path)
  if not success or not gemfile_content then
    success, gemfile_content = pcall(vim.fn.readfile, gemfile_path)
    if not success or not gemfile_content then
      callback({})
      return
    end
  end

  local packages = {}
  local use_gemfile_lock = vim.fn.filereadable(gemfile_lock_path) == 1

  if use_gemfile_lock then
    local in_specs = false
    local found_packages = false

    for _, line in ipairs(gemfile_content) do
      local trimmed = line:match("^%s*(.-)%s*$")

      if trimmed:match("^specs:") then
        in_specs = true
      elseif trimmed:match("^%w+:") then
        in_specs = false
      elseif in_specs and trimmed ~= "" then
        -- Parse gem lines like: "    rails (7.0.4.3)"
        local package_name, version = trimmed:match("^%s+([%w%-_]+)%s+%(([^%)]+)%)")
        if package_name and version then
          found_packages = true
          table.insert(packages, {
            name = package_name,
            version = version,
            description = "",
            type = "dependency",
          })
        end
      end
    end

    if not found_packages then
      local gemfile_success, gemfile_content_fallback = pcall(vim.fn.readfile, gemfile_path)
      if gemfile_success and gemfile_content_fallback then
        gemfile_content = gemfile_content_fallback
        use_gemfile_lock = false
      end
    end
  end

  if not use_gemfile_lock then
    for _, line in ipairs(gemfile_content) do
      local trimmed = line:match("^%s*(.-)%s*$")

      if not trimmed:match("^#") and trimmed ~= "" then
        local package_name, version = trimmed:match("gem%s+['\"]([^'\"]+)['\"]%s*,%s*['\"]([^'\"]+)['\"]")
        if package_name and version then
          table.insert(packages, {
            name = package_name,
            version = version,
            description = "",
            type = "dependency",
          })
        else
          local simple_name = trimmed:match("gem%s+['\"]([^'\"]+)['\"]")
          if simple_name then
            table.insert(packages, {
              name = simple_name,
              version = "latest",
              description = "",
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
        -- Remove version prefix like "~> 1.0" or ">= 1.0" for comparison
        local current_clean = package.version:gsub("^[~>=%s]+", "")
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
  local details_url = string.format("%s/gems/%s.json", RUBYGEMS_API_BASE, package_name)

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

          if success and json_data and json_data.version then
            latest_version = json_data.version
          end
        end

        callback(latest_version)
      end)
    end,
  })
end

function M.search_packages_async(query, callback)
  local search_url = string.format("%s/search.json?query=%s", RUBYGEMS_API_BASE, vim.fn.shellescape(query))

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

          if success and json_data and type(json_data) == "table" then
            -- Take only first 50 results
            local count = 0
            for _, gem in ipairs(json_data) do
              if count >= 50 then
                break
              end

              if gem.name and gem.version then
                table.insert(packages, {
                  name = gem.name,
                  version = gem.version,
                  description = gem.info or "",
                  type = "available",
                })
                count = count + 1
              end
            end
          end
        end

        callback(packages)
      end)
    end,
  })
end

local function get_dependencies_async(package_name, package_version, callback)
  local dependencies_url =
      string.format("%s/gems/%s/versions/%s.json", RUBYGEMS_API_BASE, package_name, package_version)

  local cmd = { "curl", "-s", dependencies_url }
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
        local dependencies = {}

        if exit_code == 0 then
          local result = table.concat(output, "\n")
          local success, json_data = pcall(vim.fn.json_decode, result)

          if success and json_data and json_data.dependencies then
            if json_data.dependencies.runtime then
              for _, dep in ipairs(json_data.dependencies.runtime) do
                if dep.name then
                  dependencies[dep.name] = dep.requirements or ">= 0"
                end
              end
            end
          end
        end

        callback(dependencies)
      end)
    end,
  })
end

function M.get_package_details_async(package_name, callback, version)
  if not package_name or package_name == "" then
    callback(nil)
    return
  end

  local details_url = string.format("%s/gems/%s.json", RUBYGEMS_API_BASE, package_name)
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
        if exit_code ~= 0 then
          callback(nil)
          return
        end

        local result = table.concat(output, "\n")
        local success, gem_data = pcall(vim.fn.json_decode, result)

        if not success or not gem_data then
          callback(nil)
          return
        end

        local target_version = version or gem_data.version
        get_dependencies_async(package_name, target_version, function(dependencies)
          local function safe_clean_string(str)
            if not str or str == "" then
              return ""
            end
            local cleaned = tostring(str):gsub("\n", " "):gsub("\r", " "):gsub("%s+", " ")
            local trimmed = cleaned:match("^%s*(.-)%s*$")
            return trimmed or ""
          end

          local description = safe_clean_string(gem_data.info)

          local authors = gem_data.authors or ""
          if type(authors) == "table" then
            authors = table.concat(authors, ", ")
          end
          authors = safe_clean_string(authors)

          local function safe_string(value, default)
            if value == nil or value == "" then
              return default or ""
            end
            return tostring(value)
          end

          local package_info = {
            fields = {
              {
                type = "simple",
                label = "Name",
                value = safe_string(gem_data.name, package_name),
              },
              {
                type = "simple",
                label = "Version",
                value = safe_string(target_version, "unknown"),
              },
              { type = "multiline", label = "Description", value = description },
              { type = "simple",    label = "Authors",     value = authors },
              {
                type = "simple",
                label = "License",
                value = gem_data.licenses and table.concat(gem_data.licenses, ", ") or "",
              },
              {
                type = "simple",
                label = "Homepage",
                value = safe_string(gem_data.homepage_uri),
              },
              {
                type = "simple",
                label = "Source Code",
                value = safe_string(gem_data.source_code_uri),
              },
              {
                type = "simple",
                label = "Downloads",
                value = safe_string(gem_data.downloads, "0"),
              },
              { type = "dependencies", label = "Dependencies", value = dependencies or {} },
            },
          }
          callback(package_info)
        end)
      end)
    end,
  })
end

function M.get_package_versions_async(package_name, callback)
  if not package_name or package_name == "" then
    callback({})
    return
  end

  local versions_url = string.format("%s/versions/%s.json", RUBYGEMS_API_BASE, package_name)
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

          if success and json_data and type(json_data) == "table" then
            for _, version_info in ipairs(json_data) do
              if version_info.number then
                table.insert(versions, {
                  version = version_info.number,
                  created_at = format_date(version_info.created_at) or "",
                  prerelease = version_info.prerelease or false,
                })
              end
            end

            -- Sort versions by creation date (newest first)
            table.sort(versions, function(a, b)
              return (a.created_at or "") > (b.created_at or "")
            end)
          end
        end

        callback(versions)
      end)
    end,
  })
end

function M.install_package_async(package_name, version, callback)
  local cwd = vim.fn.getcwd()
  local gemfile_path = cwd .. "/Gemfile"

  local function is_gem_in_gemfile(gem_name)
    local success, gemfile_content = pcall(vim.fn.readfile, gemfile_path)
    if not success or not gemfile_content then
      return false
    end

    for _, line in ipairs(gemfile_content) do
      local trimmed = line:match("^%s*(.-)%s*$")
      if not trimmed:match("^#") and trimmed ~= "" then
        local existing_name = trimmed:match("gem%s+['\"]([^'\"]+)['\"]")
        if existing_name == gem_name then
          return true
        end
      end
    end
    return false
  end

  local was_present_before = is_gem_in_gemfile(package_name)
  if was_present_before then
    vim.schedule(function()
      callback(true, "Gem is already in Gemfile")
    end)
    return
  end

  local output = {}
  local error_output = {}

  local cmd = { "bundle", "add", package_name }
  if version and version ~= "latest" then
    table.insert(cmd, "--version")
    table.insert(cmd, version)
  end

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
        local success = exit_code == 0
        local message = nil

        local is_present_after = is_gem_in_gemfile(package_name)
        if is_present_after and not was_present_before then
          success = true
          if exit_code ~= 0 then
            message = "Gem added to Gemfile (run 'bundle install' to complete installation)"
          else
            message = "Gem successfully installed"
          end
        elseif not success then
          local error_text = table.concat(error_output, "\n")
          if error_text:match("specify the same gem twice") or error_text:match("already.*in.*Gemfile") then
            success = true
            message = "Gem is already in Gemfile"
          elseif
              error_text:match("could not find compatible versions")
              or error_text:match("dependency.*conflict")
              or error_text:match("Bundler could not find compatible versions")
          then
            message = "Dependency conflict - try a different version or run 'bundle update'"
          elseif error_text:match("not find gem") or error_text:match("Could not find") then
            message = "Gem not found - check the gem name and version"
          elseif error_text:match("permission") or error_text:match("sudo") then
            message = "Permission denied - try running 'bundle config set --local path vendor/bundle'"
          else
            message = "Installation failed - check bundle add command manually"
          end
        end

        callback(success, message)
      end)
    end,
  })
end

function M.uninstall_package_async(package_name, callback)
  local output = {}
  local error_output = {}

  local cmd = { "bundle", "remove", package_name }

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
        local success = exit_code == 0
        local message = nil

        if not success then
          local error_text = table.concat(error_output, "\n")
          if error_text:match("not.*found") or error_text:match("not.*in.*Gemfile") then
            success = true
            message = "Gem was not in Gemfile"
          end
        end

        callback(success, message)
      end)
    end,
  })
end

return M
