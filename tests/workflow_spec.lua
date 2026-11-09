local config = require('pele_mermaid.config').normalize()
local parser = require('pele_mermaid.parser')
local projection = require('pele_mermaid.projection').new()
local source = vim.api.nvim_create_buf(false, true)
vim.bo[source].filetype = 'markdown'
local lines = { '# Heading', '```mermaid', 'flowchart LR', 'A --> B', '```', 'after text' }
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.api.nvim_win_set_buf(0, source)
local first = vim.api.nvim_get_current_win()
vim.wo[first].wrap = false
vim.wo[first].scrolloff = 7
vim.api.nvim_win_set_cursor(first, { 6, 3 })
local projected = projection:enter(source, first)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(first), { 3, 3 }))
projection:enter(source, first) -- Rebuilding an existing projection must not map its cursor twice.
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(first), { 3, 3 }))
vim.cmd('vsplit')
local second = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(second, source)
vim.wo[second].wrap = false
vim.wo[second].scrolloff = 2
projection:enter(source, second)
projection:leave(projected, first)
assert(vim.api.nvim_win_get_buf(second) == projected)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(first), { 6, 3 }))
assert(not vim.wo[first].wrap and vim.wo[first].scrolloff == 7)
projection:leave(projected, second)
assert(not vim.wo[second].wrap and vim.wo[second].scrolloff == 2)
projection:enter(source, first)
projection:leave(projected, first)
assert(vim.api.nvim_win_get_buf(first) == source)
projection:cleanup_source(source)
vim.api.nvim_win_close(second, true)
vim.api.nvim_set_current_win(first)

-- Graphics-unavailable read mode must retain the original editable source.
local view = {}
function view:graphics_available() return false end
function view:clear_buffer() end
function view:clear_window() end
local artifacts = { requests = {} }
function artifacts:resolve(request, callback)
  self.requests[#self.requests + 1] = { request = request, callback = callback }
  return { cancel = function() end }
end
function artifacts:stop() end
local runtime = require('pele_mermaid.runtime').new(config, { view = view, artifact = artifacts })
assert(runtime:toggle(source, first) == 'edit')
assert(vim.api.nvim_win_get_buf(first) == source and #artifacts.requests == 0)
runtime:stop()

-- Prefetch waits for visible work and completes one background request at a time.
function view:graphics_available() return true end
function view:width_px() return 600 end
function view:update() return true end
function view:clear_block() end
local scheduled = {}
runtime = require('pele_mermaid.runtime').new(config, {
  view = view, artifact = artifacts, schedule = function(fn) scheduled[#scheduled + 1] = fn end,
})
local function drain()
  while #scheduled > 0 do table.remove(scheduled, 1)() end
end
local many = {}
for index = 1, 4 do
  vim.list_extend(many, { '```mermaid', 'flowchart LR', 'A --> B' .. index, '```', 'gap' })
end
vim.api.nvim_buf_set_lines(source, 0, -1, false, many)
runtime._window_range = function() return 0, 0 end
runtime:toggle(source, first)
-- Anchor 0 and anchor 2 are within the viewport margin; remaining blocks are idle.
assert(#artifacts.requests == 2)
drain()
assert(#artifacts.requests == 2, 'prefetch started before visible requests settled')
local visible_releases = 0
artifacts.requests[1].callback({ ok = true, png_path = '/first.png', key = 'first', release = function() visible_releases = visible_releases + 1 end })
drain()
assert(#artifacts.requests == 2)
artifacts.requests[2].callback({ ok = true, png_path = '/second.png', key = 'second', release = function() visible_releases = visible_releases + 1 end })
drain()
assert(#artifacts.requests == 3)
local idle_released = false
artifacts.requests[3].callback({ ok = true, png_path = '/third.png', key = 'third', release = function() idle_released = true end })
assert(idle_released, 'offscreen prefetch must release private artifacts after warming the bounded cache')
drain()
assert(#artifacts.requests == 4)
runtime:cleanup_window(first)
assert(visible_releases == 2, 'closing the final reading window must release its complete visible artifacts')
runtime:toggle(vim.api.nvim_win_get_buf(first), first)
artifacts.requests[4].callback({ ok = true, png_path = '/fourth.png', key = 'fourth' })
drain()
assert(vim.api.nvim_win_get_buf(first) == source)
runtime:stop()
parser.clear(source)
vim.api.nvim_buf_delete(source, { force = true })

local linter = require('pele_mermaid.linter')
for _, valid in ipairs({
  'sequenceDiagram\nA->B: hello;',
  'flowchart LR\n%% A -> B;\nA ----> B',
  'flowchart LR\nA["literal X -> Y; (label)"] --> B',
  'flowchart LR\nA --> B %% comment X -> Y;',
}) do
  assert(linter.fix(valid).fixed == valid, 'repair changed valid Mermaid semantics')
end
assert(linter.fix('flowchart LR\nA(path/name) --> B').fixed:find('A("path/name")', 1, true))

local fenced_example = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(fenced_example, 0, -1, false, {
  '````markdown', '```mermaid', 'flowchart LR', 'A --> B', '```', '````',
})
assert(#parser.index(fenced_example) == 0, 'nested examples are not live Mermaid blocks')
parser.clear(fenced_example)
vim.api.nvim_buf_delete(fenced_example, { force = true })
