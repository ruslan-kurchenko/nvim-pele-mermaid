local default_backend = require("pele_mermaid.deps.image_backend")
local terminal = require("pele_mermaid.terminal")

local M = {}
local View = {}
View.__index = View

local namespace = vim.api.nvim_create_namespace("pele_mermaid.inline")

local function placement_id(bufnr, winid, block_id)
  return ("pele-mermaid:%d:%d:%d"):format(bufnr, winid, block_id)
end

local function window_percentage(value, total)
  if value <= 1 then return math.floor(value * 100) end
  return math.max(1, math.min(100, math.floor(value / total * 100)))
end


function View:_raise_conceal(winid)
  if self.original_conceallevel[winid] == nil then
    self.original_conceallevel[winid] = vim.wo[winid].conceallevel
  end
  if vim.wo[winid].conceallevel < 2 then
    vim.wo[winid].conceallevel = 2
  end
end

function View:_restore_conceal(winid)
  local original = self.original_conceallevel[winid]
  if original ~= nil and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].conceallevel = original
  end
  self.original_conceallevel[winid] = nil
end
function View:_delete_marks(bufnr, block_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  for _, field in ipairs({ "conceal_marks", "line_marks" }) do
    local marks = self[field][bufnr]
    local mark_id = marks and marks[block_id]
    if mark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, mark_id)
      marks[block_id] = nil
      if next(marks) == nil then self[field][bufnr] = nil end
    end
  end
end


function View:_track(bufnr, winid, block_id)
  self.block_windows[bufnr] = self.block_windows[bufnr] or {}
  self.block_windows[bufnr][block_id] = self.block_windows[bufnr][block_id] or {}
  self.block_windows[bufnr][block_id][winid] = true
  self.window_blocks[winid] = self.window_blocks[winid] or {}
  self.window_blocks[winid][bufnr .. ":" .. block_id] = { bufnr = bufnr, block_id = block_id }
  self:_raise_conceal(winid)
end

function View:_untrack(bufnr, winid, block_id)
  local by_buffer = self.block_windows[bufnr]
  local windows = by_buffer and by_buffer[block_id]
  if windows then
    windows[winid] = nil
    if next(windows) == nil then
      by_buffer[block_id] = nil
      self:_delete_marks(bufnr, block_id)
    end
    if next(by_buffer) == nil then
      self.block_windows[bufnr] = nil
    end
  end

  local blocks = self.window_blocks[winid]
  if blocks then
    blocks[bufnr .. ":" .. block_id] = nil
    if next(blocks) == nil then
      self.window_blocks[winid] = nil
      self:_restore_conceal(winid)
    end
  end
end

function View:_clear_all_block(bufnr, block_id)
  local windows = self.block_windows[bufnr] and self.block_windows[bufnr][block_id]
  local ids = {}
  if windows then
    for winid in pairs(windows) do ids[#ids + 1] = winid end
  end
  for _, winid in ipairs(ids) do
    self.backend.clear(placement_id(bufnr, winid, block_id))
    self:_untrack(bufnr, winid, block_id)
  end
  self.source_visible[bufnr] = self.source_visible[bufnr] or {}
  self.source_visible[bufnr][block_id] = true
  for id in pairs(self.displayed) do
    if id:match("^pele%-mermaid:" .. bufnr .. ":%d+:" .. block_id .. "$") then self.displayed[id] = nil end
  end
  self:_delete_marks(bufnr, block_id)
end

function View:_decorate(bufnr, winid, block)
  self.source_visible[bufnr] = self.source_visible[bufnr] or {}
  self.source_visible[bufnr][block.id] = nil
  self:_delete_marks(bufnr, block.id)

  if block.end_row > block.start_row then
    local opener = vim.api.nvim_buf_get_lines(bufnr, block.start_row, block.start_row + 1, false)[1] or ""
    self.conceal_marks[bufnr] = self.conceal_marks[bufnr] or {}
    self.conceal_marks[bufnr][block.id] = vim.api.nvim_buf_set_extmark(bufnr, namespace, block.start_row, 0, {
      end_row = block.start_row,
      end_col = #opener,
      conceal = "",
      right_gravity = false,
      end_right_gravity = true,
      strict = false,
    })

    self.line_marks[bufnr] = self.line_marks[bufnr] or {}
    self.line_marks[bufnr][block.id] = vim.api.nvim_buf_set_extmark(bufnr, namespace, block.start_row + 1, 0, {
      end_row = block.end_row + 1,
      end_col = 0,
      conceal_lines = "",
      right_gravity = false,
      end_right_gravity = true,
      strict = false,
    })
  end

  self:_track(bufnr, winid, block.id)
end
function View:update(bufnr, winid, block, artifact, options)
  local source_visible = self.source_visible[bufnr] and self.source_visible[bufnr][block.id]
  if options.active or not artifact then
    if source_visible then return true end
    self:_clear_all_block(bufnr, block.id)
    return true
  end

  if not artifact.png_path then
    self:_clear_all_block(bufnr, block.id)
    return false, "artifact has no PNG output"
  end
  local id = placement_id(bufnr, winid, block.id)
  local signature = tostring(artifact.key) .. ":" .. artifact.png_path
  if not source_visible and self.displayed[id] == signature then return true end


  self:_decorate(bufnr, winid, block)
  local ok, error_message = self.backend.render({
    id = id,
    path = artifact.png_path,
    buffer = bufnr,
    window = winid,
    row = block.start_row,
    col = 0,
    max_width_window_percentage = window_percentage(self.config.inline.max_width, vim.api.nvim_win_get_width(winid)),
    max_height_window_percentage = window_percentage(self.config.inline.max_height, vim.api.nvim_win_get_height(winid)),
  })
  if not ok then
    self:_clear_all_block(bufnr, block.id)
    return false, error_message
  end
  self.displayed[id] = signature
  return true
end

function View:clear_block(bufnr, winid, block_id)
  self.displayed[placement_id(bufnr, winid, block_id)] = nil
  self.backend.clear(placement_id(bufnr, winid, block_id))
  self:_untrack(bufnr, winid, block_id)
end

function View:clear_window(winid)
  local blocks = self.window_blocks[winid]
  local tracked = {}
  if blocks then
    for _, block in pairs(blocks) do tracked[#tracked + 1] = block end
  end
  for _, block in ipairs(tracked) do
    self:clear_block(block.bufnr, winid, block.block_id)
  end
  self.backend.clear_window(winid)
  self:_restore_conceal(winid)
end

function View:clear_buffer(bufnr)
  local blocks = self.block_windows[bufnr]
  local ids = {}
  if blocks then
    for block_id in pairs(blocks) do ids[#ids + 1] = block_id end
  end
  for _, block_id in ipairs(ids) do self:_clear_all_block(bufnr, block_id) end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  self.backend.clear_buffer(bufnr)
  self.source_visible[bufnr] = nil
  self.conceal_marks[bufnr] = nil
  self.line_marks[bufnr] = nil
end

function View:graphics_available()
  if self.graphics ~= nil then
    return self.graphics
  end
  local application = terminal.detect()
  self.graphics = terminal.kitty_graphics_available(application)
    and self.backend.is_available()
    and vim.fn.executable("magick") == 1
  return self.graphics
end

function View:width_px(winid, maximum)
  local columns = vim.api.nvim_win_get_width(winid)
  if maximum <= 1 then
    columns = math.max(1, math.floor(columns * maximum))
  else
    columns = math.min(columns, maximum)
  end

  local cell_width = 8
  local ok, term = pcall(require, "image/utils/term")
  if ok then
    local size = term.get_size()
    if size and size.cell_width and size.cell_width > 0 then
      cell_width = size.cell_width
    end
  end
  return math.max(1, math.floor(columns * cell_width))
end

function View:invalidate_graphics()
  self.graphics = nil
end

function M.new(config, dependencies)
  dependencies = dependencies or {}
  return setmetatable({
    config = config,
    backend = dependencies.backend or default_backend,
    displayed = {},
    conceal_marks = {},
    line_marks = {},
    source_visible = {},
    block_windows = {},
    window_blocks = {},
    original_conceallevel = {},
    graphics = dependencies.graphics,
  }, View)
end

function M.namespace()
  return namespace
end

function M.placement_id(bufnr, winid, block_id)
  return placement_id(bufnr, winid, block_id)
end

return M
