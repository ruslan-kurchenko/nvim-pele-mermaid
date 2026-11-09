local config = require("pele_mermaid.config").normalize()
local parser = require("pele_mermaid.parser")
local projection_module = require("pele_mermaid.projection")
local runtime_module = require("pele_mermaid.runtime")

local view = { updates = {}, clears = 0, cleared_blocks = {}, cleared_windows = {} }
function view:graphics_available() return true end
function view:width_px() return 600 end
function view:update(bufnr, winid, block, artifact, options)
  self.updates[#self.updates + 1] = { bufnr = bufnr, winid = winid, id = block.id, artifact = artifact, active = options.active }
  return true
end
function view:clear_block(bufnr, winid, id)
  self.cleared_blocks[#self.cleared_blocks + 1] = { bufnr = bufnr, winid = winid, id = id }
  self.clears = self.clears + 1
end
function view:clear_window(winid)
  self.cleared_windows[#self.cleared_windows + 1] = winid
  self.clears = self.clears + 1
end
function view:clear_buffer() self.clears = self.clears + 1 end

local artifact = { requests = {}, callbacks = {} }
function artifact:resolve(request, callback)
  self.requests[#self.requests + 1] = request
  self.callbacks[#self.callbacks + 1] = callback
  return { cancel = function() return true end }
end
function artifact:stop() end

local theme = {}
function theme.resolve() return { options = {}, signature = "theme" } end
function theme.invalidate() end

local projection = projection_module.new({ parser = parser })
local runtime = runtime_module.new(config, {
  parser = parser,
  projection = projection,
  artifact = artifact,
  view = view,
  theme = theme,
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "markdown"
local lines = {
  "# Title",
  "```mermaid",
  "flowchart LR",
  "  A --> B",
  "```",
}
for index = 1, 80 do lines[#lines + 1] = "filler " .. index end
vim.list_extend(lines, {
  "```mermaid",
  "sequenceDiagram",
  "  A->>B: hello",
  "```",
})
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 3, 0 })

-- 1. Opening Markdown source performs ZERO artifact requests
runtime:reconcile(bufnr)
assert(#artifact.requests == 0, "opening Markdown source must perform zero Mermaid rendering requests")
assert(#view.updates == 0, "opening Markdown source must create zero view updates")

-- 2. Toggle enters the projected read buffer
local mode = runtime:toggle(bufnr)
assert(mode == "read", "toggle on source must switch to read mode")
local projected = vim.api.nvim_get_current_buf()
assert(projected ~= bufnr, "toggle must switch window to projected buffer")
assert(vim.bo[projected].buftype == "nofile")
assert(vim.bo[projected].modifiable == false)
assert(projection:is_projection(projected))
assert(projection:source_buffer(projected) == bufnr)

-- 3. Visible block requested
assert(#artifact.requests >= 1, "visible diagram must be requested upon entering read mode")
local first_request = artifact.requests[1]
assert(first_request.source:match("flowchart LR"), "first diagram must be requested")

-- 4. Complete callback renders onto projected anchor
artifact.callbacks[1]({ ok = true, key = "first-art", png_path = "FIRST-ASCII" })
local latest = view.updates[#view.updates]
assert(latest and latest.bufnr == projected, "diagram must be updated on projected buffer")
assert(latest.artifact and latest.artifact.png_path == "FIRST-ASCII")

-- 5. Toggle from projection leaves read mode and restores source
local exit_mode = runtime:toggle(projected)
assert(exit_mode == "edit", "toggle from projection must switch back to edit mode")
assert(vim.api.nvim_get_current_buf() == bufnr, "window must be restored to source buffer")
assert(vim.api.nvim_win_get_cursor(0)[1] >= 2, "cursor must map back to source fence")

runtime:cleanup_buffer(bufnr)
runtime:stop()
if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
