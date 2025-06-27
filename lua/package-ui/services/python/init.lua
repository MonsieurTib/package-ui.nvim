local M = {}

local function detect_python_tool()
  local cwd = vim.fn.getcwd()

  if vim.fn.filereadable(cwd .. "/pyproject.toml") == 1 then
    return "poetry"
  end

  if vim.fn.filereadable(cwd .. "/Pipfile") == 1 then
    return "pipenv"
  end

  return "pip"
end

function M.get_service()
  local tool = detect_python_tool()
  return require("package-ui.services.python." .. tool .. "_service")
end

M.detect_python_tool = detect_python_tool

return M

