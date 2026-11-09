local log = require("pele_mermaid.log")
local cache_module = require("pele_mermaid.cache")
local rasterizer_module = require("pele_mermaid.deps.rasterizer")
local renderer_module = require("pele_mermaid.deps.renderer")

local M = {}
local Artifact = {}
Artifact.__index = Artifact

local PELE_VERSION = "1.13.0"
local ARTIFACT_FORMAT_VERSION = 3

local function deliver(subscriber, result)
  if subscriber.cancelled or subscriber.delivered then
    if result.release then result.release() end
    return
  end
  subscriber.delivered = true
  local ok, message = pcall(subscriber.callback, result)
  if not ok then
    if result.release then result.release() end
    vim.schedule(function() error(message) end)
  end
end

local function active_subscribers(subscribers)
  local active = {}
  for _, subscriber in ipairs(subscribers) do
    if not subscriber.cancelled and not subscriber.delivered then
      active[#active + 1] = subscriber
    end
  end
  return active
end

function Artifact:_error(subscribers, stage, message)
  for _, subscriber in ipairs(active_subscribers(subscribers)) do
    deliver(subscriber, { ok = false, stage = stage, error = message })
  end
end

-- Each subscriber owns its result until release, independently of cache eviction
-- and the other subscribers sharing the render.
function Artifact:_success(subscriber, key, svg_path, png_path)
  local svg, message = self.cache:stage(svg_path)
  if not svg then self:_error({ subscriber }, "cache", message); return end
  local png
  if png_path then
    png, message = self.cache:stage(png_path)
    if not png then
      svg.release()
      self:_error({ subscriber }, "cache", message)
      return
    end
  end
  deliver(subscriber, {
    ok = true, key = key, svg_path = svg.path, png_path = png and png.path,
    release = function()
      svg.release()
      if png then png.release() end
    end,
  })
end

function Artifact:_resolve_png(svg_key, svg_path, request, subscriber)
  local width = math.max(1, math.floor(request.width_px * (request.scale or 1) + 0.5))
  local png_key = cache_module.key({ svg_key = svg_key, width = width, rasterizer = self.rasterizer_signature })
  local png_path = self.cache:path(png_key, "png")
  local inflight = self.inflight_png[png_key]
  if inflight then
    inflight.subscribers[#inflight.subscribers + 1] = subscriber
    return
  end
  local cached = not request.bypass_cache and self.cache:stage(png_path)
  if cached then
    self.stats.hits = self.stats.hits + 1
    log.write("cache_hit", { kind = "png", key = png_key })
    self:_success(subscriber, png_key, svg_path, cached.path)
    cached.release()
    return
  end

  self.stats.misses = self.stats.misses + 1
  log.write("cache_miss", { kind = "png", key = png_key })
  self.stats.rasters = self.stats.rasters + 1
  local input, message = self.cache:stage(svg_path)
  if not input then self:_error({ subscriber }, "cache", message); return end
  inflight = {
    subscribers = { subscriber },
    temporary = self.cache:temporary_path(png_path),
    release = input.release,
  }
  self.inflight_png[png_key] = inflight
  inflight.operation = self.rasterizer:rasterize(input.path, inflight.temporary, width, function(result)
    if self.inflight_png[png_key] ~= inflight then
      return
    end
    if not result.ok then
      inflight.release()
      self.cache:discard_temporary(inflight.temporary)
      self.inflight_png[png_key] = nil
      self:_error(inflight.subscribers, "rasterizer", result.error)
      return
    end
    self.cache:commit_temporary(inflight.temporary, png_path, function(ok, error_message, stable_path)
      if self.inflight_png[png_key] ~= inflight then
        return
      end
      self.inflight_png[png_key] = nil
      if not ok then
        inflight.release()
        self:_error(inflight.subscribers, "cache", error_message)
        return
      end
      for _, current in ipairs(active_subscribers(inflight.subscribers)) do
        self:_success(current, png_key, input.path, stable_path)
      end
      inflight.release()
    end)
  end)
end

function Artifact:_complete_svg(svg_key, svg_path, subscribers)
  for _, subscriber in ipairs(active_subscribers(subscribers)) do
    if subscriber.request.want_png then
      self:_resolve_png(svg_key, svg_path, subscriber.request, subscriber)
    else
      self:_success(subscriber, svg_key, svg_path)
    end
  end
end

function Artifact:_resolve_svg(key, path, request, subscriber)
  local inflight = self.inflight_render[key]
  if inflight then
    inflight.subscribers[#inflight.subscribers + 1] = subscriber
    return
  end
  local cached = not request.bypass_cache and self.cache:stage(path)
  if cached then
    self.stats.hits = self.stats.hits + 1
    log.write("cache_hit", { kind = "svg", key = key })
    self:_complete_svg(key, cached.path, { subscriber })
    cached.release()
    return
  end

  self.stats.misses = self.stats.misses + 1
  log.write("cache_miss", { kind = "svg", key = key })
  self.stats.renders = self.stats.renders + 1
  inflight = { subscribers = { subscriber } }
  self.inflight_render[key] = inflight
  inflight.operation = self.renderer:render({
    source = request.source,
    output = "svg",
    theme = request.theme,
    options = request.options,
  }, function(result)
    if self.inflight_render[key] ~= inflight then
      return
    end
    if not result.ok then
      self.inflight_render[key] = nil
      self:_error(inflight.subscribers, "renderer", result.error)
      return
    end
    self.cache:atomic_write(path, result.output, function(ok, error_message, stable_path)
      if self.inflight_render[key] ~= inflight then
        return
      end
      self.inflight_render[key] = nil
      if not ok then
        self:_error(inflight.subscribers, "cache", error_message)
        return
      end
      self:_complete_svg(key, stable_path, inflight.subscribers)
    end)
  end)
end

function Artifact:resolve(request, callback)
  assert(type(request) == "table", "artifact request must be a table")
  assert(type(request.source) == "string", "artifact source must be a string")
  assert(type(callback) == "function", "artifact callback must be a function")
  if request.want_png then
    assert(type(request.width_px) == "number" and request.width_px > 0 and request.width_px < math.huge,
      "PNG artifacts require finite positive width_px")
    local scale = request.scale or 1
    assert(type(scale) == "number" and scale > 0 and request.width_px * scale < math.huge,
      "PNG scale must be finite and positive")
  end

  local output = request.output or "svg"
  assert(output == "svg", "Pele artifacts support SVG output only")
  local key = cache_module.key({
    version = PELE_VERSION,
    artifact_format = ARTIFACT_FORMAT_VERSION,
    renderer = self.renderer_signature,
    source = request.source,
    theme_signature = request.theme_signature,
    theme = request.theme,
    options = request.options or {},
    output = output,
  })
  local subscriber = {
    callback = callback,
    request = request,
    cancelled = false,
    delivered = false,
  }

  self:_resolve_svg(key, self.cache:path(key, "svg"), request, subscriber)

  return {
    cancel = function()
      if subscriber.cancelled or subscriber.delivered then
        return false
      end
      subscriber.cancelled = true
      for _, pending in ipairs({ self.inflight_render, self.inflight_png }) do
        for pending_key, inflight in pairs(pending) do
          if #active_subscribers(inflight.subscribers) == 0 then
            pending[pending_key] = nil
            if inflight.release then inflight.release() end
            if inflight.temporary then self.cache:discard_temporary(inflight.temporary) end
            if inflight.operation then inflight.operation.cancel() end
          end
        end
      end
      return true
    end,
  }
end

function Artifact:stop(reason)
  local renders, rasters = self.inflight_render, self.inflight_png
  self.inflight_render = {}
  self.inflight_png = {}
  for _, inflight in pairs(renders) do
    self:_error(inflight.subscribers, "renderer", reason or "artifact pipeline stopped")
  end
  for _, inflight in pairs(rasters) do
    self:_error(inflight.subscribers, "rasterizer", reason or "artifact pipeline stopped")
    inflight.release()
    self.cache:discard_temporary(inflight.temporary)
    if inflight.operation then inflight.operation.cancel() end
  end
  self.renderer:stop(reason)
  self.rasterizer:stop()
  if self.cache.stop then self.cache:stop() end
end

function Artifact:is_available()
  return self.renderer:is_available() and self.rasterizer:is_available()
end

function M.new(config, dependencies)
  dependencies = dependencies or {}
  local cache = dependencies.cache or cache_module.new(config.cache)
  local renderer = dependencies.renderer or renderer_module.new(config.renderer)
  local rasterizer = dependencies.rasterizer or rasterizer_module.new(config)
  return setmetatable({
    cache = cache,
    renderer = renderer,
    rasterizer = rasterizer,
    renderer_signature = { command = config.renderer and config.renderer.command, script = config.renderer and config.renderer.script },
    rasterizer_signature = { command = config.rasterizer and config.rasterizer.command, dpi = config.rasterizer and config.rasterizer.dpi or rasterizer_module.DPI },
    schedule = dependencies.schedule or vim.schedule,
    inflight_render = {},
    inflight_png = {},
    stats = { hits = 0, misses = 0, renders = 0, rasters = 0 },
  }, Artifact)
end

return M
