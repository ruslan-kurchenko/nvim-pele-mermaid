local module = require("pele_mermaid.deps.rasterizer")

local function fixture(options)
  local state = {
    systems = {}, requests = {}, timers = {}, files = { ["input.svg"] = "<svg>Maple</svg>" },
    removed = {}, killed = 0, cancelled = 0, snapshots = {},
  }
  local raster = module.new({ renderer = {}, rasterizer = options or { timeout_ms = 1000 } }, {
    get_command = function() return "resvg" end,
    resolve = function() return "/test/bun" end,
    stage = function(path)
      if not state.files[path] then return nil, "missing input" end
      local private = "private-" .. (#state.snapshots + 1) .. ".svg"
      state.files[private] = state.files[path]
      state.snapshots[#state.snapshots + 1] = private
      return { path = private, release = function()
        state.files[private] = nil
        state.removed[private] = true
      end }
    end,
    read_svg = function(path) return state.files[path], "missing input" end,
    write_svg = function(path, content) state.files[path] = content; return true end,
    unlink = function(path) state.removed[path] = true; state.files[path] = nil; return true end,
    stat = function(path) return state.files[path] and { size = #state.files[path] } or nil end,
    rename = function(from, to)
      if not state.files[from] then return nil, "missing output" end
      state.files[to] = state.files[from]; state.files[from] = nil; return true
    end,
    schedule = function(callback) callback() end,
    new_timer = function()
      local timer = {}
      function timer:start(_, _, callback) self.callback = callback end
      function timer:stop() self.stopped = true end
      function timer:close() self.closed = true end
      state.timers[#state.timers + 1] = timer
      return timer
    end,
    request = function(_, _, payload, _, callback)
      state.requests[#state.requests + 1] = { payload = vim.json.decode(payload), callback = callback }
      return function() state.cancelled = state.cancelled + 1 end
    end,
    system = function(argv, _, callback)
      state.systems[#state.systems + 1] = { argv = argv, callback = callback }
      return { kill = function() state.killed = state.killed + 1 end }
    end,
  })
  function state:outline(index)
    self.requests[index].callback({ ok = true, output = "<svg><path/></svg>" })
  end
  function state:complete(index, code)
    local process = self.systems[index]
    self.files[process.argv[#process.argv]] = "PNG"
    process.callback({ code = code or 0, stderr = "" })
  end
  return raster, state
end

local raster, state = fixture()
local results = {}
for index = 1, 3 do
  raster:rasterize("input.svg", "output" .. index .. ".png", 400, function(result) results[index] = result end)
end
assert(#state.requests == 2 and raster.active == 2, "only two outline/raster pipelines may run")
assert(state.requests[1].payload.operation == "outline" and state.requests[1].payload.svg == "<svg>Maple</svg>")
assert(#state.timers == 0, "outline queue time must not consume the raster subprocess deadline")
assert(#state.snapshots == 3, "queued inputs must be made private before admission")
state.files["input.svg"] = nil -- Another editor evicts the shared source.
state:outline(1)
state:outline(2)
assert(#state.systems == 2 and state.systems[1].argv[3] == "400")
state:complete(1)
assert(results[1].ok and state.files["output1.png"] == "PNG")
assert(#state.requests == 3 and raster.active == 2, "completion must admit exactly one queued raster")
assert(state.requests[3].payload.svg == "<svg>Maple</svg>", "queued input must survive shared source eviction")
state:outline(3)
state:complete(2)
state:complete(3)
assert(raster.active == 0 and next(raster.jobs) == nil)
for _, timer in ipairs(state.timers) do assert(timer.closed) end
for _, path in ipairs(state.snapshots) do assert(state.removed[path], "finished raster input must be released") end
state.files["input.svg"] = "<svg>Maple</svg>"

local timeout
raster:rasterize("input.svg", "timeout.png", 400, function(result) timeout = result end)
state:outline(4)
state.timers[4].callback()
assert(timeout and not timeout.ok and timeout.error == "rasterizer timed out" and state.killed == 1)
state:complete(4)
assert(not state.files["timeout.png"], "a late killed process must not publish its output")
assert(not state.files[state.systems[4].argv[#state.systems[4].argv]], "late partial output must be cleaned")

local preparing, prep = fixture()
local operation = preparing:rasterize("input.svg", "cancelled.png", 200, function() error("cancelled callback") end)
assert(operation.cancel() and not operation.cancel())
assert(prep.cancelled == 1 and preparing.active == 0 and #prep.timers == 0)
assert(prep.removed[prep.snapshots[1]])
prep:outline(1)
assert(#prep.systems == 0, "a cancelled outline may not spawn a raster")

local queued, queue_state = fixture()
queued:rasterize("input.svg", "one.png", 200, function() error("stopped callback") end)
queued:rasterize("input.svg", "two.png", 200, function() error("stopped callback") end)
local third = queued:rasterize("input.svg", "three.png", 200, function() error("cancelled queued callback") end)
assert(third.cancel() and #queue_state.requests == 2)
queued:stop()
assert(queued.active == 0 and next(queued.jobs) == nil and #queued.queue == 0)
assert(queue_state.cancelled == 2 and #queue_state.requests == 2, "stop must not start queued work")

local failed, failure = fixture()
local failed_result
failure.files["cached.png"] = "previous image"
failed:rasterize("input.svg", "cached.png", 200, function(result) failed_result = result end)
failure:outline(1)
failure:complete(1, 7)
assert(not failed_result.ok and failed_result.error:find("code 7", 1, true))
assert(failure.files["cached.png"] == "previous image", "failed output must not replace the previous image")
assert(not failure.files[failure.systems[1].argv[#failure.systems[1].argv]])

local missing, missing_state = fixture()
missing_state.files["input.svg"] = nil
local missing_result
local missing_operation = missing:rasterize("input.svg", "missing.png", 200, function(result) missing_result = result end)
assert(not missing_result.ok and missing_result.error == "missing input")
assert(not missing_operation.cancel() and #missing_state.requests == 0, "unstageable input must not enter the queue")
