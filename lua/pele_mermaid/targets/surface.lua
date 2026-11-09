local default_backend = require("pele_mermaid.deps.image_backend")

local M = {}
local Surface = {}
Surface.__index = Surface

local function set_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

function Surface:_render(artifact, error_message)
  if not self:is_open() then
    return false, "preview is closed"
  end
  if not artifact then
    set_lines(self.preview_buf, { error_message or "Move cursor to a Mermaid block to preview" })
    self.backend.clear(self.image_id)
    return true
  end

  local row = error_message and 1 or 0
  local ok, display_error = self.backend.render({
    id = self.image_id,
    path = artifact.png_path,
    buffer = self.preview_buf,
    window = self.preview_win,
    row = row,
    inline = false,
    with_virtual_padding = false,
    col = 0,
    max_width_window_percentage = 100,
    max_height_window_percentage = 95,
  })
  if not ok then
    self.error = display_error
    if not self.last_good then
      set_lines(self.preview_buf, { "Mermaid preview unavailable: " .. tostring(display_error) })
    end
    vim.notify("pele_mermaid: preview: " .. tostring(display_error), vim.log.levels.ERROR)
    return false, display_error
  end
  set_lines(self.preview_buf, error_message and { "Mermaid preview stale: " .. error_message, "" } or { "" })
  self.error = error_message
  return true
end


function Surface:refresh()
  if not self:is_open() or not vim.api.nvim_win_is_valid(self.source_win) then
    self:close()
    return
  end

  local display_buf = vim.api.nvim_win_get_buf(self.source_win)
  self.source_buf = self.runtime.projection and self.runtime.projection:source_buffer(display_buf) or display_buf
  local block = self.runtime:current_block(display_buf, self.source_win)
  local identity = block and (tostring(block.bufnr or self.source_buf) .. ":" .. tostring(block.id))
  if identity ~= self.identity then
    if self.last_good and self.last_good.release then self.last_good.release() end
    self.last_good = nil
    self.backend.clear(self.image_id)
  end
  self.identity = identity
  self.block = block
  self.generation = self.generation + 1
  local generation = self.generation
  if self.pending then
    self.pending.cancel()
    self.pending = nil
  end
  if not self.block or not self.block.complete then
    self.error = "Mermaid block is incomplete or missing"
    self:_render(self.last_good, self.error)
    return
  end

  if not self.view:graphics_available() then
    self.backend.clear(self.image_id)
    set_lines(self.preview_buf, { "Mermaid preview requires Kitty graphics, image.nvim, and ImageMagick" })
    return
  end
  local options = { output = "svg", want_png = true, width_px = self.view:width_px(self.preview_win, 1) }
  self.pending = self.runtime:request(self.block, options, function(result)
    if generation ~= self.generation or not self:is_open() then
      if result.release then result.release() end
      return
    end
    self.pending = nil
    if not result.ok then
      self.error = result.error
      self:_render(self.last_good, self.error)
      return
    end
    if not self:_render(result) then
      if result.release then result.release() end
      return
    end
    local previous = self.last_good
    self.last_good = result
    if previous and previous ~= result and previous.release then previous.release() end
  end)
end

function Surface:subscribe(group, debounce)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
    group = group,
    callback = function(event)
      if self.closed or not vim.api.nvim_win_is_valid(self.source_win) then return end
      if event.buf == vim.api.nvim_win_get_buf(self.source_win) then self:refresh() end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      if not self.closed and event.buf == self.source_buf then debounce() end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      if event.buf == self.source_buf then vim.schedule(function() self:close() end) end
    end,
  })
end

function Surface:resize()
  if not self:is_open() then return end
  self.resize_window(self)
  self:refresh()
end

function Surface:is_open()
  return self.preview_win
    and vim.api.nvim_win_is_valid(self.preview_win)
    and self.preview_buf
    and vim.api.nvim_buf_is_valid(self.preview_buf)
end

function Surface:close()
  if self.closed then return end
  self.closed = true
  self.generation = self.generation + 1
  if self.pending then
    self.pending.cancel()
    self.pending = nil
  end
  self.backend.clear(self.image_id)
  if self.last_good and self.last_good.release then self.last_good.release() end
  self.last_good = nil
  if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
    vim.api.nvim_win_close(self.preview_win, true)
  end
  if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
    vim.api.nvim_buf_delete(self.preview_buf, { force = true })
  end
  self.preview_win = nil
  self.preview_buf = nil
  if self.on_close then self.on_close(self) end
end

function M.new(options)
  return setmetatable({
    runtime = options.runtime,
    view = options.view,
    backend = options.backend or default_backend,
    source_win = options.source_win,
    source_buf = options.source_buf,
    preview_win = options.preview_win,
    preview_buf = options.preview_buf,
    image_id = options.image_id,
    resize_window = options.resize_window,
    on_close = options.on_close,
    generation = 0,
    pending = nil,
    block = nil,
    last_good = nil,
    error = nil,
    closed = false,
  }, Surface)
end

return M
