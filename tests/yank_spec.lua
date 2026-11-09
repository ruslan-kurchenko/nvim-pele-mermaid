local yank = require("pele_mermaid.yank")
local png_path = '/tmp/diagram "quoted"; $(not-a-command).png'
local function scenario(options)
  local calls, notices, requests = {}, {}, {}
  local runtime = {}
  function runtime:current_block() return { complete = true, source = "flowchart LR\nA --> B" } end
  function runtime:request(_, request, callback)
    requests[#requests + 1] = request
    callback(options.result or { ok = true, png_path = png_path })
    return { cancel = function() end }
  end
  local copier = yank.new({
    runtime = runtime, is_mac = options.is_mac or false, env = options.env or {},
    executable = function(name) return options.executables and options.executables[name] and 1 or 0 end,
    read_binary = function(path) assert(path == png_path); return "\137PNG\0\r\nbytes" end,
    notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end,
    system = function(command, process_options, callback)
      calls[#calls + 1] = { command = command, options = process_options }
      if options.throw then error("spawn rejected") end
      callback({ code = options.code or 0, stderr = options.stderr or "" })
      return {}
    end,
  })
  copier:current()
  vim.wait(100, function() return #notices > 0 end, 1)
  return calls, notices, requests
end

local calls, notices, requests = scenario({ env = { WAYLAND_DISPLAY = "wayland-1" }, executables = { ["wl-copy"] = true } })
assert(#calls == 1 and calls[1].command[1] == "wl-copy")
assert(calls[1].command[2] == "--type" and calls[1].command[3] == "image/png")
assert(#calls[1].command == 3 and calls[1].options.stdin == "\137PNG\0\r\nbytes")
assert(calls[1].options.text == false, "binary PNG must not undergo text conversion")
assert(requests[1].width_px == 1200 and requests[1].scale == 2 and requests[1].want_png)
assert(notices[#notices].message:find("2x PNG", 1, true))

calls = scenario({ env = { DISPLAY = ":0" }, executables = { ["xclip"] = true, ["wl-copy"] = true } })
assert(calls[1].command[1] == "xclip" and calls[1].command[7] == png_path)
assert(calls[1].options.stdin == nil)

calls = scenario({ is_mac = true, executables = { osascript = true } })
assert(calls[1].command[1] == "osascript" and calls[1].command[4] == png_path)
assert(not calls[1].command[3]:find(png_path, 1, true), "AppleScript must receive the filename as argv, not source code")
assert(calls[1].command[3]:find("PNGf", 1, true))

calls, notices, requests = scenario({ executables = { ["wl-copy"] = true } })
assert(#calls == 0 and #requests == 0)
assert(notices[1].level == vim.log.levels.ERROR)

calls, notices = scenario({ env = { DISPLAY = ":0" }, executables = { xclip = true }, code = 1, stderr = "display unavailable" })
assert(notices[#notices].message:find("display unavailable", 1, true))
calls, notices = scenario({ env = { DISPLAY = ":0" }, executables = { xclip = true }, throw = true })
assert(notices[#notices].message:find("spawn rejected", 1, true))
calls, notices = scenario({ is_mac = true, executables = { osascript = true }, result = { ok = false, error = "bad diagram" } })
assert(#calls == 0 and notices[#notices].message:find("bad diagram", 1, true))

local pending_callback, cancelled, copied = nil, false, false
local stopped = yank.new({
  is_mac = false, env = { WAYLAND_DISPLAY = "wayland-1" },
  executable = function() return 1 end,
  runtime = {
    current_block = function() return { complete = true } end,
    request = function(_, _, _, callback)
      pending_callback = callback
      return { cancel = function() cancelled = true end }
    end,
  },
  system = function() copied = true end,
  read_binary = function() return "PNG" end,
})
stopped:current()
stopped:stop()
pending_callback({ ok = true, png_path = png_path })
assert(cancelled and not copied, "stopped runtime must not perform a delayed clipboard write")

local providers, releases = {}, 0
local owned_copier = yank.new({
  is_mac = false, env = { DISPLAY = ":0" }, executable = function() return 1 end,
  notify = function() end,
  runtime = {
    current_block = function() return { complete = true } end,
    request = function(_, _, _, callback)
      local released = false
      callback({ ok = true, png_path = png_path, release = function()
        if not released then released = true; releases = releases + 1 end
      end })
      return { cancel = function() end }
    end,
  },
  system = function(_, _, callback)
    if #providers > 0 then assert(providers[#providers].killed and providers[#providers].waited, "old provider must finish cancellation before starting its replacement") end
    local process = { callback = callback }
    function process:kill(signal) assert(signal == 9); self.killed = true end
    function process:wait() self.waited = true end
    providers[#providers + 1] = process
    return process
  end,
})
owned_copier:current()
assert(owned_copier.provider == providers[1] and releases == 0)
owned_copier:current()
assert(providers[1].killed and providers[1].waited and releases == 1)
providers[1].callback({ code = 137 })
vim.wait(20, function() return owned_copier.provider ~= providers[2] end, 1)
assert(owned_copier.provider == providers[2], "late completion must not discard the newer provider handle")
owned_copier:stop()
assert(providers[2].killed and providers[2].waited and releases == 2)
providers[2].callback({ code = 137 })
