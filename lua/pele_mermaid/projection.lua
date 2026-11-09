local default_parser = require("pele_mermaid.parser")

local M = {}
local Projection = {}
Projection.__index = Projection

function M.new(dependencies)
  dependencies = dependencies or {}
  return setmetatable({
    parser = dependencies.parser or default_parser,
    sources = {},      -- [source_bufnr] = { projected_bufnr, blocks, display_blocks, anchor_to_block, block_to_anchor, windows }
    projections = {},  -- [projected_bufnr] = source_bufnr
    original_scrolloff = {},
    original_wrap = {},
  }, Projection)
end

function Projection:is_projection(bufnr)
  return self.projections[bufnr] ~= nil
end

function Projection:source_buffer(bufnr)
  return self.projections[bufnr]
end

function Projection:projection_buffer(source_bufnr)
  local record = self.sources[source_bufnr]
  return record and record.projected_bufnr
end

function Projection:active_window(source_bufnr)
  local record = self.sources[source_bufnr]
  if not record or not record.windows then return nil end
  for winid in pairs(record.windows) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == record.projected_bufnr then
      return winid
    end
  end
  return nil
end

function Projection:refresh(source_bufnr)
  local record = self.sources[source_bufnr]
  local winid = self:active_window(source_bufnr)
  if record and winid and record.changedtick ~= vim.api.nvim_buf_get_changedtick(source_bufnr) then
    self:enter(source_bufnr, winid)
  end
end

function Projection:track_window(source_bufnr, winid)
  local record = self.sources[source_bufnr]
  if not record or record.windows[winid] then return end
  local original = self:active_window(source_bufnr)
  self.original_scrolloff[winid] = original and self.original_scrolloff[original] or vim.wo[winid].scrolloff
  local wrap = original and self.original_wrap[original]
  if wrap == nil then wrap = vim.wo[winid].wrap end
  self.original_wrap[winid] = wrap
  record.windows[winid] = {}
  vim.wo[winid].scrolloff = 0
  vim.wo[winid].wrap = true
end

local function build_mapping(source_lines, blocks)
  local projected_lines = {}
  local display_blocks = {}
  local anchor_to_block = {}
  local block_to_anchor = {}

  local sorted_blocks = vim.deepcopy(blocks)
  table.sort(sorted_blocks, function(a, b) return a.start_row < b.start_row end)

  local current_source_row = 0
  local current_projected_row = 0

  for _, block in ipairs(sorted_blocks) do
    -- Copy lines before block
    while current_source_row < block.start_row and current_source_row < #source_lines do
      projected_lines[#projected_lines + 1] = source_lines[current_source_row + 1]
      current_source_row = current_source_row + 1
      current_projected_row = current_projected_row + 1
    end

    -- Replace block with single anchor line
    local anchor_row = current_projected_row
    projected_lines[#projected_lines + 1] = ""
    current_projected_row = current_projected_row + 1
    current_source_row = math.min(#source_lines, block.end_row + 1)

    anchor_to_block[anchor_row] = block
    block_to_anchor[block.id] = anchor_row
    display_blocks[block.id] = {
      id = block.id,
      start_row = anchor_row,
      end_row = anchor_row,
      source_hash = block.source_hash,
      complete = block.complete,
      source = block.source,
    }
  end

  -- Copy trailing lines
  while current_source_row < #source_lines do
    projected_lines[#projected_lines + 1] = source_lines[current_source_row + 1]
    current_source_row = current_source_row + 1
    current_projected_row = current_projected_row + 1
  end

  if #projected_lines == 0 then
    projected_lines = { "" }
  end

  return projected_lines, display_blocks, anchor_to_block, block_to_anchor, sorted_blocks
end

function Projection:source_to_projected_row(source_bufnr, source_row)
  local record = self.sources[source_bufnr]
  if not record or not record.sorted_blocks then return source_row end

  local offset = 0
  for _, block in ipairs(record.sorted_blocks) do
    if source_row < block.start_row then
      return math.max(0, source_row - offset)
    end
    if source_row <= block.end_row then
      return math.max(0, block.start_row - offset)
    end
    offset = offset + (block.end_row - block.start_row)
  end
  return math.max(0, source_row - offset)
end

function Projection:projected_to_source_row(source_bufnr, projected_row)
  local record = self.sources[source_bufnr]
  if not record or not record.sorted_blocks then return projected_row end

  local offset = 0
  for _, block in ipairs(record.sorted_blocks) do
    local anchor = block.start_row - offset
    if projected_row < anchor then
      return projected_row + offset
    end
    if projected_row == anchor then
      return block.start_row
    end
    offset = offset + (block.end_row - block.start_row)
  end
  return projected_row + offset
end

function Projection:enter(source_bufnr, winid, blocks)
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(source_bufnr) then return nil end

  local source_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
  blocks = blocks or self.parser.index(source_bufnr)

  local projected_lines, display_blocks, anchor_to_block, block_to_anchor, sorted_blocks =
    build_mapping(source_lines, blocks)

  local record = self.sources[source_bufnr]
  local positions = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if window == winid or (record and vim.api.nvim_win_get_buf(window) == record.projected_bufnr) then
      local cursor = vim.api.nvim_win_get_cursor(window)
      if record and vim.api.nvim_win_get_buf(window) == record.projected_bufnr then
        cursor[1] = self:projected_to_source_row(source_bufnr, cursor[1] - 1) + 1
      end
      positions[window] = cursor
    end
  end
  local projected_bufnr
  if record and record.projected_bufnr and vim.api.nvim_buf_is_valid(record.projected_bufnr) then
    projected_bufnr = record.projected_bufnr
  else
    projected_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[projected_bufnr].buftype = "nofile"
    vim.bo[projected_bufnr].bufhidden = "hide"
    vim.bo[projected_bufnr].swapfile = false
    vim.bo[projected_bufnr].filetype = vim.bo[source_bufnr].filetype
    local name = vim.api.nvim_buf_get_name(source_bufnr)
    if name ~= "" then
      pcall(vim.api.nvim_buf_set_name, projected_bufnr, "[Mermaid] " .. vim.fn.fnamemodify(name, ":t"))
    end
  end

  vim.bo[projected_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(projected_bufnr, 0, -1, false, projected_lines)
  vim.bo[projected_bufnr].modifiable = false

  for _, dblock in pairs(display_blocks) do
    dblock.bufnr = projected_bufnr
  end

  record = {
    projected_bufnr = projected_bufnr,
    changedtick = vim.api.nvim_buf_get_changedtick(source_bufnr),
    blocks = blocks,
    display_blocks = display_blocks,
    anchor_to_block = anchor_to_block,
    block_to_anchor = block_to_anchor,
    sorted_blocks = sorted_blocks,
    windows = (record and record.windows) or {},
  }
  if not record.windows[winid] then
    record.windows[winid] = { cursor = positions[winid] }
  end
  self.sources[source_bufnr] = record
  self.projections[projected_bufnr] = source_bufnr


  self.original_scrolloff = self.original_scrolloff or {}
  if self.original_scrolloff[winid] == nil and vim.api.nvim_win_is_valid(winid) then
    self.original_scrolloff[winid] = vim.wo[winid].scrolloff
  end

  self.original_wrap = self.original_wrap or {}
  if self.original_wrap[winid] == nil and vim.api.nvim_win_is_valid(winid) then
    self.original_wrap[winid] = vim.wo[winid].wrap
  end

  if vim.api.nvim_win_get_buf(winid) ~= projected_bufnr then
    vim.api.nvim_win_set_buf(winid, projected_bufnr)
  end
  vim.wo[winid].scrolloff = 0
  vim.wo[winid].wrap = true
  vim.api.nvim_win_call(winid, function() vim.fn.winrestview({ leftcol = 0 }) end)
  for window, cursor in pairs(positions) do
    local row = math.min(self:source_to_projected_row(source_bufnr, cursor[1] - 1), #projected_lines - 1)
    local col = math.min(cursor[2], #(projected_lines[row + 1] or ""))
    pcall(vim.api.nvim_win_set_cursor, window, { row + 1, col })
  end
  return projected_bufnr
end

function Projection:leave(projected_bufnr, winid)
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  local source_bufnr = self.projections[projected_bufnr]
  if not source_bufnr or not vim.api.nvim_buf_is_valid(source_bufnr) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local target_source_row = self:projected_to_source_row(source_bufnr, cursor[1] - 1)
  local source_line_count = vim.api.nvim_buf_line_count(source_bufnr)
  target_source_row = math.min(target_source_row, math.max(0, source_line_count - 1))

  local record = self.sources[source_bufnr]
  local saved = record and record.windows[winid]
  local target_col = cursor[2]
  if type(saved) == "table" and saved.cursor
    and self:source_to_projected_row(source_bufnr, saved.cursor[1] - 1) == cursor[1] - 1 then
    target_source_row = math.min(saved.cursor[1] - 1, source_line_count - 1)
    target_col = saved.cursor[2]
  end
  if record and record.windows then
    record.windows[winid] = nil
  end

  vim.api.nvim_win_set_buf(winid, source_bufnr)
  self:cleanup_window(winid)
  pcall(vim.api.nvim_win_set_cursor, winid, { target_source_row + 1, target_col })
  return source_bufnr
end

function Projection:display_block(source_bufnr, block)
  local record = self.sources[source_bufnr]
  if not record then return nil end
  return record.display_blocks[block.id]
end

function Projection:display_blocks(source_bufnr)
  local record = self.sources[source_bufnr]
  if not record then return {} end
  local list = {}
  for _, block in ipairs(record.sorted_blocks) do
    local dblock = record.display_blocks[block.id]
    if dblock then list[#list + 1] = dblock end
  end
  return list
end

function Projection:block_at(projected_bufnr, row)
  local source_bufnr = self.projections[projected_bufnr]
  if not source_bufnr then return nil end
  local record = self.sources[source_bufnr]
  if not record then return nil end
  return record.anchor_to_block[row]
end

function Projection:cleanup_window(winid)
  if vim.api.nvim_win_is_valid(winid) then
    if self.original_scrolloff[winid] ~= nil then
      vim.wo[winid].scrolloff = self.original_scrolloff[winid]
    end
    if self.original_wrap[winid] ~= nil then
      vim.wo[winid].wrap = self.original_wrap[winid]
    end
  end
  self.original_scrolloff[winid] = nil
  self.original_wrap[winid] = nil
  for _, record in pairs(self.sources) do record.windows[winid] = nil end
end

function Projection:cleanup_source(source_bufnr)
  local record = self.sources[source_bufnr]
  if record then
    local windows = vim.tbl_keys(record.windows)
    for _, winid in ipairs(windows) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == record.projected_bufnr
        and vim.api.nvim_buf_is_valid(source_bufnr) then
        self:leave(record.projected_bufnr, winid)
      else
        self:cleanup_window(winid)
      end
    end
    if record.projected_bufnr and vim.api.nvim_buf_is_valid(record.projected_bufnr) then
      self.projections[record.projected_bufnr] = nil
      pcall(vim.api.nvim_buf_delete, record.projected_bufnr, { force = true })
    end
    self.sources[source_bufnr] = nil
  end
end

function Projection:cleanup_projection(projected_bufnr)
  local source_bufnr = self.projections[projected_bufnr]
  if source_bufnr then
    local record = self.sources[source_bufnr]
    if record and record.projected_bufnr == projected_bufnr then
      for _, winid in ipairs(vim.tbl_keys(record.windows)) do self:cleanup_window(winid) end
      record.projected_bufnr = nil
    end
    self.projections[projected_bufnr] = nil
  end
end

return M
