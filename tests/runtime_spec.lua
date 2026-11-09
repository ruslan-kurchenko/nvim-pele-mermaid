local config = require("pele_mermaid.config").normalize()
local parser = require("pele_mermaid.parser")
local runtime_module = require("pele_mermaid.runtime")

local view = { updates = {}, cleared_blocks = {}, cleared_windows = {}, cleared_buffers = {} }
function view:graphics_available() return true end
function view:width_px() return 600 end
function view:update(bufnr, winid, block, artifact, options)
  self.updates[#self.updates + 1] = {
    bufnr = bufnr,
    winid = winid,
    id = block.id,
    artifact = artifact,
    active = options.active,
    error = options.error,
  }
  return true
end
function view:clear_block(bufnr, winid, id) self.cleared_blocks[#self.cleared_blocks + 1] = { bufnr, winid, id } end
function view:clear_window(winid) self.cleared_windows[#self.cleared_windows + 1] = winid end
function view:clear_buffer(bufnr) self.cleared_buffers[#self.cleared_buffers + 1] = bufnr end

local artifact = { requests = {}, callbacks = {}, subscriptions = {}, stopped = false }
function artifact:resolve(request, callback)
  self.requests[#self.requests + 1] = request
  self.callbacks[#self.callbacks + 1] = callback
  local subscription = { cancelled = false }
  function subscription.cancel()
    subscription.cancelled = true
    return true
  end
  self.subscriptions[#self.subscriptions + 1] = subscription
  return subscription
end
function artifact:stop() self.stopped = true end

local theme = { signature = "theme-one" }
function theme.resolve()
  return { options = { bg = "#000000", fg = "#ffffff" }, signature = theme.signature }
end
function theme.invalidate() theme.signature = "theme-two" end

local timers = {}
local function new_timer()
  local timer = { closed = false }
  function timer:start(_, _, callback) self.callback = callback end
  function timer:stop() end
  function timer:close() self.closed = true end
  function timer:is_closing() return self.closed end
  timers[#timers + 1] = timer
  return timer
end

local runtime = runtime_module.new(config, {
  parser = parser,
  artifact = artifact,
  view = view,
  theme = theme,
  new_timer = new_timer,
  schedule = function(callback) callback() end,
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "markdown"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "```mermaid",
  "flowchart LR",
  "  A --> B",
  "```",
  "outside",
})
vim.api.nvim_win_set_cursor(0, { 2, 0 })
runtime:toggle(bufnr)
assert(#artifact.requests == 1 and artifact.requests[1].output == "svg")
local block_id = parser.index(bufnr)[1].id
local released = {}
local function result(key)
  return { ok = true, key = key, png_path = key, release = function()
    released[key] = (released[key] or 0) + 1
  end }
end

vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "  A --> C" })
runtime:reconcile(bufnr)
assert(#artifact.requests == 2)
assert(artifact.subscriptions[1].cancelled)
artifact.callbacks[1](result("stale"))
assert(released.stale == 1, "late results must release their private artifact files")
local state = runtime:_state(bufnr).blocks[block_id]
assert(next(state.last_good) == nil)
artifact.callbacks[2](result("fresh"))
assert(state.last_good["png:600"].png_path == "fresh")
assert(view.updates[#view.updates].active == false and view.updates[#view.updates].artifact.png_path == "fresh")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
runtime:reconcile(bufnr)
local latest = view.updates[#view.updates]
assert(latest.active == false and latest.artifact.png_path == "fresh")
vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "  this is invalid" })
runtime:reconcile(bufnr)
assert(#artifact.requests == 3)
artifact.callbacks[3]({ ok = false, stage = "renderer", error = "invalid edge" })
assert(state.error == "invalid edge")
assert(state.last_good["png:600"].png_path == "fresh")
assert(not released.fresh, "last-good artifacts stay leased through invalid edits")
assert(#artifact.requests == 3, "failed generation was retried")
local diagnostics = vim.diagnostic.get(bufnr, { namespace = runtime_module.diagnostic_namespace() })
assert(#diagnostics == 1 and diagnostics[1].message == "Mermaid preview stale: invalid edge")

vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "  A --> D" })
runtime:reconcile(bufnr)
artifact.callbacks[4](result("repaired"))
assert(released.fresh == 1, "successful replacement releases prior artifacts")
assert(state.error == nil and state.last_good["png:600"].png_path == "repaired")
assert(#vim.diagnostic.get(bufnr, { namespace = runtime_module.diagnostic_namespace() }) == 0)

runtime:refresh(bufnr)
assert(#artifact.requests == 5)
vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, {})
runtime:reconcile(bufnr)
assert(artifact.subscriptions[5].cancelled)
artifact.callbacks[5](result("obsolete-complete"))
assert(released["obsolete-complete"] == 1, "incomplete-fence stale results must release")
assert(state.error == "incomplete Mermaid fence")
assert(state.last_good["png:600"].png_path == "repaired")
runtime:cleanup_window(vim.api.nvim_get_current_win())
assert(not released.repaired and state.last_good["png:600"], "incomplete fence must keep its one last-valid artifact across view transitions")

local other = vim.api.nvim_create_buf(false, true)
vim.bo[other].filetype = "markdown"
runtime:_debounce(bufnr)
runtime:_debounce(other)
assert(runtime:_state(bufnr).timer ~= runtime:_state(other).timer)
local other_timer = runtime:_state(other).timer
timers[#timers - 1].callback()
assert(runtime:_state(bufnr).timer == nil and runtime:_state(other).timer == other_timer)

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
runtime:reconcile(bufnr)
assert(next(runtime:_state(bufnr).blocks) == nil)
assert(released.repaired == 1, "removed blocks release retained artifacts")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "```mermaid",
  "flowchart LR",
  "  X --> Y",
  "```",
  "outside",
})
vim.api.nvim_win_set_buf(0, bufnr)
vim.cmd("vsplit")
local windows = vim.api.nvim_list_wins()
assert(#windows >= 2)
for _, winid in ipairs(windows) do
  if vim.api.nvim_win_get_buf(winid) == bufnr then
    vim.api.nvim_win_set_cursor(winid, { 2, 0 })
  end
end
runtime:toggle(bufnr)
local projected = vim.api.nvim_get_current_buf()
assert(runtime.projection:is_projection(projected))
runtime:toggle(projected)
assert(vim.api.nvim_get_current_buf() == bufnr)
assert(#view.cleared_windows > 0)
local clears_before_disable = #view.cleared_buffers
vim.bo[bufnr].filetype = "text"
runtime:reconcile(bufnr)
assert(runtime:_state(bufnr) == nil)
assert(#view.cleared_buffers == clears_before_disable + 1)

runtime:cleanup_buffer(bufnr)
runtime:cleanup_buffer(other)
runtime:stop()
assert(artifact.stopped)
if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
if vim.api.nvim_buf_is_valid(other) then vim.api.nvim_buf_delete(other, { force = true }) end
