local M = {}
local derived
local roles = {
  bg = { 'Normal' }, fg = { 'Normal' },
  muted = { 'Comment', 'NonText' },
  accent = { 'Function', 'Keyword', 'Identifier' },
  surface = { 'Visual', 'CursorLine', 'Pmenu' },
  border = { 'FloatBorder', 'WinSeparator', 'VertSplit' },
  line = { 'Statement', 'Type', 'Special' },
}
local mocha = {
  bg = '#1e1e2e', fg = '#cdd6f4', muted = '#a6adc8',
  accent = '#cba6f7', surface = '#313244', border = '#585b70', line = '#89b4fa',
}

local function editor_colors()
  if derived and derived.background == vim.o.background then return derived.colors end
  local colors = {}
  for role, groups in pairs(roles) do
    local attribute = (role == 'bg' or role == 'surface') and 'bg' or 'fg'
    for _, group in ipairs(groups) do
      local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
      if ok and type(highlight[attribute]) == 'number' then
        colors[role] = ('#%06x'):format(highlight[attribute])
        break
      end
    end
  end
  derived = { background = vim.o.background, colors = colors }
  return colors
end

function M.resolve(config)
  local name = config.mermaid.theme or 'nvim'
  local options = vim.deepcopy(config.mermaid.options or {})
  if name == 'nvim' or name == 'auto' then
    options = vim.tbl_deep_extend('force', {}, editor_colors(), options)
    name = vim.o.background
  elseif name == 'catppuccin-mocha' then
    options = vim.tbl_deep_extend('force', {}, mocha, options)
    name = 'dark'
  end
  return {
    name = name, options = options,
    signature = require('pele_mermaid.cache').key({ name = name, options = options }),
  }
end

function M.invalidate()
  derived = nil
end

return M
