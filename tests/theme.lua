local function run()
  local theme = require('pele_mermaid.theme')
  vim.api.nvim_set_hl(0, 'Normal', { fg = '#ffffff', bg = '#000000' })
  vim.api.nvim_set_hl(0, 'Visual', { fg = '#ffffff', bg = '#313244' })
  theme.invalidate()
  vim.o.background = 'dark'
  local resolved = theme.resolve({mermaid={theme='nvim',options={accent='#ff0000'}}})
  local colors = resolved.options
  assert(resolved.name == 'dark' and colors.bg == '#000000', 'black background must not be treated as absent')
  assert(colors.surface == '#313244', 'node surface must use highlight background, not foreground')
  assert(colors.accent == '#ff0000', 'explicit colors must override editor colors')
  vim.o.background = 'light'
  assert(theme.resolve({mermaid={theme='nvim'}}).name == 'light', 'editor fallback must follow light appearance')
  resolved = theme.resolve({mermaid={theme='catppuccin-mocha',options={accent='#ff0000'}}})
  colors = resolved.options
  assert(resolved.name == 'dark' and colors.bg == '#1e1e2e' and colors.fg == '#cdd6f4', 'Mocha must stay dark independently of editor')
  assert(colors.accent == '#ff0000', 'explicit colors must override named palettes')
  print('PASS: black backgrounds, surface contrast, dark/light fallback, Mocha selection and explicit precedence')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
