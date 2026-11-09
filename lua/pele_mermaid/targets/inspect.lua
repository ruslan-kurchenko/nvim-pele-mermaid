local default_backend = require("pele_mermaid.deps.image_backend")
local default_image = require("pele_mermaid.deps.image")

local M = {}
local Inspect = {}
Inspect.__index = Inspect

local ZOOM_LEVELS = { 1.0, 1.5, 2.0, 3.0 }

local function set_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

function M.new(runtime, view, config, dependencies)
  dependencies = dependencies or {}
  return setmetatable({
    runtime = runtime,
    view = view,
    config = config or {},
    backend = dependencies.backend or default_backend,
    preview_win = nil,
    image = dependencies.image or default_image,
    preview_buf = nil,
    source_win = nil,
    source_buf = nil,
    block = nil,
    image_id = "pele-mermaid-inspect",
    zoom_idx = 1,
    zoom_level = 1.0,
    pan_x = 0,
    pan_y = 0,
    pending = nil,
    generation = 0,
  }, Inspect)
end

function Inspect:_title()
  return (" Mermaid Inspector [%d%%] [+/-: zoom | 0: reset | h/j/k/l: pan | q: exit] "):format(
    math.floor(self.zoom_level * 100)
  )
end

function Inspect:_dimensions()
  local total_w = vim.o.columns
  local total_h = vim.o.lines
  local width = math.max(10, math.floor(total_w * 0.95))
  local height = math.max(5, math.floor(total_h * 0.90))
  local row = math.max(0, math.floor((total_h - height) / 2))
  local col = math.max(0, math.floor((total_w - width) / 2))
  return { width = width, height = height, row = row, col = col }
end

function Inspect:is_open()
  return self.preview_win ~= nil
    and vim.api.nvim_win_is_valid(self.preview_win)
    and self.preview_buf ~= nil
    and vim.api.nvim_buf_is_valid(self.preview_buf)
end
function Inspect:_cancel_crop()
  if self.crop then self.crop.cancel(); self.crop = nil end
  if self.candidate and self.candidate ~= self.artifact and self.candidate.release then
    self.candidate.release()
  end
  self.candidate = nil
end

function Inspect:_error(message)
  self.error = tostring(message)
  if not self.artifact then set_lines(self.preview_buf, { "Error: " .. self.error }) end
  vim.notify("pele_mermaid: inspector: " .. self.error, vim.log.levels.ERROR)
end


function Inspect:_display(artifact)
  if not self:is_open() then return end
  self.generation = self.generation + 1
  local generation = self.generation
  self:_cancel_crop()
  self.candidate = artifact
  local cell_width, cell_height = self.image.cell_size()
  self.crop = self.image.viewport({
    path = artifact.png_path,
    width = self.view:width_px(self.preview_win, 1),
    height = vim.api.nvim_win_get_height(self.preview_win) * cell_height,
    x = self.pan_x * cell_width,
    y = self.pan_y * cell_height,
  }, function(result)
    if generation ~= self.generation or not self:is_open() then
      if result.temporary then vim.uv.fs_unlink(result.path) end
      return
    end
    self.crop = nil
    if not result.ok then
      if artifact ~= self.artifact and artifact.release then artifact.release() end
      self.candidate = nil
      self:_error(result.error)
      return
    end
    local ok, err = self.backend.render({
      id = self.image_id, path = result.path, buffer = self.preview_buf,
      window = self.preview_win, row = 0, col = 0,
      inline = false, with_virtual_padding = false, native_pixels = true,
    })
    if not ok then
      if result.temporary then vim.uv.fs_unlink(result.path) end
      if artifact ~= self.artifact and artifact.release then artifact.release() end
      self.candidate = nil
      self:_error(err)
      return
    end
    local previous = self.artifact
    local previous_viewport = self.viewport_path
    self.artifact = artifact
    self.candidate = nil
    self.viewport_path = result.temporary and result.path or nil
    self.pan_x = math.floor(result.x / cell_width)
    self.pan_y = math.floor(result.y / cell_height)
    self.error = nil
    set_lines(self.preview_buf, { "" })
    if previous_viewport and previous_viewport ~= self.viewport_path then vim.uv.fs_unlink(previous_viewport) end
    if previous and previous ~= artifact and previous.release then previous.release() end
  end)
end

function Inspect:_render_current()
  if not self:is_open() or not self.block then return end
  self.generation = self.generation + 1
  local generation = self.generation
  if self.pending then self.pending.cancel(); self.pending = nil end
  self:_cancel_crop()
  if not self.view:graphics_available() then
    self:_error("Mermaid inspector requires Kitty graphics, image.nvim, and ImageMagick")
    return
  end
  self.pending = self.runtime:request(self.block, {
    output = "svg", want_png = true,
    width_px = math.floor(self.view:width_px(self.preview_win, 1) * self.zoom_level),
  }, function(result)
    if generation ~= self.generation or not self:is_open() then
      if result.release then result.release() end
      return
    end
    self.pending = nil
    if not result.ok then
      self:_error(result.error or "failed to render diagram")
      return
    end
    self:_display(result)
  end)
  pcall(vim.api.nvim_win_set_config, self.preview_win, { title = self:_title() })
end

function Inspect:zoom_in()
  if not self:is_open() then return end
  if self.zoom_idx < #ZOOM_LEVELS then
    self.zoom_idx = self.zoom_idx + 1
    self.zoom_level = ZOOM_LEVELS[self.zoom_idx]
    self:_render_current()
  end
end

function Inspect:zoom_out()
  if not self:is_open() then return end
  if self.zoom_idx > 1 then
    self.zoom_idx = self.zoom_idx - 1
    self.zoom_level = ZOOM_LEVELS[self.zoom_idx]
    self:_render_current()
  end
end

function Inspect:reset_zoom()
  if not self:is_open() then return end
  self.zoom_idx = 1
  self.zoom_level = ZOOM_LEVELS[1]
  self.pan_x = 0
  self.pan_y = 0
  self:_render_current()
end

function Inspect:pan(dx, dy)
  if not self:is_open() then return end
  self.pan_x = math.max(0, self.pan_x + (dx or 0))
  self.pan_y = math.max(0, self.pan_y + (dy or 0))
  if self.artifact then self:_display(self.artifact) end
end

function Inspect:open()
  if self:is_open() then return true end

  self.source_win = vim.api.nvim_get_current_win()
  self.source_buf = vim.api.nvim_win_get_buf(self.source_win)
  self.block = self.runtime:current_block(self.source_buf, self.source_win)

  if not self.block or not self.block.complete then
    vim.notify("pele_mermaid: current Mermaid block is incomplete or missing", vim.log.levels.ERROR)
    return false
  end

  local dims = self:_dimensions()
  self.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.preview_buf].buftype = "nofile"
  vim.bo[self.preview_buf].bufhidden = "wipe"
  vim.bo[self.preview_buf].swapfile = false
  vim.bo[self.preview_buf].filetype = "mermaid-inspect"

  self.preview_win = vim.api.nvim_open_win(self.preview_buf, true, {
    relative = "editor",
    width = dims.width,
    height = dims.height,
    row = dims.row,
    col = dims.col,
    style = "minimal",
    border = "rounded",
    title = self:_title(),
    title_pos = "center",
  })

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = self.preview_buf, silent = true, nowait = true })
  end

  map("q", function() self:close() end)
  map("<Esc>", function() self:close() end)
  map("+", function() self:zoom_in() end)
  map("=", function() self:zoom_in() end)
  map("-", function() self:zoom_out() end)
  map("0", function() self:reset_zoom() end)
  map("h", function() self:pan(-1, 0) end)
  map("l", function() self:pan(1, 0) end)
  map("k", function() self:pan(0, -1) end)
  map("j", function() self:pan(0, 1) end)

  self.group = vim.api.nvim_create_augroup("PeleMermaidInspect", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = self.group,
    callback = function()
      if not self:is_open() then return end
      local resized = self:_dimensions()
      vim.api.nvim_win_set_config(self.preview_win, {
        relative = "editor", row = resized.row, col = resized.col,
        width = resized.width, height = resized.height,
      })
      self:_render_current()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(event)
      if tonumber(event.match) == self.preview_win or tonumber(event.match) == self.source_win then
        vim.schedule(function() self:close() end)
      end
    end,
  })
  self.pan_x, self.pan_y = 0, 0
  self.zoom_idx = 1
  self.zoom_level = ZOOM_LEVELS[1]
  self:_render_current()
  return true
end

function Inspect:close()
  self.generation = self.generation + 1
  if self.group then pcall(vim.api.nvim_del_augroup_by_id, self.group); self.group = nil end
  self:_cancel_crop()
  if self.pending then
    self.pending.cancel()
    self.pending = nil
  end
  self.backend.clear(self.image_id)
  if self.viewport_path then vim.uv.fs_unlink(self.viewport_path); self.viewport_path = nil end
  if self.artifact and self.artifact.release then self.artifact.release() end
  self.artifact = nil

  if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
    vim.api.nvim_win_close(self.preview_win, true)
  end
  if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
    vim.api.nvim_buf_delete(self.preview_buf, { force = true })
  end

  self.preview_win = nil
  self.preview_buf = nil
end

function Inspect:toggle()
  if self:is_open() then
    self:close()
    return false
  end
  return self:open()
end

return M
