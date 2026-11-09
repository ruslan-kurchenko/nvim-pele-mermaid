local M = {}
local Yank = {}
Yank.__index = Yank

local function read_binary(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local bytes = file:read("*a")
  file:close()
  return bytes
end

function M.new(dependencies)
  dependencies = dependencies or {}
  local is_mac = dependencies.is_mac
  if is_mac == nil then is_mac = vim.uv.os_uname().sysname == "Darwin" end
  return setmetatable({
    runtime = dependencies.runtime,
    system = dependencies.system or vim.system,
    notify = dependencies.notify or vim.notify,
    executable = dependencies.executable or vim.fn.executable,
    read_binary = dependencies.read_binary or read_binary,
    env = dependencies.env or vim.env,
    is_mac = is_mac,
    generation = 0,
  }, Yank)
end

function Yank:stop()
  self.generation = self.generation + 1
  if self.pending then self.pending.cancel(); self.pending = nil end
  if self.provider then
    local provider = self.provider
    self.provider = nil
    pcall(provider.kill, provider, 9)
    if provider.wait then pcall(provider.wait, provider) end
  end
  if self.input then
    if self.input.release then self.input.release() end
    self.input = nil
  end
end

function Yank:current(options)
  options = options or {}
  self:stop()
  local generation = self.generation
  local block = self.runtime:current_block(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  if not block or not block.complete then
    self.notify("pele_mermaid: current Mermaid block is incomplete or missing", vim.log.levels.ERROR)
    return
  end

  local command
  local use_stdin = false
  if self.is_mac and self.executable("osascript") == 1 then
    command = { "osascript", "-e", "on run argv\nset the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)\nend run" }
  elseif not self.is_mac and self.env.WAYLAND_DISPLAY and self.executable("wl-copy") == 1 then
    command = { "wl-copy", "--type", "image/png" }
    use_stdin = true
  elseif not self.is_mac and self.env.DISPLAY and self.executable("xclip") == 1 then
    command = { "xclip", "-selection", "clipboard", "-t", "image/png", "-i" }
  else
    self.notify("pele_mermaid: PNG clipboard requires macOS osascript, Wayland wl-copy, or X11 xclip with an active display", vim.log.levels.ERROR)
    return
  end

  self.pending = self.runtime:request(block, {
    output = "svg", want_png = true, width_px = options.width_px or 1200, scale = 2,
  }, function(result)
    if generation ~= self.generation then
      if result.release then result.release() end
      return
    end
    self.pending = nil
    if not result.ok or not result.png_path then
      if result.release then result.release() end
      self.notify("pele_mermaid: failed to render diagram for clipboard: " .. (result.error or "no PNG produced"), vim.log.levels.ERROR)
      return
    end
    local process_options = { text = false }
    if use_stdin then
      local bytes, err = self.read_binary(result.png_path)
      if not bytes then
        self.notify("pele_mermaid: cannot read clipboard PNG: " .. tostring(err), vim.log.levels.ERROR)
        if result.release then result.release() end
        return
      end
      process_options.stdin = bytes
    else
      command[#command + 1] = result.png_path
    end
    self.input = result
    local ok, process = pcall(self.system, command, process_options, function(res)
      vim.schedule(function()
        if result.release then result.release() end
        if generation ~= self.generation then return end
        self.provider = nil
        self.input = nil
        if res.code == 0 then
          self.notify("pele_mermaid: diagram copied to clipboard (2x PNG)", vim.log.levels.INFO)
        else
          self.notify("pele_mermaid: failed to copy diagram to clipboard: " .. ((res.stderr and res.stderr ~= "") and res.stderr or ("exit " .. tostring(res.code))), vim.log.levels.ERROR)
        end
      end)
    end)
    if ok then
      self.provider = process
    else
      if result.release then result.release() end
      self.input = nil
      self.notify("pele_mermaid: clipboard command failed: " .. tostring(process), vim.log.levels.ERROR)
    end
  end)
  return self.pending
end

return M
