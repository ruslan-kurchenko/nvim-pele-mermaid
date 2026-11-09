local M = {}
local checked_nodes = {}

local function executable(command)
  local path = vim.fn.exepath(command)
  return path ~= "" and path or nil
end

local function bun_path()
  local path = executable("bun")
  if path then
    return path
  end

  local name = vim.fn.has("win32") == 1 and "bun.exe" or "bun"
  local install = vim.env.BUN_INSTALL
  if install and install ~= "" then
    path = executable(vim.fs.joinpath(install, "bin", name))
    if path then
      return path
    end
  end

  local home = vim.uv.os_homedir()
  if home then
    return executable(vim.fs.joinpath(home, ".bun", "bin", name))
  end
end

-- Resolve at execution/health boundaries, never while reading configuration.
-- Explicit commands are authoritative: a typo must not select another runtime.
function M.resolve(cfg)
  local command = cfg.renderer and cfg.renderer.command
  if command == nil then
    command = "auto"
  end
  if type(command) ~= "string" or command == "" then
    return nil, "pele_mermaid: renderer.command must be 'auto', 'bun', 'node', or an executable path"
  end

  local path
  if command == "auto" or command == "bun" then
    path = bun_path()
    if not path and command == "auto" then
      path = executable("node")
    end
  else
    path = executable(command)
  end
  if path then
    local name = vim.fn.fnamemodify(path, ":t"):gsub("%.exe$", "")
    if name == "node" and not checked_nodes[path] then
      local ok, result = pcall(function()
        return vim.system({ path, "--version" }, { text = true, timeout = 1000 }):wait()
      end)
      local major = ok and result.code == 0 and tonumber((result.stdout or ""):match("^v(%d+)%."))
      if not major or major < 20 then
        return nil, "pele_mermaid: Node.js >=20 is required: " .. path .. "; upgrade Node.js or install Bun"
      end
      checked_nodes[path] = true
    end
    return path
  end

  if command == "auto" or command == "bun" then
    local fallback = command == "auto" and ", or install Node.js >=20 on PATH" or ""
    return nil, "pele_mermaid: renderer runtime unavailable; install Bun on PATH, in $BUN_INSTALL/bin or ~/.bun/bin"
      .. fallback .. "; or set renderer.command to an executable's absolute path"
  end
  return nil, "pele_mermaid: renderer.command is not executable: " .. command
    .. "; set it to an executable's absolute path or use 'auto'"
end

return M
