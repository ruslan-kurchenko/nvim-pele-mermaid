local cache_module = require("pele_mermaid.cache")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local disk = cache_module.new({ max_bytes = 14, max_age_days = 1 }, { directory = root })
assert(cache_module.key({ b = 2, a = 1 }) == cache_module.key({ a = 1, b = 2 }))

local write_result
local first_path = disk:path("first", "svg")
disk:atomic_write(first_path, "123456", function(ok, value) write_result = { ok, value } end)
assert(vim.wait(1000, function() return write_result ~= nil end, 5))
assert(write_result[1] and disk:exists(first_path))
local read_result
disk:read(first_path, function(ok, content) read_result = { ok, content } end)
assert(vim.wait(1000, function() return read_result ~= nil end, 5))
assert(read_result[1] and read_result[2] == "123456")

vim.fn.writefile({ "abandoned" }, root .. "/orphan.tmp-1")
vim.uv.fs_utime(root .. "/orphan.tmp-1", 1, 1)
local protected_path = disk:path("protected", "png")
local protected_temporary = disk:temporary_path(protected_path)
vim.fn.writefile({ "active" }, protected_temporary)
vim.uv.fs_utime(protected_temporary, 1, 1)
local old_path = disk:path("old", "svg")
vim.fn.writefile({ "old" }, old_path)
vim.uv.fs_utime(old_path, 1, 1)
assert(disk:prune(os.time()) >= 2)
assert(vim.fn.filereadable(old_path) == 0)
assert(vim.fn.filereadable(protected_temporary) == 1)
local protected_done
disk:commit_temporary(protected_temporary, protected_path, function(ok) protected_done = ok end)
assert(vim.wait(1000, function() return protected_done ~= nil end, 5) and protected_done)
assert(vim.fn.filereadable(protected_path) == 1)
assert(vim.fn.filereadable(root .. "/orphan.tmp-1") == 0)

vim.fn.delete(protected_path)

local second_path = disk:path("second", "svg")
local third_path = disk:path("third", "svg")
vim.fn.writefile({ "123456" }, second_path)
vim.fn.writefile({ "123456" }, third_path)
vim.uv.fs_utime(first_path, 10, 10)
vim.uv.fs_utime(second_path, 20, 20)
vim.uv.fs_utime(third_path, 30, 30)
disk:prune(30)
assert(vim.fn.filereadable(first_path) == 0)
assert(vim.fn.filereadable(second_path) == 1 and vim.fn.filereadable(third_path) == 1)

local failed_write
disk:atomic_write(root .. "/missing/artifact.svg", "x", function(ok, message) failed_write = { ok, message } end)
assert(vim.wait(1000, function() return failed_write ~= nil end, 5))
assert(failed_write[1] == false and failed_write[2] ~= "")

local pinned_path = disk:path("pinned", "svg")
vim.fn.writefile({ "pinned source" }, pinned_path)
vim.uv.fs_utime(pinned_path, 1, 1)
local release = disk:pin(pinned_path)
disk:prune(os.time())
assert(vim.fn.filereadable(pinned_path) == 1, "pruning must preserve active raster input")
release()
release()
disk:prune(os.time())
assert(vim.fn.filereadable(pinned_path) == 0, "released input must be eligible for age eviction")

local partial_uv = setmetatable({}, { __index = vim.uv })
local writes = 0
function partial_uv.fs_write(descriptor, content, offset, callback)
  writes = writes + 1
  vim.uv.fs_write(descriptor, content:sub(1, 2), offset, callback)
end
local partial = cache_module.new({ max_bytes = 1024 }, { directory = root .. "/partial", uv = partial_uv })
local partial_result
local partial_path = partial:path("short-writes", "svg")
partial:atomic_write(partial_path, "1234567", function(ok) partial_result = ok end)
assert(vim.wait(1000, function() return partial_result ~= nil end, 5))
assert(partial_result and writes == 4 and vim.fn.readfile(partial_path)[1] == "1234567",
  "short filesystem writes must be continued before atomic publication")
assert(#vim.fn.glob(partial.directory .. "/*.tmp-*", false, true) == 0)

local failed_commit
partial:commit_temporary(partial.directory .. "/missing.tmp", partial:path("missing", "png"),
  function(ok, message) failed_commit = { ok, message } end)
assert(vim.wait(1000, function() return failed_commit ~= nil end, 5))
assert(not failed_commit[1] and failed_commit[2] ~= "")

local timers = {}
local bounded = cache_module.new({ max_bytes = 4, max_age_days = 1 }, {
  directory = root .. "/bounded",
  schedule = function(callback) callback() end,
  new_timer = function()
    local timer = {}
    function timer:start(delay, interval, callback)
      assert(delay == 60000 and interval == 60000)
      self.callback = callback
    end
    function timer:stop() self.stopped = true end
    function timer:close() self.closed = true end
    timers[#timers + 1] = timer
    return timer
  end,
})
local burst_path = bounded:path("burst", "svg")
local burst_done
bounded:atomic_write(burst_path, "over budget", function(ok) burst_done = ok end)
assert(vim.wait(1000, function() return burst_done ~= nil end, 5) and burst_done)
assert(vim.fn.filereadable(burst_path) == 1, "writes within the throttle window await the timer")
timers[1].callback()
assert(vim.fn.filereadable(burst_path) == 0, "the deferred pass must bound an otherwise idle cache")

local aged_path = bounded:path("aged", "svg")
vim.fn.writefile({ "x" }, aged_path)
local unpin = bounded:pin(aged_path)
vim.uv.fs_utime(aged_path, 1, 1)
timers[1].callback()
assert(vim.fn.filereadable(aged_path) == 1)
unpin()
timers[1].callback()
assert(vim.fn.filereadable(aged_path) == 0, "unpinning must not require a later write for age eviction")

local shared_path = bounded:path("shared", "svg")
vim.fn.writefile({ "stable" }, shared_path)
local owned = assert(cache_module.stage(shared_path))
local private_temporary = bounded:temporary_path(shared_path)
vim.fn.writefile({ "in progress" }, private_temporary)
vim.uv.fs_utime(private_temporary, 1, 1)
local other = cache_module.new({ max_bytes = 0 }, { directory = bounded.directory })
assert(vim.fn.filereadable(shared_path) == 0)
assert(vim.fn.readfile(owned.path)[1] == "stable")
assert(vim.fn.readfile(private_temporary)[1] == "in progress", "another editor must not prune private active outputs")
owned.release()
owned.release()
bounded:discard_temporary(private_temporary)
assert(vim.fn.filereadable(owned.path) == 0)

local pruning_uv = setmetatable({}, { __index = vim.uv })
function pruning_uv.fs_rename(from, to, callback)
  vim.uv.fs_rename(from, to, function(message)
    if not message then vim.uv.fs_unlink(to) end
    callback(message)
  end)
end
local pruned = cache_module.new({}, { directory = root .. "/pruned", uv = pruning_uv })
local stable_write
pruned:atomic_write(pruned:path("publication", "svg"), "survives publication", function(ok, _, stable)
  assert(ok and vim.fn.readfile(stable)[1] == "survives publication",
    "publication must retain its private source before another editor can evict the shared path")
  stable_write = stable
end)
assert(vim.wait(1000, function() return stable_write ~= nil end, 5))
assert(vim.fn.filereadable(stable_write) == 0, "cache callback staging has bounded ownership")

local copying_uv = setmetatable({}, { __index = vim.uv })
function copying_uv.fs_link(_, _, callback)
  if callback then callback("EXDEV") else return nil, "EXDEV" end
end
local copying = cache_module.new({}, { directory = root .. "/copying", uv = copying_uv })
local copy_done
local copy_path = copying:path("cross-filesystem", "svg")
copying:atomic_write(copy_path, "copied source", function(ok, _, stable)
  assert(ok and vim.fn.readfile(stable)[1] == "copied source")
  copy_done = true
end)
assert(vim.wait(1000, function() return copy_done end, 5))
local copied = assert(copying:stage(copy_path))
vim.uv.fs_unlink(copy_path)
assert(vim.fn.readfile(copied.path)[1] == "copied source", "hardlink failure must fall back to an owned copy")
copied.release()
copying:stop()

disk:stop()
partial:stop()
bounded:stop()
other:stop()
pruned:stop()
assert(timers[1].closed)
vim.fn.delete(root, "rf")
