local M = {}

local HEX_API_BASE = "https://hex.pm/api"

local last_search = {
  term = nil,
  data = nil,
  timestamp = nil,
}

local function format_package_details(raw_details)
  local fields = {}

  local function clean_string(str)
    if not str or type(str) ~= "string" then
      return str
    end
    return str:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if raw_details.name then
    table.insert(fields, {
      type = "simple",
      label = "Name",
      value = clean_string(raw_details.name),
    })
  end

  if raw_details.version then
    table.insert(fields, {
      type = "simple",
      label = "Version",
      value = clean_string(raw_details.version),
    })
  end

  if raw_details.description and raw_details.description ~= "No description" then
    table.insert(fields, {
      type = "multiline",
      label = "Description",
      value = clean_string(raw_details.description),
      max_width = 45,
    })
  end

  if raw_details.licenses and type(raw_details.licenses) == "table" and #raw_details.licenses > 0 then
    table.insert(fields, {
      type = "simple",
      label = "License",
      value = clean_string(table.concat(raw_details.licenses, ", ")),
    })
  end

  if raw_details.homepage and raw_details.homepage ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "Homepage",
      value = clean_string(raw_details.homepage),
    })
  end

  if raw_details.repository and raw_details.repository ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "Repository",
      value = clean_string(raw_details.repository),
    })
  end

  if raw_details.downloads then
    table.insert(fields, {
      type = "simple",
      label = "Downloads",
      value = clean_string(tostring(raw_details.downloads)),
    })
  end

  if raw_details.inserted_at then
    local date = raw_details.inserted_at:match("(%d%d%d%d%-%d%d%-%d%d)")
    if date then
      table.insert(fields, {
        type = "simple",
        label = "Created",
        value = clean_string(date),
      })
    end
  end

  if raw_details.updated_at then
    local date = raw_details.updated_at:match("(%d%d%d%d%-%d%d%-%d%d)")
    if date then
      table.insert(fields, {
        type = "simple",
        label = "Updated",
        value = clean_string(date),
      })
    end
  end

  if raw_details.requirements and type(raw_details.requirements) == "table" then
    local deps = {}
    local optional_deps = {}

    for dep_name, dep_info in pairs(raw_details.requirements) do
      local clean_name = clean_string(dep_name)
      local clean_requirement = clean_string(dep_info.requirement or "any")
      if dep_info.optional then
        optional_deps[clean_name] = clean_requirement
      else
        deps[clean_name] = clean_requirement
      end
    end

    if next(deps) then
      table.insert(fields, {
        type = "dependencies",
        label = "Dependencies",
        value = deps,
      })
    end

    if next(optional_deps) then
      table.insert(fields, {
        type = "dependencies",
        label = "Optional Dependencies",
        value = optional_deps,
      })
    end
  end

  return { fields = fields }
end

local function is_last_search_valid(search_term)
  return last_search.term == search_term
      and last_search.data
      and last_search.timestamp
      and (os.time() - last_search.timestamp) < 300 -- 5 minutes TTL
end

local function parse_outdated_line(line)
  local parts = {}
  for part in string.gmatch(line, "%S+") do
    table.insert(parts, part)
  end

  if #parts >= 3 then
    local name = parts[1]
    local version = parts[2]
    local latest_version = parts[3]
    local status = parts[4] or ""

    local has_update = false
    if status == "Up-to-date" or latest_version == "Up-to-date" then
      latest_version = version
    elseif status:match("Update") and status:match("not") and status:match("possible") then
      has_update = false
      latest_version = latest_version
    elseif version ~= latest_version then
      has_update = true
    end

    return {
      name = name,
      version = version,
      latest_version = latest_version,
      has_update = has_update,
    }
  end

  return nil
end

function M.get_installed_packages_with_updates_async(callback)
  local cmd = { "mix", "hex.outdated" }
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
        local has_useful_output = false
        for i, line in ipairs(output) do
          if i > 1 and line ~= "" and not line:match("^Run ") and not line:match("^%s*$") then
            if
                line:match("^%w+%s+[%d%.]+%s+[%d%.]+")
                or line:match("Update not possible")
                or line:match("Up%-to%-date")
            then
              has_useful_output = true
              break
            end
          end
        end

        if exit_code ~= 0 and not has_useful_output then
          local deps_cmd = { "mix", "deps" }
          local deps_output = {}

          vim.fn.jobstart(deps_cmd, {
            stdout_buffered = true,
            on_stdout = function(_, data)
              if data then
                for _, line in ipairs(data) do
                  if line ~= "" then
                    table.insert(deps_output, line)
                  end
                end
              end
            end,
            on_exit = function(_, deps_exit_code)
              vim.schedule(function()
                local packages = {}
                if deps_exit_code == 0 then
                  for _, line in ipairs(deps_output) do
                    local name = line:match("^%* ([%w_]+) %(Hex package%)")
                    if name then
                      local version = line:match("locked at ([%d%.]+)")
                      table.insert(packages, {
                        name = name,
                        version = version or "unknown",
                        has_update = false,
                        latest_version = nil,
                      })
                    end
                  end
                end
                callback(packages)
              end)
            end,
          })
          return
        end

        local packages = {}
        for i, line in ipairs(output) do
          if i > 1 and line ~= "" and not line:match("^Run ") and not line:match("^%s*$") then
            local pkg = parse_outdated_line(line)
            if pkg then
              table.insert(packages, pkg)
            end
          end
        end
        callback(packages)
      end)
    end,
  })
end

function M.search_packages_async(search_term, callback)
  if is_last_search_valid(search_term) then
    vim.schedule(function()
      local packages = {}
      for _, pkg_data in ipairs(last_search.data) do
        table.insert(packages, {
          name = pkg_data.name,
          version = pkg_data.latest_stable_version or pkg_data.latest_version,
        })
      end
      callback(packages)
    end)
    return
  end

  local url = string.format("%s/packages?sort=downloads&search=%s", HEX_API_BASE, vim.fn.shellescape(search_term))
  local cmd = { "curl", "-s", url }
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
          local result = table.concat(output, "")
          local success, data = pcall(vim.fn.json_decode, result)

          if success and data and type(data) == "table" then
            -- Store as last search (overwrites previous)
            last_search.term = search_term
            last_search.data = data
            last_search.timestamp = os.time()

            for _, pkg_data in ipairs(data) do
              table.insert(packages, {
                name = pkg_data.name,
                version = pkg_data.latest_stable_version or pkg_data.latest_version,
              })
            end
          end
        end

        callback(packages)
      end)
    end,
  })
end

function M.get_package_versions_async(package_name, callback)
  if last_search.data then
    for _, pkg_data in ipairs(last_search.data) do
      if pkg_data.name == package_name and pkg_data.releases then
        vim.schedule(function()
          local versions = {}
          for _, release in ipairs(pkg_data.releases) do
            table.insert(versions, { version = release.version })
          end
          callback(versions)
        end)
        return
      end
    end
  end

  local url = string.format("%s/packages/%s", HEX_API_BASE, package_name)
  local cmd = { "curl", "-s", url }
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
          local result = table.concat(output, "")
          local success, data = pcall(vim.fn.json_decode, result)

          if success and data and data.releases then
            for _, release in ipairs(data.releases) do
              table.insert(versions, { version = release.version })
            end
          end
        end

        callback(versions)
      end)
    end,
  })
end

function M.get_package_details_async(package_name, callback, version)
  if not version and last_search.data then
    for _, pkg_data in ipairs(last_search.data) do
      if pkg_data.name == package_name then
        vim.schedule(function()
          local meta = pkg_data.meta or {}
          local details = format_package_details({
            name = pkg_data.name or package_name,
            description = meta.description or "No description",
            version = pkg_data.latest_stable_version or pkg_data.latest_version,
            licenses = meta.licenses or {},
            homepage = meta.homepage or (meta.links and meta.links.Homepage) or "",
            repository = pkg_data.repository or "",
            downloads = pkg_data.downloads and pkg_data.downloads.all,
            inserted_at = pkg_data.inserted_at,
            updated_at = pkg_data.updated_at,
          })
          callback(details)
        end)
        return
      end
    end
  end

  local url
  if version then
    url = string.format("%s/packages/%s/releases/%s", HEX_API_BASE, package_name, version)
  else
    url = string.format("%s/packages/%s", HEX_API_BASE, package_name)
  end

  local cmd = { "curl", "-s", url }
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

        local result = table.concat(output, "")
        local success, data = pcall(vim.fn.json_decode, result)

        if not success or not data then
          callback(nil)
          return
        end

        if version then
          local package_url = string.format("%s/packages/%s", HEX_API_BASE, package_name)
          local package_cmd = { "curl", "-s", package_url }
          local package_output = {}

          vim.fn.jobstart(package_cmd, {
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout = function(_, pkg_data)
              if pkg_data then
                for _, line in ipairs(pkg_data) do
                  if line ~= "" then
                    table.insert(package_output, line)
                  end
                end
              end
            end,
            on_exit = function(_, pkg_exit_code)
              vim.schedule(function()
                local pkg_meta = {}
                if pkg_exit_code == 0 then
                  local pkg_result = table.concat(package_output, "")
                  local pkg_success, pkg_data = pcall(vim.fn.json_decode, pkg_result)
                  if pkg_success and pkg_data and pkg_data.meta then
                    pkg_meta = pkg_data.meta
                  end
                end

                local details = format_package_details({
                  name = data.name or package_name,
                  description = pkg_meta.description or "No description",
                  version = version,
                  licenses = pkg_meta.licenses or {},
                  homepage = pkg_meta.homepage or (pkg_meta.links and pkg_meta.links.Homepage) or "",
                  repository = data.repository or "",
                  downloads = data.downloads,
                  inserted_at = data.inserted_at,
                  updated_at = data.updated_at,
                  requirements = data.requirements,
                })
                callback(details)
              end)
            end,
          })
        else
          local meta = data.meta or {}
          local latest_version = data.latest_stable_version or data.latest_version

          if latest_version then
            local version_url =
                string.format("%s/packages/%s/releases/%s", HEX_API_BASE, package_name, latest_version)
            local version_cmd = { "curl", "-s", version_url }
            local version_output = {}

            vim.fn.jobstart(version_cmd, {
              stdout_buffered = true,
              stderr_buffered = true,
              on_stdout = function(_, version_data)
                if version_data then
                  for _, line in ipairs(version_data) do
                    if line ~= "" then
                      table.insert(version_output, line)
                    end
                  end
                end
              end,
              on_exit = function(_, version_exit_code)
                vim.schedule(function()
                  local requirements = {}
                  if version_exit_code == 0 then
                    local version_result = table.concat(version_output, "")
                    local version_success, version_data = pcall(vim.fn.json_decode, version_result)
                    if version_success and version_data and version_data.requirements then
                      requirements = version_data.requirements
                    end
                  end

                  local details = format_package_details({
                    name = data.name or package_name,
                    description = meta.description or "No description",
                    version = latest_version,
                    licenses = meta.licenses or {},
                    homepage = meta.homepage or (meta.links and meta.links.Homepage) or "",
                    repository = data.repository or "",
                    downloads = data.downloads and data.downloads.all,
                    inserted_at = data.inserted_at,
                    updated_at = data.updated_at,
                    requirements = requirements,
                  })
                  callback(details)
                end)
              end,
            })
          else
            local details = format_package_details({
              name = data.name or package_name,
              description = meta.description or "No description",
              version = latest_version,
              licenses = meta.licenses or {},
              homepage = meta.homepage or (meta.links and meta.links.Homepage) or "",
              repository = data.repository or "",
              downloads = data.downloads and data.downloads.all,
              inserted_at = data.inserted_at,
              updated_at = data.updated_at,
            })
            callback(details)
          end
        end
      end)
    end,
  })
end

local function read_mix_file()
  local mix_file = vim.fn.getcwd() .. "/mix.exs"
  if vim.fn.filereadable(mix_file) == 0 then
    return nil, "mix.exs not found"
  end

  local lines = {}
  for line in io.lines(mix_file) do
    table.insert(lines, line)
  end
  return lines, nil
end

local function write_mix_file(lines)
  local mix_file = vim.fn.getcwd() .. "/mix.exs"
  local file = io.open(mix_file, "w")
  if not file then
    return false, "Could not open mix.exs for writing"
  end

  for _, line in ipairs(lines) do
    file:write(line .. "\n")
  end
  file:close()
  return true, nil
end

local function find_deps_section(lines)
  local deps_start = nil
  local deps_end = nil
  local bracket_count = 0
  local in_deps = false

  for i, line in ipairs(lines) do
    if line:match("defp deps do") then
      deps_start = i
      in_deps = true
      bracket_count = 0
    elseif in_deps then
      -- Count brackets to find the end of the deps list
      local open_brackets = select(2, line:gsub("%[", ""))
      local close_brackets = select(2, line:gsub("%]", ""))
      bracket_count = bracket_count + open_brackets - close_brackets

      -- Look for the closing bracket of the deps list
      if bracket_count == 0 and line:match("%]") then
        deps_end = i
        break
      end
    end
  end

  return deps_start, deps_end
end

local function package_exists_in_deps(lines, package_name)
  local deps_start, deps_end = find_deps_section(lines)
  if not deps_start or not deps_end then
    return false, nil
  end

  for i = deps_start, deps_end do
    local line = lines[i]
    if line:match("{:" .. package_name .. ",") then
      return true, i
    end
  end
  return false, nil
end

local function parse_dependency_error(package_name, error_output, stdout_output)
  local all_output = {}
  for _, line in ipairs(stdout_output) do
    table.insert(all_output, line)
  end
  for _, line in ipairs(error_output) do
    table.insert(all_output, line)
  end

  local full_text = table.concat(all_output, "\n")
  local error_lines = {}

  -- Check for dependency resolution failures
  if
      full_text:match("dependency resolution failed")
      or full_text:match("version solving failed")
      or full_text:match("Failed to use")
      or full_text:match("Because")
  then
    table.insert(error_lines, "Dependency conflict detected:")
    table.insert(error_lines, "")

    local conflicts = {}
    local requirements = {}
    local raw_errors = {}

    for _, line in ipairs(all_output) do
      local clean_line = line:gsub("^%s*", ""):gsub("%s*$", "")

      if
          clean_line == ""
          or clean_line:match("^Resolving")
          or clean_line:match("^Looking")
          or clean_line:match("^Compiling")
          or clean_line:match("^Generated")
      then
        goto continue
      end

      local because_match = clean_line:match("Because (.+)")
      if because_match then
        table.insert(conflicts, "• " .. because_match)
        goto continue
      end

      local dep, required_version, available_version = clean_line:match("(%w+) requires ([^%s]+) but ([^%s]+) is")
      if dep and required_version and available_version then
        table.insert(
          conflicts,
          string.format("• %s needs %s but %s is available", dep, required_version, available_version)
        )
        goto continue
      end

      local pkg, requirement = clean_line:match("(%w+) requires: (.+)")
      if pkg and requirement then
        table.insert(requirements, string.format("• %s requires: %s", pkg, requirement))
        goto continue
      end

      local failed_pkg, reason = clean_line:match('Failed to use "?([^"]+)"? because (.+)')
      if failed_pkg and reason then
        table.insert(conflicts, string.format("• %s: %s", failed_pkg, reason))
        goto continue
      end

      local incompatible_pkg, needed_version, current_version =
          clean_line:match("(%w+) .* needs ([^%s]+) but you have ([^%s]+)")
      if incompatible_pkg and needed_version and current_version then
        table.insert(
          conflicts,
          string.format(
            "• %s needs %s but current version is %s",
            incompatible_pkg,
            needed_version,
            current_version
          )
        )
        goto continue
      end

      local pkg1, pkg2, version_constraint = clean_line:match("(%w+) depends on (%w+) (.+)")
      if pkg1 and pkg2 and version_constraint then
        table.insert(requirements, string.format("• %s depends on %s %s", pkg1, pkg2, version_constraint))
        goto continue
      end

      local constraint_violation = clean_line:match("version constraint .* was not satisfied")
      if constraint_violation then
        table.insert(conflicts, "• " .. clean_line)
        goto continue
      end

      if
          clean_line:match(package_name)
          and (
            clean_line:match("conflict")
            or clean_line:match("incompatible")
            or clean_line:match("requires")
            or clean_line:match("depends")
          )
      then
        table.insert(raw_errors, "• " .. clean_line)
        goto continue
      end

      if
          clean_line:match("^%*%*")
          or clean_line:match("ERROR")
          or clean_line:match("Error")
          or clean_line:match("failed")
          or clean_line:match("cannot")
          or clean_line:match("unable")
      then
        table.insert(raw_errors, "• " .. clean_line)
      end

      ::continue::
    end

    if #conflicts > 0 then
      table.insert(error_lines, "Conflicts found:")
      for _, conflict in ipairs(conflicts) do
        table.insert(error_lines, conflict)
      end
      table.insert(error_lines, "")
    end

    if #requirements > 0 then
      table.insert(error_lines, "Requirements:")
      for _, req in ipairs(requirements) do
        table.insert(error_lines, req)
      end
      table.insert(error_lines, "")
    end

    if #conflicts == 0 and #requirements == 0 and #raw_errors > 0 then
      table.insert(error_lines, "Error details:")
      for i, error in ipairs(raw_errors) do
        if i <= 3 then -- Limit to first 3 errors to avoid clutter
          table.insert(error_lines, error)
        end
      end
      table.insert(error_lines, "")
    end

    if #conflicts == 0 and #requirements == 0 and #raw_errors == 0 and #all_output > 0 then
      table.insert(error_lines, "Raw output (for debugging):")
      for i, line in ipairs(all_output) do
        if i <= 5 and line:gsub("^%s*", ""):gsub("%s*$", "") ~= "" then
          table.insert(error_lines, "• " .. line)
        end
      end
      table.insert(error_lines, "")
    end

    table.insert(error_lines, "Suggestions:")
    table.insert(error_lines, "• Try a different version of " .. package_name)
    table.insert(error_lines, "• Update existing dependencies first")
    table.insert(error_lines, "• Check if " .. package_name .. " is compatible with your Elixir version")
  elseif full_text:match("could not compile dependency") then
    table.insert(error_lines, "Compilation failed:")
    table.insert(error_lines, "")

    for _, line in ipairs(all_output) do
      if line:match("error:") or line:match("Error:") then
        table.insert(error_lines, "• " .. line)
      end
    end

    table.insert(error_lines, "")
    table.insert(error_lines, "This package may not be compatible with your Elixir/OTP version")
  elseif full_text:match("network") or full_text:match("timeout") or full_text:match("connection") then
    table.insert(error_lines, "Network error:")
    table.insert(error_lines, "• Check your internet connection")
    table.insert(error_lines, "• Hex.pm may be temporarily unavailable")
    table.insert(error_lines, "• Try again in a few moments")
  else
    table.insert(error_lines, "Installation failed:")
    table.insert(error_lines, "")

    local error_count = 0
    for _, line in ipairs(all_output) do
      if
          (line:match("error") or line:match("Error") or line:match("failed") or line:match("Failed"))
          and error_count < 3
      then
        table.insert(error_lines, "• " .. line)
        error_count = error_count + 1
      end
    end

    if error_count == 0 then
      table.insert(error_lines, "• Unknown error occurred during installation")
    end
  end

  return table.concat(error_lines, "\n")
end

function M.uninstall_package_async(package_name, callback)
  vim.schedule(function()
    local lines, err = read_mix_file()
    if not lines then
      callback(false, err)
      return
    end

    local exists, line_num = package_exists_in_deps(lines, package_name)
    if not exists then
      callback(false, "Package " .. package_name .. " not found in mix.exs")
      return
    end

    table.remove(lines, line_num)

    local deps_start, deps_end = find_deps_section(lines)
    if deps_start and deps_end then
      for i = deps_end - 1, deps_start + 1, -1 do
        local line = lines[i]:gsub("^%s*", ""):gsub("%s*$", "")
        if line == "" then
          table.remove(lines, i)
        elseif line:match(",$") and i == deps_end - 1 then
          lines[i] = lines[i]:gsub(",%s*$", "")
        end
      end
    end

    local success, write_err = write_mix_file(lines)
    if not success then
      callback(false, write_err)
      return
    end

    vim.fn.jobstart({ "mix", "deps.get" }, {
      cwd = vim.fn.getcwd(),
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if exit_code == 0 then
            callback(true, "Package " .. package_name .. " uninstalled successfully")
          else
            callback(false, "Package removed from mix.exs but 'mix deps.get' failed")
          end
        end)
      end,
    })
  end)
end

function M.install_package_async(package_name, version, callback)
  vim.schedule(function()
    local lines, err = read_mix_file()
    if not lines then
      callback(false, err)
      return
    end

    local deps_start, deps_end = find_deps_section(lines)
    if not deps_start or not deps_end then
      callback(false, "Could not find deps section in mix.exs")
      return
    end

    local version_spec
    if version then
      version_spec = "== " .. version
    else
      version_spec = "~> 0.1"
    end

    local exists, existing_line_num = package_exists_in_deps(lines, package_name)
    if exists then
      local existing_line = lines[existing_line_num]
      local indent = existing_line:match("^(%s*)")
      local has_comma = existing_line:match(",$")

      local updated_dep = indent .. string.format('{:%s, "%s"}', package_name, version_spec)
      if has_comma then
        updated_dep = updated_dep .. ","
      end

      lines[existing_line_num] = updated_dep
    else
      local insert_line = deps_end - 1
      while insert_line > deps_start do
        local line = lines[insert_line]:gsub("^%s*", ""):gsub("%s*$", "")
        if line ~= "" and not line:match("^#") and not line:match("^%]") then
          break
        end
        insert_line = insert_line - 1
      end

      local indent = "      " -- Default indentation
      if insert_line > deps_start then
        local prev_line = lines[insert_line]
        local existing_indent = prev_line:match("^(%s*)")
        if existing_indent and existing_indent ~= "" then
          indent = existing_indent
        end
      end

      local prev_line_clean = lines[insert_line]:gsub("^%s*", ""):gsub("%s*$", "")
      if prev_line_clean ~= "[" and not lines[insert_line]:match(",$") and prev_line_clean ~= "" then
        lines[insert_line] = lines[insert_line] .. ","
      end

      local formatted_dep = indent .. string.format('{:%s, "%s"}', package_name, version_spec)

      table.insert(lines, insert_line + 1, formatted_dep)
    end

    local success, write_err = write_mix_file(lines)
    if not success then
      callback(false, write_err)
      return
    end

    local error_output = {}
    local stdout_output = {}
    vim.fn.jobstart({ "mix", "deps.get" }, {
      cwd = vim.fn.getcwd(),
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
            local action = exists and "upgraded" or "installed"
            callback(true, "Package " .. package_name .. " " .. action .. " successfully")
          else
            local error_msg = parse_dependency_error(package_name, error_output, stdout_output)

            -- Remove the problematic package from mix.exs since it can't be installed
            local lines, read_err = read_mix_file()
            if lines then
              local exists, line_num = package_exists_in_deps(lines, package_name)
              if exists then
                table.remove(lines, line_num)
                write_mix_file(lines)
              end
            end

            callback(false, error_msg)
          end
        end)
      end,
    })
  end)
end

function M.parse_package(line)
  if not line then
    return nil
  end
  local name, version = string.match(line, "([^@]+)@(.+)")
  if name and version then
    local _, latest_version = string.match(version, "([^ ]+) → (.+)")
    if latest_version then
      version = string.match(version, "([^ ]+)")
      return { name = name, version = version, latest_version = latest_version }
    end
    return { name = name, version = version }
  end
  return nil
end

return M
