local term_name = vim.env.TERM_PROGRAM
local old_term, old_helpers = package.loaded['image/utils/term'], package.loaded['image/backends/kitty/helpers']
local placement
package.loaded['image/utils/term'] = { get_size = function() return {cell_width=14,cell_height=32} end }
package.loaded['image/backends/kitty/helpers'] = { write_graphics_at = function(payload) placement=payload end }
vim.env.TERM_PROGRAM='tern'
local win = vim.api.nvim_get_current_win()
local info = vim.fn.getwininfo(win)[1]
local bottom = info.winrow - 1 + info.height
require('pele_mermaid.deps.tern').place({
  window=win, internal_id=1,
  global_state={options={backend='kitty'}},
  rendered_geometry={x=0,y=bottom-2,width=20,height=4},
  bounds={left=0,right=80,top=0,bottom=bottom},
})
assert(placement.display_height==64, 'positive-z image must stop before the statusline')
assert(placement.display_rows==nil and placement.display_columns==nil, 'cell rounding must not stretch native PNG pixels')
vim.env.TERM_PROGRAM=term_name
package.loaded['image/utils/term'],package.loaded['image/backends/kitty/helpers']=old_term,old_helpers
