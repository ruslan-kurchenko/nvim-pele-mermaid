local artifact_module = require("pele_mermaid.artifact")
local fake_cache = { files = {}, fail_write = false }
function fake_cache:path(key, extension) return key .. "." .. extension end
function fake_cache:exists(path) return self.files[path] ~= nil end
function fake_cache:stage(path)
  if not self.files[path] then return nil, "missing artifact" end
  self.leases = (self.leases or 0) + 1
  local released = false
  return { path = path, release = function()
    if not released then self.leases = self.leases - 1; released = true end
  end }
end
function fake_cache:read(path, callback) callback(self.files[path] ~= nil, self.files[path]) end
function fake_cache:temporary_path(path) return path .. ".tmp" end
function fake_cache:discard_temporary(path) self.discarded = path end
function fake_cache:atomic_write(path, content, callback)
  if self.fail_write then callback(false, "disk full") return end
  self.files[path] = content
  callback(true, path, path)
end
function fake_cache:commit_temporary(_, path, callback)
  self.files[path] = "png"
  callback(true, path, path)
end

local fake_renderer = { requests = {}, callbacks = {} }
function fake_renderer:render(request, callback)
  self.requests[#self.requests + 1] = request
  self.callbacks[#self.callbacks + 1] = callback
  return { cancel = function() self.cancelled = (self.cancelled or 0) + 1 end }
end
function fake_renderer:is_available() return true end
function fake_renderer:stop() end

local fake_rasterizer = { requests = {}, callbacks = {} }
function fake_rasterizer:rasterize(svg_path, png_path, width, callback)
  self.requests[#self.requests + 1] = { svg_path, png_path, width }
  self.callbacks[#self.callbacks + 1] = callback
  return { cancel = function() self.cancelled = (self.cancelled or 0) + 1; return true end }
end
function fake_rasterizer:is_available() return true end
function fake_rasterizer:stop() end

local pipeline = artifact_module.new({ cache = {}, renderer = {}, rasterizer = {} }, {
  cache = fake_cache,
  renderer = fake_renderer,
  rasterizer = fake_rasterizer,
  schedule = function(callback) callback() end,
})
local base_request = {
  source = "flowchart LR\nA --> B",
  source_hash = "source",
  theme_signature = "theme",
  options = {},
  width_px = 600,
}

local deduplicated = {}
pipeline:resolve(base_request, function(result) deduplicated[#deduplicated + 1] = result end)
local cancelled = pipeline:resolve(base_request, function() error("cancelled subscriber called") end)
assert(cancelled.cancel())
pipeline:resolve(base_request, function(result) deduplicated[#deduplicated + 1] = result end)
assert(#fake_renderer.requests == 1)
fake_renderer.callbacks[1]({ ok = true, output = "<svg></svg>" })
assert(#deduplicated == 2 and deduplicated[1].svg_path == deduplicated[2].svg_path)
local svg_hit
local renders_before_hit = #fake_renderer.requests
pipeline:resolve(base_request, function(result) svg_hit = result end)
assert(svg_hit and svg_hit.ok and #fake_renderer.requests == renders_before_hit)

local png_results = {}
local png_request = vim.tbl_extend("force", base_request, { want_png = true })
pipeline:resolve(png_request, function(result) png_results[#png_results + 1] = result end)
pipeline:resolve(png_request, function(result) png_results[#png_results + 1] = result end)
assert(#fake_rasterizer.requests == 1)
fake_rasterizer.callbacks[1]({ ok = true })
assert(#png_results == 2 and png_results[1].png_path == png_results[2].png_path)
local png_hit
local rasters_before_hit = #fake_rasterizer.requests
pipeline:resolve(png_request, function(result) png_hit = result end)
assert(png_hit and png_hit.ok and #fake_rasterizer.requests == rasters_before_hit)

local raster_error
local broken_png = vim.tbl_extend("force", png_request, { source = "flowchart LR\nR --> E" })
pipeline:resolve(broken_png, function(result) raster_error = result end)
fake_renderer.callbacks[2]({ ok = true, output = "<svg></svg>" })
fake_rasterizer.callbacks[2]({ ok = false, error = "resvg failed" })
assert(raster_error and not raster_error.ok and raster_error.stage == "rasterizer")

local bypassed
pipeline:resolve(vim.tbl_extend("force", base_request, { bypass_cache = true }), function(result) bypassed = result end)
assert(fake_cache.discarded and fake_cache.discarded:sub(-4) == ".tmp")
assert(#fake_renderer.requests == 3)
fake_renderer.callbacks[3]({ ok = true, output = "<svg>fresh</svg>" })
assert(bypassed and bypassed.ok)

fake_cache.fail_write = true
local cache_error
pipeline:resolve(vim.tbl_extend("force", base_request, { source = "flowchart LR\nX --> Y" }), function(result) cache_error = result end)
fake_renderer.callbacks[4]({ ok = true, output = "<svg></svg>" })
assert(cache_error and not cache_error.ok and cache_error.stage == "cache")
fake_cache.fail_write = false

local scaled
pipeline:resolve(vim.tbl_extend("force", png_request, { scale = 2 }), function(result) scaled = result end)
assert(#fake_renderer.requests == 4 and fake_rasterizer.requests[3][3] == 1200)
fake_rasterizer.callbacks[3]({ ok = true })
assert(scaled.ok and scaled.key ~= png_hit.key)
local same_pixels
pipeline:resolve(vim.tbl_extend("force", png_request, { width_px = 1200 }), function(result) same_pixels = result end)
assert(same_pixels.key == scaled.key and #fake_rasterizer.requests == 3)
assert(not pcall(function() pipeline:resolve(vim.tbl_extend("force", png_request, { scale = 0 }), function() end) end))
assert(not pcall(function() pipeline:resolve({ source = "x", output = "ascii" }, function() end) end))

local only = pipeline:resolve({ source = "flowchart LR\nOnly-->Cancelled" }, function() error("cancelled render delivered") end)
assert(only.cancel() and fake_renderer.cancelled == 1)
fake_renderer.callbacks[5]({ ok = true, output = "late" })
assert(next(pipeline.inflight_render) == nil)
local abandoned_png = pipeline:resolve(vim.tbl_extend("force", png_request, { width_px = 900 }),
  function() error("cancelled raster delivered") end)
local leases_before_cancel = fake_cache.leases
assert(abandoned_png.cancel() and fake_rasterizer.cancelled == 1 and fake_cache.leases == leases_before_cancel - 1)
fake_rasterizer.callbacks[4]({ ok = true })
assert(next(pipeline.inflight_png) == nil)

local stopped
pipeline:resolve({ source = "flowchart LR\nStop-->Waiting" }, function(result) stopped = result end)
pipeline:stop("stopped")
assert(stopped and stopped.error == "stopped")
fake_renderer.callbacks[6]({ ok = true, output = "late stopped output" })
assert(not stopped.ok)


pipeline:stop("test complete")
for _, result in ipairs(deduplicated) do result.release() end
for _, result in ipairs(png_results) do result.release() end
for _, result in ipairs({ svg_hit, png_hit, bypassed, scaled, same_pixels }) do result.release(); result.release() end
assert(fake_cache.leases == 0, "all independent subscriber leases must be released")

-- Real files: a second editor can evict the entire shared cache without
-- invalidating successful artifacts, including their companion SVG.
local cache_module = require("pele_mermaid.cache")
local directory = vim.fn.tempname()
local cache = cache_module.new({}, { directory = directory })
local renders = 0
local real = artifact_module.new({}, {
  cache = cache,
  renderer = {
    render = function(_, _, callback)
      renders = renders + 1
      callback({ ok = true, output = "<svg>private</svg>" })
      return { cancel = function() end }
    end,
    stop = function() end,
  },
  rasterizer = {
    rasterize = function(_, input, output, _, callback)
      assert(vim.fn.readfile(input)[1] == "<svg>private</svg>")
      vim.fn.writefile({ "PNG" }, output)
      callback({ ok = true })
      return { cancel = function() end }
    end,
    stop = function() end,
  },
})
local retained = {}
for _ = 1, 2 do
  real:resolve({ source = "private", want_png = true, width_px = 100 }, function(result)
    assert(result.ok, result.error)
    retained[#retained + 1] = result
  end)
end
assert(vim.wait(1000, function() return #retained == 2 end, 5))
assert(renders == 1 and retained[1].png_path ~= retained[2].png_path)
local evictor = cache_module.new({ max_bytes = 0 }, { directory = directory })
for _, result in ipairs(retained) do
  assert(vim.fn.readfile(result.svg_path)[1] == "<svg>private</svg>")
  assert(vim.fn.readfile(result.png_path)[1] == "PNG")
end
retained[1].release()
assert(vim.fn.filereadable(retained[1].png_path) == 0 and vim.fn.filereadable(retained[2].png_path) == 1)
retained[2].release()
real:stop()
evictor:stop()
vim.fn.delete(directory, "rf")
