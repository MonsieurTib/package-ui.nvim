local M = {}

local PYPI_API_BASE = "https://pypi.org/pypi"

local last_search = {
  term = nil,
  data = nil,
  timestamp = nil,
}

local pypi_index_cache = {
  packages = nil,
  timestamp = nil,
  ttl = 3600,
}

local cache_dir = vim.fn.stdpath("cache") .. "/package-ui"
local pypi_cache_file = cache_dir .. "/pypi_index.json"

local function ensure_cache_dir()
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
end

local function load_cache_from_file()
  if vim.fn.filereadable(pypi_cache_file) == 1 then
    local content = vim.fn.readfile(pypi_cache_file)
    if content and #content > 0 then
      local success, cache_data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
      if success and cache_data and cache_data.packages and cache_data.timestamp then
        pypi_index_cache.packages = cache_data.packages
        pypi_index_cache.timestamp = cache_data.timestamp
        return true
      end
    end
  end
  return false
end

local function save_cache_to_file()
  ensure_cache_dir()
  local cache_data = {
    packages = pypi_index_cache.packages,
    timestamp = pypi_index_cache.timestamp,
  }
  local json_content = vim.fn.json_encode(cache_data)
  vim.fn.writefile({ json_content }, pypi_cache_file)
end

load_cache_from_file()

local function get_pip_command()
  local commands = { "pip", "pip3", "python -m pip", "python3 -m pip" }

  for _, cmd in ipairs(commands) do
    local test_cmd = cmd:match("python") and vim.split(cmd, " ") or { cmd }
    table.insert(test_cmd, "--version")

    local handle = io.popen(table.concat(test_cmd, " ") .. " 2>/dev/null")
    if handle then
      local result = handle:read("*a")
      handle:close()
      if result and result:match("pip") then
        return cmd:match("python") and vim.split(cmd, " ") or { cmd }
      end
    end
  end

  return nil
end

local function format_package_details(raw_details)
  local fields = {}

  local function clean_string(str)
    if not str or type(str) ~= "string" then
      return ""
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

  if raw_details.summary and raw_details.summary ~= "" then
    table.insert(fields, {
      type = "multiline",
      label = "Summary",
      value = clean_string(raw_details.summary),
      max_width = 45,
    })
  end

  if raw_details.author then
    table.insert(fields, {
      type = "simple",
      label = "Author",
      value = clean_string(raw_details.author),
    })
  end

  if raw_details.license and raw_details.license ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "License",
      value = clean_string(raw_details.license),
    })
  end

  if raw_details.home_page and raw_details.home_page ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "Homepage",
      value = clean_string(raw_details.home_page),
    })
  end

  if raw_details.project_url and raw_details.project_url ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "Project URL",
      value = clean_string(raw_details.project_url),
    })
  end

  if raw_details.download_url and raw_details.download_url ~= "" then
    table.insert(fields, {
      type = "simple",
      label = "Download URL",
      value = clean_string(raw_details.download_url),
    })
  end

  if raw_details.requires_python then
    table.insert(fields, {
      type = "simple",
      label = "Python Required",
      value = clean_string(raw_details.requires_python),
    })
  end

  if raw_details.keywords and type(raw_details.keywords) == "string" and raw_details.keywords ~= "" then
    local keywords = {}
    for keyword in raw_details.keywords:gmatch("([^,]+)") do
      local clean_keyword = keyword:gsub("^%s+", ""):gsub("%s+$", "")
      if clean_keyword ~= "" then
        table.insert(keywords, clean_keyword)
      end
    end
    if #keywords > 0 then
      table.insert(fields, {
        type = "keywords",
        label = "Keywords",
        value = keywords,
      })
    end
  end

  if raw_details.requires_dist and type(raw_details.requires_dist) == "table" and #raw_details.requires_dist > 0 then
    local deps = {}
    for _, dep in ipairs(raw_details.requires_dist) do
      local dep_name = dep:match("^([^%s<>=!]+)")
      local dep_version = dep:match("([<>=!][^;]+)")
      if dep_name then
        deps[dep_name] = dep_version or "any"
      end
    end

    if next(deps) then
      table.insert(fields, {
        type = "dependencies",
        label = "Dependencies",
        value = deps,
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

local function is_pypi_index_valid()
  return pypi_index_cache.packages
      and pypi_index_cache.timestamp
      and (os.time() - pypi_index_cache.timestamp) < pypi_index_cache.ttl
end

local function load_pypi_index_async(callback)
  if is_pypi_index_valid() then
    vim.schedule(function()
      callback(pypi_index_cache.packages)
    end)
    return
  end

  local url = "https://pypi.org/simple/"
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
          local html = table.concat(output, "\n")

          -- Extract package names from <a href="/simple/package-name/">package-name</a>
          for package_name in html:gmatch('<a href="/simple/[^"]+/">([^<]+)</a>') do
            if package_name and package_name ~= "" then
              table.insert(packages, package_name)
            end
          end

          -- Cache the results
          pypi_index_cache.packages = packages
          pypi_index_cache.timestamp = os.time()

          save_cache_to_file()
        end

        callback(packages)
      end)
    end,
  })
end

function M.get_package_latest_version_async(package_name, callback)
  local url = string.format("%s/%s/json", PYPI_API_BASE, package_name)
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
        local latest_version = nil

        if exit_code == 0 then
          local result = table.concat(output, "")
          local success, data = pcall(vim.fn.json_decode, result)

          if success and data and data.info and data.info.version then
            latest_version = data.info.version
          end
        end

        callback(latest_version)
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
          version = pkg_data.version,
          description = pkg_data.summary or "",
          type = "available",
        })
      end
      callback(packages)
    end)
    return
  end

  load_pypi_index_async(function(pypi_packages)
    if not pypi_packages or #pypi_packages == 0 then
      vim.schedule(function()
        callback({})
      end)
      return
    end

    local search_lower = string.lower(search_term)
    local search_normalized = search_lower:gsub("%s+", "") -- Remove spaces
    local matching_packages = {}

    local scored_packages = {}
    for _, package_name in ipairs(pypi_packages) do
      local package_lower = string.lower(package_name)
      local package_normalized = package_lower:gsub("[-_]", "") -- Remove dashes and underscores

      local matches = false
      local relevance_score = 0

      if package_lower == search_lower then
        matches = true
        relevance_score = 1000
      elseif string.sub(package_lower, 1, #search_lower) == search_lower then
        matches = true
        relevance_score = 900
      elseif string.find(package_lower, search_lower, 1, true) then
        matches = true
        local pos = string.find(package_lower, search_lower, 1, true)
        relevance_score = 800 - pos -- Earlier matches score higher
      elseif string.find(package_normalized, search_normalized, 1, true) then
        matches = true
        local pos = string.find(package_normalized, search_normalized, 1, true)
        relevance_score = 700 - pos
      else
        local search_words = {}
        for word in search_lower:gmatch("%S+") do
          table.insert(search_words, word)
        end

        if #search_words > 1 then
          local all_words_found = true
          for _, word in ipairs(search_words) do
            if not string.find(package_lower, word, 1, true) then
              all_words_found = false
              break
            end
          end
          if all_words_found then
            matches = true
            relevance_score = 600 - #package_name -- Shorter names score higher
          end
        end
      end

      if matches then
        table.insert(scored_packages, {
          name = package_name,
          score = relevance_score,
        })

        if #scored_packages >= 100 then -- Increased limit since we'll sort by relevance
          break
        end
      end
    end

    table.sort(scored_packages, function(a, b)
      return a.score > b.score
    end)

    for i = 1, math.min(#scored_packages, 50) do
      table.insert(matching_packages, scored_packages[i].name)
    end

    local packages = {}
    local max_detailed = math.min(#matching_packages, 10)
    local completed = 0

    local function complete_search()
      for i = max_detailed + 1, #matching_packages do
        table.insert(packages, {
          name = matching_packages[i],
          version = "latest",
          description = "",
          type = "available",
        })
      end

      last_search.term = search_term
      last_search.data = packages
      last_search.timestamp = os.time()

      vim.schedule(function()
        callback(packages)
      end)
    end

    if max_detailed == 0 then
      complete_search()
      return
    end

    for i = 1, max_detailed do
      local package_name = matching_packages[i]
      M.get_package_latest_version_async(package_name, function(latest_version)
        table.insert(packages, {
          name = package_name,
          version = latest_version or "latest",
          description = "",
          type = "available",
        })

        completed = completed + 1
        if completed >= max_detailed then
          complete_search()
        end
      end)
    end
  end)
end

function M.get_package_versions_async(package_name, callback)
  local url = string.format("%s/%s/json", PYPI_API_BASE, package_name)
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
            for version, _ in pairs(data.releases) do
              table.insert(versions, { version = version })
            end

            table.sort(versions, function(a, b)
              return a.version > b.version
            end)
          end
        end

        callback(versions)
      end)
    end,
  })
end

function M.get_package_details_async(package_name, callback, version)
  local url
  if version then
    url = string.format("%s/%s/%s/json", PYPI_API_BASE, package_name, version)
  else
    url = string.format("%s/%s/json", PYPI_API_BASE, package_name)
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

        if not success or not data or not data.info then
          callback(nil)
          return
        end

        local details = format_package_details({
          name = data.info.name or package_name,
          summary = data.info.summary or "No summary available",
          version = version or data.info.version,
          author = data.info.author,
          license = data.info.license,
          home_page = data.info.home_page,
          project_url = data.info.project_url,
          download_url = data.info.download_url,
          requires_python = data.info.requires_python,
          keywords = data.info.keywords,
          requires_dist = data.info.requires_dist,
        })
        callback(details)
      end)
    end,
  })
end

function M.parse_package(line)
  if not line then
    return nil
  end

  local name, version = line:match("^([^@%s]+)@([^%s→]+)")
  if name and version then
    local latest_version = line:match("→%s*([^%s]+)")
    return {
      name = name,
      version = version,
      latest_version = latest_version,
      has_update = latest_version and latest_version ~= version,
    }
  end

  local name_space, version_space = line:match("^([^%s]+)%s+([^%s]+)")
  if name_space and version_space then
    return { name = name_space, version = version_space }
  end

  local req_name, req_version = line:match("^([^=<>!]+)==(.+)")
  if req_name and req_version then
    return { name = req_name, version = req_version }
  end

  local simple_name = line:match("^([^=<>!%s@]+)")
  if simple_name then
    return { name = simple_name, version = "latest" }
  end

  return nil
end

M.get_pip_command = get_pip_command
M.format_package_details = format_package_details

return M
