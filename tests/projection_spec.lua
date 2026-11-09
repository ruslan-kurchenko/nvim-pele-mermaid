local parser = require("pele_mermaid.parser")
local projection_module = require("pele_mermaid.projection")

local source = vim.api.nvim_create_buf(false, true)
vim.bo[source].filetype = "markdown"
vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. "/projection.md")
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
  "# Architecture",
  "before",
  "```mermaid",
  "flowchart LR",
  "  A --> B",
  "```",
  "between",
  "~~~MERMAID title=second",
  "sequenceDiagram",
  "  A->>B: hello",
  "~~~",
  "after",
})
vim.wo[0].wrap = false
vim.api.nvim_win_set_buf(0, source)
vim.api.nvim_win_set_cursor(0, { 4, 2 })
local projection = projection_module.new({ parser = parser })
local blocks = parser.index(source)
local projected = projection:enter(source, 0, blocks)
assert(projected ~= source)
assert(vim.api.nvim_get_current_buf() == projected)
assert(vim.bo[projected].buftype == "nofile")
assert(vim.bo[projected].modifiable == false)
assert(vim.bo[projected].filetype == "markdown")
assert(projection:is_projection(projected))
assert(projection:source_buffer(projected) == source)

assert(vim.wo[0].wrap == true, "projection must enforce wrap=true")
assert(vim.wo[0].scrolloff == 0, "projection must enforce scrolloff=0")
local lines = vim.api.nvim_buf_get_lines(projected, 0, -1, false)
assert(vim.deep_equal(lines, {
  "# Architecture",
  "before",
  "",
  "between",
  "",
  "after",
}), "projection must replace each complete fence with one logical anchor row")

local first = projection:display_block(source, blocks[1])
local second = projection:display_block(source, blocks[2])
assert(first.bufnr == projected and first.start_row == 2 and first.end_row == 2)
assert(second.bufnr == projected and second.start_row == 4 and second.end_row == 4)
assert(projection:block_at(projected, 2).id == blocks[1].id)
assert(projection:block_at(projected, 4).id == blocks[2].id)
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "source cursor inside a fence must map to its anchor")
assert(not pcall(vim.api.nvim_buf_set_lines, projected, 0, 1, false, { "mutated" }))

vim.api.nvim_win_set_cursor(0, { first.start_row + 1, 0 })
local returned = projection:leave(projected, 0)
assert(returned == source and vim.api.nvim_get_current_buf() == source)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 4, 2 }))
assert(vim.wo[0].wrap == false, "leave must restore original wrap")

vim.api.nvim_buf_set_lines(source, 1, 2, false, { "unsaved source change" })
projection:enter(source, 0, parser.index(source))
assert(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 1, 2, false)[1] == "unsaved source change")

projection:cleanup_source(source)
parser.clear(source)
if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
