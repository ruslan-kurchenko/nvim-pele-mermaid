local M = {}

function M.check()
  local health = vim.health
  health.start('pele_mermaid')
  if vim.fn.has('nvim-0.11') == 1 then health.ok('Neovim >= 0.11')
  else health.error('Neovim 0.11+ required') end

  local cfg = require('pele_mermaid').get_config()
  local command, err = require('pele_mermaid.deps.runtime').resolve(cfg)
  if command then health.ok('Renderer runtime: ' .. command) else health.error(err) end
  local script = require('pele_mermaid.deps.renderer').script_path(cfg.renderer)
  if vim.fn.filereadable(script) == 1 then health.ok('Pele renderer script available')
  else health.error('Renderer script missing: ' .. script) end
  local root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ':h:h:h')
  if vim.fn.filereadable(root .. '/node_modules/pele/dist/pele.js') == 1 then
    health.ok('Pele installed')
  else health.error('Run the plugin build hook to install Pele dependencies') end
  if vim.fn.filereadable(root .. '/assets/fonts/MapleMono-NF-Regular.ttf') == 1 then
    health.ok('Bundled Maple Mono NF available')
  else health.error('Bundled Maple Mono NF font missing') end
  if vim.fn.executable('magick') == 1 then health.ok('ImageMagick available for image processing and inspector crops')
  else health.error('Install ImageMagick (magick) for image.nvim and the inspector') end

  local ok, image = pcall(require, 'image')
  if ok and image.from_file then health.ok('image.nvim available')
  else health.error('image.nvim is required for graphical previews') end
  local rasterizer = require('pele_mermaid.deps.rasterizer')
  local raster = rasterizer.get_command(cfg.rasterizer)
  if raster then health.ok('Rasterizer: ' .. raster)
  else health.error('Install resvg (recommended), rsvg-convert, or ImageMagick') end

  if vim.fn.has('mac') == 1 then
    health.info('PNG clipboard uses the macOS pasteboard')
  elseif vim.fn.executable('wl-copy') == 1 or vim.fn.executable('xclip') == 1 then
    health.ok('PNG clipboard provider available')
  else health.warn('Install wl-copy (Wayland) or xclip (X11) for MermaidYank') end
  health.info('Markdown opens as source; MermaidToggle enters the reading view')
  health.info('Theme: ' .. cfg.mermaid.theme .. '; terminal: ' .. (vim.env.TERM_PROGRAM or vim.env.TERM or 'unknown'))
end

return M
