local config = require("pele_mermaid.config").normalize()
local parser = require("pele_mermaid.parser")
local in_buffer = require("pele_mermaid.targets.in_buffer")

local backend = { rendered = {}, cleared = {}, fail = false }
function backend.is_available() return true end
function backend.render(options)
  backend.rendered[#backend.rendered + 1] = options
  if backend.fail then return false, "display rejected" end
  return true
end
function backend.clear(id) backend.cleared[#backend.cleared + 1] = id end
function backend.clear_window() end
function backend.clear_buffer() end

local view = in_buffer.new(config, { backend = backend, graphics = true })
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.bo[bufnr].filetype = "markdown"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "```mermaid",
  "flowchart LR",
  "  A --> B",
  "```",
  "between",
  "```mermaid",
  "sequenceDiagram",
  "  A->>B: hello",
  "```",
})
local blocks = parser.index(bufnr)
local function has_inline_mark_at(row)
  for _, current in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, in_buffer.namespace(), 0, -1, {})) do
    if current[2] == row then return true end
  end
  return false
end
local winid = vim.api.nvim_get_current_win()
local original_conceallevel = vim.wo[winid].conceallevel
local png = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "fake png" }, png)

assert(view:update(bufnr, winid, blocks[1], { png_path = png, key = "one" }, { active = false }))
assert(backend.rendered[1].id == in_buffer.placement_id(bufnr, winid, blocks[1].id))
assert(backend.rendered[1].row == blocks[1].start_row)
assert(vim.wo[winid].conceallevel >= 2)
local image_marks = vim.api.nvim_buf_get_extmarks(bufnr, in_buffer.namespace(), 0, -1, { details = true })
local opener_is_visible_anchor = false
local body_is_line_concealed = false
for _, current in ipairs(image_marks) do
  local row, details = current[2], current[4]
  if row == blocks[1].start_row and details.conceal == "" and details.conceal_lines == nil then
    opener_is_visible_anchor = true
  elseif row == blocks[1].start_row + 1 and details.conceal_lines == "" then
    body_is_line_concealed = true
  end
end
assert(opener_is_visible_anchor, "image anchor row must remain visible with only fence text concealed")
assert(body_is_line_concealed, "diagram content and closing fence must be line-concealed")
local renders = #backend.rendered
assert(view:update(bufnr, winid, blocks[1], { png_path = png, key = "one" }, { active = false }))
assert(#backend.rendered == renders)
local refreshed = png .. ".refresh.png"
vim.fn.writefile({ "fresh pixels" }, refreshed)
assert(view:update(bufnr, winid, blocks[1], { png_path = refreshed, key = "one" }, { active = false }))
assert(backend.rendered[#backend.rendered].path == refreshed, "refresh must display a new delivery even when its cache key is unchanged")
vim.fn.delete(refreshed)

view:clear_window(winid)
local before_redisplay = #backend.rendered
assert(view:update(bufnr, winid, blocks[1], { png_path = png, key = "one" }, { active = false }))
assert(#backend.rendered == before_redisplay + 1, "cleared window must render the same artifact again")
local missing = view:update(bufnr, winid, blocks[2], { svg_path = "only.svg" }, { active = false })
assert(missing == false, "display must reject an artifact without a PNG")

assert(view:update(bufnr, winid, blocks[2], { png_path = png, key = "two" }, { active = false }))

view:update(bufnr, winid, blocks[1], nil, { active = true })
assert(not has_inline_mark_at(blocks[1].start_row) and not has_inline_mark_at(blocks[1].start_row + 1))
assert(vim.list_contains(backend.cleared, in_buffer.placement_id(bufnr, winid, blocks[1].id)))
assert(has_inline_mark_at(blocks[2].start_row))
assert(vim.api.nvim_buf_get_lines(bufnr, 0, 4, false)[2] == "flowchart LR")

view:clear_block(bufnr, winid, blocks[2].id)
assert(vim.wo[winid].conceallevel == original_conceallevel)

backend.fail = true
local ok, message = view:update(bufnr, winid, blocks[1], { png_path = png, key = "failure" }, { active = false })
assert(ok == false and message == "display rejected")
assert(not has_inline_mark_at(blocks[1].start_row) and not has_inline_mark_at(blocks[1].start_row + 1))
backend.fail = false

vim.cmd("vsplit")
local windows = vim.api.nvim_list_wins()
for _, current in ipairs(windows) do
  if vim.api.nvim_win_get_buf(current) == bufnr then
    view:update(bufnr, current, blocks[1], { png_path = png, key = "shared" }, { active = false })
  end
end
view:update(bufnr, windows[1], blocks[1], nil, { active = true })
assert(not has_inline_mark_at(blocks[1].start_row) and not has_inline_mark_at(blocks[1].start_row + 1))
for _, current in ipairs(windows) do
  if vim.api.nvim_win_get_buf(current) == bufnr then
    assert(vim.wo[current].conceallevel == original_conceallevel)
  end
end

view:clear_buffer(bufnr)
parser.clear(bufnr)
vim.fn.delete(png)
vim.api.nvim_buf_delete(bufnr, { force = true })
