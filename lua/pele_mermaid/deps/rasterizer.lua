local runtime = require("pele_mermaid.deps.runtime")
local worker = require("pele_mermaid.deps.worker")
local cache = require("pele_mermaid.cache")
local M = { DPI = 96 }
local Rasterizer = {}
Rasterizer.__index = Rasterizer
local root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h:h")

function M.get_command(options)
  options = options and options.rasterizer or options or {}
  local command = options.command or "auto"
  if command ~= "auto" then
    return vim.fn.executable(command) == 1 and command or nil
  end
  for _, candidate in ipairs({ "resvg", "rsvg-convert", "magick", "convert" }) do
    if vim.fn.executable(candidate) == 1 then return candidate end
  end
end

local function arguments(command, svg, png, width, dpi)
  local kind = vim.fn.fnamemodify(command, ":t"):gsub("%.exe$", "")
  if kind == "resvg" then
    return { command, "--width", tostring(width), "--dpi", tostring(dpi), svg, png }
  elseif kind == "rsvg-convert" then
    return { command, "-w", tostring(width), "-a", "-d", tostring(dpi), "-p", tostring(dpi), "-o", png, svg }
  elseif kind == "magick" or kind == "convert" then
    return { command, "-density", tostring(dpi), svg, "-resize", tostring(width) .. "x", "png:" .. png }
  end
end

local function read_svg(path)
  local file, message = io.open(path, "rb")
  if not file then return nil, message end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function write_svg(path, contents)
  local file, message = io.open(path, "wb")
  if not file then return nil, message end
  local written, write_error = file:write(contents)
  local closed, close_error = file:close()
  return written and closed, write_error or close_error
end

function Rasterizer:_cleanup(job)
  if job.input then job.input.release() end
  if job.outlined then self.deps.unlink(job.outlined) end
  if job.output then self.deps.unlink(job.output) end
end

function Rasterizer:_finish(job, result)
  if job.done then return end
  job.done = true
  self.jobs[job] = nil
  if job.timer then
    job.timer:stop()
    job.timer:close()
  end
  if job.cancel_prepare then
    local cancel = job.cancel_prepare
    job.cancel_prepare = nil
    cancel()
  end
  self:_cleanup(job)
  if job.active then
    job.active = false
    self.active = self.active - 1
  end
  if not job.cancelled then
    local ok, message = pcall(job.callback, result)
    if not ok then self.deps.schedule(function() error(message) end) end
  end
  self:_pump()
end

function Rasterizer:_spawn(job, argv, preparing)
  local timeout = self.options.timeout_ms or 3000
  if timeout > 0 and not job.timer then
    job.timer = self.deps.new_timer()
    job.timer:start(timeout, 0, function()
      self.deps.schedule(function()
        if job.done then return end
        if job.process then pcall(job.process.kill, job.process, 9) end
        self:_finish(job, { ok = false, error = "rasterizer timed out" })
      end)
    end)
  end
  local ok, process = pcall(self.deps.system, argv, { text = true }, function(result)
    self.deps.schedule(function()
      if job.done then self:_cleanup(job); return end
      job.process = nil
      if result.code ~= 0 then
        local message = result.stderr and vim.trim(result.stderr) or ""
        if message == "" then
          message = (preparing and "SVG font preparation" or "rasterizer") .. " exited with code " .. result.code
        end
        self:_finish(job, { ok = false, error = message })
      elseif preparing then
        self:_spawn(job, job.arguments, false)
      else
        local stat = self.deps.stat(job.output)
        if not stat or stat.size == 0 then
          self:_finish(job, { ok = false, error = "rasterizer produced no PNG" })
          return
        end
        local renamed, message = self.deps.rename(job.output, job.png_path)
        self:_finish(job, { ok = not not renamed, error = message })
      end
    end)
  end)
  if not ok then
    self:_finish(job, { ok = false, error = tostring(process) })
  elseif not job.done then
    job.process = process
  end
end

function Rasterizer:_start(job)
  job.active = true
  self.active = self.active + 1
  local command = self:get_command()
  local renderer_command, message = self.deps.resolve(self.config)
  if not command or not renderer_command then
    self:_finish(job, { ok = false, error = message or "no rasterizer command available" })
    return
  end
  job.outlined = vim.fn.tempname() .. ".svg"
  job.output = job.png_path .. "." .. vim.fn.getpid() .. "." .. tostring(vim.uv.hrtime()) .. ".png"
  job.arguments = arguments(command, job.outlined, job.output, job.width, self.options.dpi or M.DPI)
  if not job.arguments then
    self:_finish(job, { ok = false, error = "unsupported rasterizer command: " .. command })
    return
  end
  local timeout = self.options.timeout_ms or 3000
  if self.config.renderer and self.config.renderer.script then
    self:_spawn(job, { renderer_command, root .. "/scripts/outline-svg.js", job.svg_path, job.outlined }, true)
    return
  end
  local svg, read_error = self.deps.read_svg(job.svg_path)
  if not svg then self:_finish(job, { ok = false, error = read_error }); return end
  job.cancel_prepare = self.deps.request(renderer_command, root .. "/scripts/renderer.js",
    vim.json.encode({ operation = "outline", svg = svg }), timeout, function(result)
      if job.done then return end
      job.cancel_prepare = nil
      if not result.ok then self:_finish(job, result); return end
      local written, write_error = self.deps.write_svg(job.outlined, result.output)
      if not written then self:_finish(job, { ok = false, error = write_error }); return end
      self:_spawn(job, job.arguments, false)
    end)
end

function Rasterizer:_pump()
  if self.stopping or self.pumping then return end
  self.pumping = true
  while self.active < 2 and #self.queue > 0 do
    local job = table.remove(self.queue, 1)
    if not job.done then self:_start(job) end
  end
  self.pumping = false
end

function Rasterizer:rasterize(svg_path, png_path, width, callback)
  assert(type(width) == "number" and width > 0 and width < math.huge, "raster width must be positive and finite")
  local input, message = self.deps.stage(svg_path)
  if not input then
    callback({ ok = false, error = message })
    return { cancel = function() return false end }
  end
  local job = {
    input = input, svg_path = input.path, png_path = png_path,
    width = math.max(1, math.floor(width + 0.5)), callback = callback,
  }
  self.jobs[job] = true
  self.queue[#self.queue + 1] = job
  self:_pump()
  return { cancel = function()
    if job.done then return false end
    job.cancelled = true
    if job.process then pcall(job.process.kill, job.process, 9) end
    self:_finish(job, { ok = false, error = "rasterization cancelled" })
    return true
  end }
end

function Rasterizer:get_command()
  return self.deps.get_command(self.options)
end

function Rasterizer:is_available()
  return self:get_command() ~= nil and self.deps.resolve(self.config) ~= nil
end

function Rasterizer:stop()
  self.stopping = true
  local jobs = {}
  for job in pairs(self.jobs) do jobs[#jobs + 1] = job end
  for _, job in ipairs(jobs) do
    job.cancelled = true
    if job.process then pcall(job.process.kill, job.process, 9) end
    self:_finish(job, { ok = false, error = "rasterizer stopped" })
  end
  self.queue = {}
  self.stopping = false
end

function M.new(config, dependencies)
  config = config or {}
  dependencies = dependencies or {}
  return setmetatable({
    config = config,
    options = config.rasterizer or {},
    deps = {
      system = dependencies.system or vim.system,
      new_timer = dependencies.new_timer or vim.uv.new_timer,
      schedule = dependencies.schedule or vim.schedule,
      resolve = dependencies.resolve or runtime.resolve,
      request = dependencies.request or worker.request,
      get_command = dependencies.get_command or M.get_command,
      read_svg = dependencies.read_svg or read_svg,
      stage = dependencies.stage or cache.stage,
      write_svg = dependencies.write_svg or write_svg,
      unlink = dependencies.unlink or vim.uv.fs_unlink,
      rename = dependencies.rename or vim.uv.fs_rename,
      stat = dependencies.stat or vim.uv.fs_stat,
    },
    active = 0,
    queue = {},
    jobs = {},
  }, Rasterizer)
end

return M
