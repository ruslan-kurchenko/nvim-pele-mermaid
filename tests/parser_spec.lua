local parser = require("pele_mermaid.parser")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "before",
  "  ```` Mermaid {.wide}",
  "  flowchart LR",
  "    A --> B",
  "  ```",
  "  ````  ",
  "middle",
  "~~~MERMAID title=second",
  "sequenceDiagram",
  "  A->>B: hello",
  "~~~~",
  "after",
  "```mermaid",
  "stateDiagram-v2",
  "  [*] --> Idle",
})

local blocks = parser.index(bufnr)
assert(#blocks == 3)
assert(blocks[1].complete == true)
assert(blocks[1].start_row == 1 and blocks[1].end_row == 5)
assert(blocks[1].source == "flowchart LR\n  A --> B\n```")
assert(blocks[2].complete == true and blocks[2].source:find("sequenceDiagram", 1, true))
assert(blocks[3].complete == false and blocks[3].end_row == 14)
assert(parser.at(bufnr, 2).id == blocks[1].id)
assert(parser.at(bufnr, 6) == nil)

local scans = parser._scan_count(bufnr)
assert(parser.index(bufnr) == blocks)
assert(parser._scan_count(bufnr) == scans)

local ids = { blocks[1].id, blocks[2].id, blocks[3].id }
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted one", "inserted two" })
blocks = parser.index(bufnr)
assert(blocks[1].id == ids[1] and blocks[1].start_row == 3)
assert(blocks[2].id == ids[2] and blocks[2].start_row == 9)
assert(blocks[3].id == ids[3] and blocks[3].start_row == 14)

vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})
blocks = parser.index(bufnr)
assert(blocks[1].id == ids[1] and blocks[1].start_row == 1)
assert(blocks[2].id == ids[2] and blocks[2].start_row == 7)


vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "not a fence" })
blocks = parser.index(bufnr)
assert(#blocks == 2)
assert(blocks[1].id == ids[2])
assert(parser.position(bufnr, ids[1]) == nil)

parser.clear(bufnr)
assert(parser._scan_count(bufnr) == 0)
vim.api.nvim_buf_delete(bufnr, { force = true })
