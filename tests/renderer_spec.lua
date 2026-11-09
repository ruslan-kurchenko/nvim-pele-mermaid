local runtime = require("pele_mermaid.deps.runtime")
local worker = require("pele_mermaid.deps.worker")
local module = require("pele_mermaid.deps.renderer")
local saved = { resolve = runtime.resolve, request = worker.request, stop = worker.stop, system = vim.system, schedule = vim.schedule }
local ok, message = xpcall(function()
  local payload, finish, cancelled, stopped = nil, nil, 0, 0
  runtime.resolve = function(config)
    assert(config.renderer.command == "auto")
    return "/test/bun"
  end
  worker.request = function(command, script, encoded, timeout, callback)
    assert(command == "/test/bun" and script:match("/scripts/renderer.js$") and timeout == 5000)
    payload, finish = vim.json.decode(encoded), callback
    return function() cancelled = cancelled + 1; callback({ ok = false, cancelled = true }) end
  end
  worker.stop = function() stopped = stopped + 1 end
  local renderer = module.new({ command = "auto", timeout_ms = 5000 })
  local result, calls = nil, 0
  local operation = renderer:render({ source = "flowchart LR\nA-->B", theme = "dark", options = { font = "Maple Mono NF" } }, function(value)
    result = value; calls = calls + 1
  end)
  assert(payload.text == "flowchart LR\nA-->B" and payload.format == "svg" and payload.theme == "dark")
  assert(payload.embed_fonts == true and payload.options.font == "Maple Mono NF", "shared exports must embed bundled fonts")
  finish({ ok = true, output = "<svg/>" })
  assert(result.ok and calls == 1 and not operation.cancel())

  operation = renderer:render({ source = "flowchart LR\nC-->D" }, function(value) result = value; calls = calls + 1 end)
  assert(operation.cancel() and result.cancelled and cancelled == 1 and calls == 2)
  finish({ ok = true, output = "late" })
  assert(calls == 2)
  renderer:render({ source = "flowchart LR\nE-->F" }, function(value) result = value; calls = calls + 1 end)
  renderer:stop("shutdown")
  assert(result.error == "shutdown" and calls == 3 and stopped == 1)

  runtime.resolve = function() return nil, "runtime unavailable" end
  renderer:render({ source = "x" }, function(value) result = value end)
  assert(not result.ok and result.error == "runtime unavailable" and not renderer:is_available())

  runtime.resolve = function() return "/test/bun" end
  vim.schedule = function(callback) callback() end
  local process_callback, killed, input
  vim.system = function(argv, options, callback)
    assert(argv[1] == "/test/bun" and argv[2] == "/custom/renderer.js")
    input, process_callback = vim.json.decode(options.stdin), callback
    return { kill = function() killed = true end }
  end
  local custom = module.new({ script = "/custom/renderer.js", timeout_ms = 1000 })
  assert(module.script_path(custom.options) == "/custom/renderer.js")
  custom:render({ source = "flowchart LR\nX-->Y" }, function(value) result = value end)
  assert(input.embed_fonts)
  process_callback({ code = 0, stdout = '{"output":"<svg/>"}', stderr = "" })
  assert(result.ok and result.output == "<svg/>")
  custom:render({ source = "invalid" }, function(value) result = value end)
  process_callback({ code = 1, stdout = '{"error":"parse failed"}', stderr = "" })
  assert(not result.ok and result.error == "parse failed")
  custom:render({ source = "invalid" }, function(value) result = value end)
  process_callback({ code = 0, stdout = '{"output":3}', stderr = "" })
  assert(not result.ok and result.error:find("invalid renderer response", 1, true))
  custom:render({ source = "slow" }, function(value) result = value end)
  process_callback({ code = 124, stdout = "", stderr = "" })
  assert(not result.ok and result.error:find("timed out", 1, true))
  operation = custom:render({ source = "x" }, function(value) result = value end)
  operation.cancel()
  assert(killed and result.cancelled)
  vim.system = function() error("spawn failed") end
  custom:render({ source = "x" }, function(value) result = value end)
  assert(not result.ok and result.error:find("spawn failed", 1, true))
  assert(next(custom.pending) == nil)
end, debug.traceback)
runtime.resolve, worker.request, worker.stop = saved.resolve, saved.request, saved.stop
vim.system, vim.schedule = saved.system, saved.schedule
assert(ok, message)
