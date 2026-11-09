local runtime = require("pele_mermaid.deps.runtime")
local worker = require("pele_mermaid.deps.worker")
local M = {}
local Renderer = {}
Renderer.__index = Renderer
local root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h:h")

function M.script_path(options)
  return options and options.script or (root .. "/scripts/renderer.js")
end

function Renderer:render(request, callback)
  assert(request.output == nil or request.output == "svg", "Pele supports SVG output only")
  local entry = { callback = callback }
  self.pending[entry] = true
  local function complete(result)
    if not self.pending[entry] then return end
    self.pending[entry] = nil
    callback(result)
  end
  local operation = {
    cancel = function()
      if not self.pending[entry] then return false end
      if entry.cancel then entry.cancel() end
      complete({ ok = false, cancelled = true, error = "render cancelled" })
      return true
    end,
  }
  entry.operation = operation
  local command, error_message = runtime.resolve({ renderer = self.options })
  if not command then
    complete({ ok = false, error = error_message })
    return operation
  end
  self.command = command
  local payload = vim.json.encode({
    text = request.source,
    format = "svg",
    theme = request.theme,
    options = request.options or {},
    -- Cached SVGs are also export artifacts, so never rely on installed fonts.
    embed_fonts = true,
  })
  if not self.options.script then
    entry.cancel = worker.request(command, M.script_path(self.options), payload, self.options.timeout_ms, complete)
    return operation
  end

  local ok, process = pcall(vim.system, { command, self.options.script }, {
    text = true,
    stdin = payload,
    timeout = self.options.timeout_ms,
  }, function(result)
    vim.schedule(function()
      local decoded_ok, decoded = pcall(vim.json.decode, result.stdout or "")
      if result.code == 124 then
        complete({ ok = false, error = "pele_mermaid: renderer timed out" })
      elseif result.code ~= 0 then
        local message = result.stderr and vim.trim(result.stderr) or ""
        if message == "" and decoded_ok and type(decoded) == "table" then message = decoded.error or "" end
        if message == "" then message = "pele_mermaid: renderer exited with code " .. result.code end
        complete({ ok = false, error = message })
      elseif not decoded_ok or type(decoded) ~= "table" then
        complete({ ok = false, error = "pele_mermaid: invalid renderer response" })
      elseif type(decoded.error) == "string" then
        complete({ ok = false, error = decoded.error })
      elseif type(decoded.output) ~= "string" or decoded.output == "" then
        complete({ ok = false, error = "pele_mermaid: invalid renderer response" })
      else
        complete({ ok = true, output = decoded.output })
      end
    end)
  end)
  if not ok then
    complete({ ok = false, error = tostring(process) })
  else
    entry.cancel = function() pcall(process.kill, process, 9) end
  end
  return operation
end

function Renderer:is_available()
  return runtime.resolve({ renderer = self.options }) ~= nil
end

function Renderer:stop(reason)
  local pending = self.pending
  self.pending = {}
  for entry in pairs(pending) do
    if entry.cancel then entry.cancel() end
    local ok, message = pcall(entry.callback, { ok = false, error = reason or "renderer stopped" })
    if not ok then vim.schedule(function() error(message) end) end
  end
  if self.command and not self.options.script then
    worker.stop(self.command, M.script_path(self.options), reason)
  end
end

function M.new(options)
  return setmetatable({ options = vim.tbl_extend("force", { command = "auto", timeout_ms = 10000 }, options or {}), pending = {} }, Renderer)
end

return M
