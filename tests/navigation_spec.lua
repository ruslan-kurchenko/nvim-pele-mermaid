local parser = require("pele_mermaid.parser")
local projection_module = require("pele_mermaid.projection")
local navigation = require("pele_mermaid.navigation")

local source = vim.api.nvim_create_buf(false, true)
vim.bo[source].filetype = "markdown"
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
  "# Architecture",
  "## First Section",
  "```mermaid",
  "flowchart LR",
  "  A --> B",
  "```",
  "some text",
  "## Second Section",
  "```mermaid",
  "sequenceDiagram",
  "  A->>B: hi",
  "```",
  "trailing text",
})
vim.api.nvim_win_set_buf(0, source)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local projection = projection_module.new({ parser = parser })
vim.o.scrolloff = 8

-- 1. Source navigation: next and prev
local target1 = navigation.next(source, 0, { parser = parser, projection = projection })
assert(target1 == 2, "navigation.next from line 1 must jump to first diagram at row 2")
assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
assert(vim.fn.line("w0") == 3, "target diagram must be positioned at top of viewport (w0)")
local target2 = navigation.next(source, 0, { parser = parser, projection = projection })
assert(target2 == 8, "navigation.next from first diagram must jump to second diagram at row 8")
assert(vim.api.nvim_win_get_cursor(0)[1] == 9)

local prev1 = navigation.prev(source, 0, { parser = parser, projection = projection })
assert(prev1 == 2, "navigation.prev from second diagram must jump back to first diagram at row 2")
assert(vim.api.nvim_win_get_cursor(0)[1] == 3)

-- 2. Projected navigation: next and prev
local projected = projection:enter(source, 0, parser.index(source))
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local p_target1 = navigation.next(projected, 0, { parser = parser, projection = projection })
assert(p_target1 == 2, "navigation.next in projection must jump to first diagram anchor row")
assert(vim.api.nvim_win_get_cursor(0)[1] == 3)

local p_target2 = navigation.next(projected, 0, { parser = parser, projection = projection })
assert(p_target2 == 5, "navigation.next in projection must jump to second diagram anchor row")
assert(vim.api.nvim_win_get_cursor(0)[1] == 6)
assert(vim.fn.line("w0") == 6, "projected diagram must be positioned at top of viewport (w0)")
-- 3. Diagram listing with metadata (type & section heading)
local items = navigation.items(source, { parser = parser, projection = projection })
assert(#items == 2)
assert(items[1].type == "flowchart LR")
assert(items[1].heading == "## First Section")
assert(items[2].type == "sequenceDiagram")
assert(items[2].heading == "## Second Section")

projection:leave(projected, 0)
projection:cleanup_source(source)
parser.clear(source)
if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
