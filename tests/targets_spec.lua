local config = require("pele_mermaid.config").normalize({ debounce_ms = 1 })
local float_module = require("pele_mermaid.targets.float")
local split_module = require("pele_mermaid.targets.split")
local export_module = require("pele_mermaid.targets.external")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "markdown"
local source_win = vim.api.nvim_get_current_win()
local block = { id = 1, bufnr = bufnr, start_row = 0, end_row = 3, source = "flowchart LR\nA --> B", source_hash = "hash", complete = true }
local second_block = { id = 2, bufnr = bufnr, start_row = 5, end_row = 8, source = "sequenceDiagram\nA->>B: Hi", source_hash = "two", complete = true }

local runtime = { block = block, requests = {}, callbacks = {} }
function runtime:current_block() return self.block end
function runtime:request(current, options, callback)
  self.requests[#self.requests + 1] = { block = current, options = options }
  self.callbacks[#self.callbacks + 1] = callback
  return { cancel = function() return true end }
end
local view = {}
function view:graphics_available() return true end
local placements = {}
local backend = require("pele_mermaid.deps.image_backend")
local saved_render, saved_clear = backend.render, backend.clear
backend.render = function(options) placements[options.id] = options; return true end
backend.clear = function(id) placements[id] = nil end
function view:width_px() return 800 end

local floating = float_module.new(runtime, view, config)
assert(floating:toggle())
local float_session = floating.sessions[source_win]
assert(float_session and float_session:is_open())
local float_maps = vim.api.nvim_buf_get_keymap(float_session.preview_buf, "n")
local float_lhs = {}
for _, mapping in ipairs(float_maps) do float_lhs[mapping.lhs] = true end
assert(float_lhs.q and float_lhs["<Esc>"])
runtime.callbacks[1]({ ok = true, key = "float", png_path = "float.png" })
assert(placements[float_session.image_id].path == "float.png")
runtime.block = nil
float_session:refresh()
assert(not placements[float_session.image_id] and not float_session.last_good, "leaving a block clears its old image")
float_session:close()
assert(not floating:is_open(source_win))

runtime.block = block
vim.api.nvim_set_current_win(source_win)
local split = split_module.new(runtime, view, config)
assert(split:toggle())
local tabpage = vim.api.nvim_get_current_tabpage()
local split_session = split.sessions[tabpage]
assert(split_session and split_session:is_open())
local split_lhs = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(split_session.preview_buf, "n")) do split_lhs[mapping.lhs] = true end
assert(split_lhs.q and split_lhs["<Esc>"])
runtime.callbacks[2]({ ok = true, key = "split", png_path = "split.png" })
assert(placements[split_session.image_id].path == "split.png")
runtime.block = second_block
split_session:refresh()
assert(runtime.requests[3].block.id == second_block.id)
runtime.callbacks[3]({ ok = true, key = "second", png_path = "second.png" })
assert(placements[split_session.image_id].path == "second.png")
split_session:resize()
assert(#runtime.requests == 4)
split_session:close()
assert(not split:is_open(tabpage))
local late_released = false
runtime.callbacks[4]({ ok = true, key = "late", png_path = "late.png", release = function() late_released = true end })
assert(not placements[split_session.image_id] and late_released, "closed preview must release late artifact completion")

assert(split:toggle())
local first_tab_session = split.sessions[tabpage]
vim.cmd("tabnew")
local other_tab = vim.api.nvim_get_current_tabpage()
vim.api.nvim_win_set_buf(0, bufnr)
assert(split:toggle())
assert(split.sessions[other_tab] ~= first_tab_session and first_tab_session:is_open())
assert(not split:toggle())
assert(first_tab_session:is_open(), "closing another tab's split must preserve the first tab")
vim.cmd("tabclose")
first_tab_session:close()
vim.api.nvim_set_current_win(source_win)

view.graphics_available = function() return false end
local before_unavailable = #runtime.requests
assert(floating:toggle())
local unavailable = floating.sessions[source_win]
assert(#runtime.requests == before_unavailable, "unsupported graphics must not request another renderer")
assert(vim.api.nvim_buf_get_lines(unavailable.preview_buf, 0, 1, false)[1]:find("requires Kitty graphics", 1, true))
unavailable:close()
view.graphics_available = function() return true end

-- Projection cursor events resolve against the actual window buffer, while
-- edits in the hidden source still refresh both preview target kinds.
local projected = vim.api.nvim_create_buf(false, true)
runtime.projection = {
  is_projection = function(_, buf) return buf == projected end,
  source_buffer = function(_, buf) return buf == projected and bufnr or nil end,
}
function runtime:current_block(buf, win)
  assert(buf == vim.api.nvim_win_get_buf(win), "current_block must receive the displayed projection buffer")
  return self.block
end
for _, target in ipairs({ floating, split }) do
  vim.api.nvim_win_set_buf(source_win, projected)
  runtime.block = block
  assert(target:toggle())
  local session = target == floating and target.sessions[source_win] or target.sessions[tabpage]
  local released = 0
  runtime.callbacks[#runtime.callbacks]({ ok = true, png_path = "projected.png", release = function() released = released + 1 end })
  local previous = session.last_good
  local previous_lines = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
  local accepted_render = backend.render
  backend.render = function() return false, "replacement decode failed" end
  session:refresh()
  local rejected_released = false
  runtime.callbacks[#runtime.callbacks]({
    ok = true, png_path = "rejected.png", release = function() rejected_released = true end,
  })
  assert(rejected_released and released == 0 and session.last_good == previous, "failed replacement must release only the rejected artifact")
  assert(placements[session.image_id].path == "projected.png", "backend failure must preserve prior pixels")
  assert(vim.deep_equal(previous_lines, vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)))
  assert(session.error == "replacement decode failed", "failed replacement must remain observable")
  backend.render = accepted_render
  local count = #runtime.requests
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = projected })
  assert(#runtime.requests > count, "projection cursor changes must refresh preview")
  count = #runtime.requests
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  assert(vim.wait(100, function() return #runtime.requests > count end, 1), "hidden source edits must refresh preview")
  runtime.block = vim.tbl_extend("force", block, { complete = false })
  session:refresh()
  assert(placements[session.image_id].path == "projected.png" and released == 0, "same incomplete identity keeps its own image")
  runtime.block = vim.tbl_extend("force", second_block, { complete = false })
  session:refresh()
  assert(not placements[session.image_id] and released == 1, "another incomplete block must not inherit the prior image")
  runtime.block = block
  session:refresh()
  runtime.callbacks[#runtime.callbacks]({ ok = true, png_path = "again.png" })
  runtime.block = nil
  vim.api.nvim_win_set_buf(source_win, bufnr)
  assert(not placements[session.image_id], "switching source window buffers must clear old image")
  session:close()
end
runtime.projection = nil
runtime.block = block
vim.api.nvim_buf_delete(projected, { force = true })

local source_svg = vim.fn.tempname() .. ".svg"
local source_png = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "<svg></svg>" }, source_svg)
vim.fn.writefile({ "png" }, source_png)
local export_runtime = { block = block, requests = 0 }
function export_runtime:current_block() return self.block end
function export_runtime:request(_, options, callback)
  self.requests = self.requests + 1
  vim.schedule(function()
    callback(options.want_png and { ok = true, png_path = source_png } or { ok = true, svg_path = source_svg })
  end)
  return { cancel = function() return true end }
end
local parser = {}
function parser.index()
  return {
    block,
    { id = 2, bufnr = bufnr, start_row = 5, end_row = 8, source = "sequenceDiagram\nA->>B: Hi", source_hash = "two", complete = true },
  }
end
local exporter = export_module.new(export_runtime, view, parser)
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level) notifications[#notifications + 1] = { message, level } end

vim.api.nvim_set_current_win(source_win)
local destination = vim.fn.tempname() .. ".svg"
exporter:current(destination, false)
assert(vim.wait(1000, function() return vim.fn.filereadable(destination) == 1 end, 5))
assert(vim.fn.readfile(destination)[1] == "<svg></svg>")
local request_count = export_runtime.requests
exporter:current(destination, false)
assert(export_runtime.requests == request_count)
assert(notifications[#notifications][1]:find("use :MermaidExport!", 1, true))

local invalid_requests = export_runtime.requests
exporter:current(vim.fn.tempname() .. ".txt", false)
assert(export_runtime.requests == invalid_requests)
assert(notifications[#notifications][1]:find(".svg or .png", 1, true))

export_runtime.block = vim.tbl_extend("force", block, { complete = false })
exporter:current(vim.fn.tempname() .. ".svg", false)
assert(export_runtime.requests == invalid_requests)
assert(notifications[#notifications][1]:find("incomplete", 1, true))
export_runtime.block = block

local raced_destination = vim.fn.tempname() .. ".svg"
local notices_before_race = #notifications
exporter:current(raced_destination, false)
vim.fn.writefile({ "other writer" }, raced_destination)
assert(vim.wait(1000, function() return #notifications > notices_before_race end, 5))
assert(vim.fn.readfile(raced_destination)[1] == "other writer")

local png_destination = vim.fn.tempname() .. ".png"
local notices_before_png = #notifications
exporter:current(png_destination, false)
assert(vim.wait(1000, function() return vim.fn.filereadable(png_destination) == 1 end, 5))
assert(vim.wait(1000, function() return #notifications > notices_before_png end, 5))

local directory = vim.fn.tempname()
local notices_before_all = #notifications
exporter:all(directory, false)
local first_export = directory .. "/mermaid-mermaid-1.svg"
local second_export = directory .. "/mermaid-mermaid-2.svg"
assert(vim.wait(1000, function()
  for index = notices_before_all + 1, #notifications do
    if notifications[index][1]:find("exported 2 diagrams", 1, true) then return true end
  end
  return false
end, 5))
assert(vim.fn.filereadable(first_export) == 1 and vim.fn.filereadable(second_export) == 1)
local before_protected_all = export_runtime.requests
exporter:all(directory, false)
assert(export_runtime.requests == before_protected_all)
assert(notifications[#notifications][1]:find("MermaidExportAll!", 1, true))

vim.fn.writefile({ "replace me" }, destination)
local before_overwrite = #notifications
exporter:current(destination, true)
assert(vim.wait(1000, function() return #notifications > before_overwrite end, 5))
assert(vim.fn.readfile(destination)[1] == "<svg></svg>")

local dangling = vim.fn.tempname() .. ".svg"
assert(vim.uv.fs_symlink(vim.fn.tempname(), dangling))
local before_symlink = export_runtime.requests
exporter:current(dangling, false)
assert(export_runtime.requests == before_symlink, "dangling symlinks must count as existing destinations")
vim.fn.delete(dangling)

local deliveries = {}
local owned_runtime = {
  request = function(_, _, _, callback)
    deliveries[#deliveries + 1] = callback
    return { cancel = function() end }
  end,
}
local owned_exporter = export_module.new(owned_runtime, view, parser)
local owned_directory = vim.fn.tempname()
owned_exporter:all(owned_directory, false)
local release_count = 0
local function owned_svg(text)
  local path = vim.fn.tempname() .. ".svg"
  vim.fn.writefile({ text }, path)
  return { ok = true, svg_path = path, release = function()
    release_count = release_count + 1
    vim.uv.fs_unlink(path)
  end }
end
local first_input = owned_svg("<svg>first</svg>")
deliveries[1](first_input)
assert(release_count == 0 and vim.fn.filereadable(first_input.svg_path) == 1, "first result must stay owned while the second renders")
deliveries[2](owned_svg("<svg>second</svg>"))
assert(vim.wait(1000, function() return release_count == 2 end, 5))
assert(vim.fn.readfile(owned_directory .. "/mermaid-mermaid-1.svg")[1] == "<svg>first</svg>")
assert(vim.fn.readfile(owned_directory .. "/mermaid-mermaid-2.svg")[1] == "<svg>second</svg>")
owned_exporter:all(owned_directory, true)
deliveries[3](owned_svg("<svg>discard</svg>"))
deliveries[4]({ ok = false, error = "second failed" })
assert(release_count == 3, "a failed batch must release earlier delivered artifacts")
vim.fn.delete(owned_directory, "rf")

vim.notify = original_notify
vim.fn.delete(destination)
vim.fn.delete(png_destination)
vim.fn.delete(source_svg)
vim.fn.delete(raced_destination)
vim.fn.delete(source_png)
vim.fn.delete(directory, "rf")
floating:close_all()
split:close_all()
vim.api.nvim_buf_delete(bufnr, { force = true })

backend.render, backend.clear = saved_render, saved_clear
