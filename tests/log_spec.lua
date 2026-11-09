local log = require("pele_mermaid.log")

vim.fn.delete(log.path())
vim.g.pele_mermaid_debug = true

local call_ok
local call_error
local timer = assert(vim.uv.new_timer())
timer:start(0, 0, function()
  call_ok, call_error = pcall(log.write, "rasterizer_complete", { ok = true })
  timer:stop()
  timer:close()
end)

assert(vim.wait(1000, function() return call_ok ~= nil end, 5), "fast-event log call did not complete")
assert(call_ok, call_error)
assert(vim.wait(1000, function() return vim.fn.filereadable(log.path()) == 1 end, 5), "scheduled log write did not reach disk")
local lines = vim.fn.readfile(log.path())
assert(lines[#lines]:find("rasterizer_complete", 1, true))

vim.g.pele_mermaid_debug = false
vim.fn.delete(log.path())
