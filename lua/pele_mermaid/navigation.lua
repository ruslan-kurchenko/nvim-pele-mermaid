local default_parser = require("pele_mermaid.parser")
local default_projection = require("pele_mermaid.projection")

local M = {}
local jumps = {}
local group = vim.api.nvim_create_augroup("PeleMermaidNavigation", { clear = true })

local function restore_jump(winid)
  local saved = jumps[winid]
  if not saved then return end
  jumps[winid] = nil
  if vim.api.nvim_win_is_valid(winid) and vim.wo[winid].scrolloff == 0 then
    vim.wo[winid].scrolloff = saved.scrolloff
  end
end

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinLeave", "BufLeave", "WinClosed" }, {
  group = group,
  callback = function(event)
    local win = event.event == "WinClosed" and tonumber(event.match) or vim.api.nvim_get_current_win()
    local saved = jumps[win]
    if saved and (event.event ~= "CursorMoved" and event.event ~= "CursorMovedI"
      or vim.api.nvim_win_get_cursor(win)[1] ~= saved.row) then
      restore_jump(win)
    end
  end,
})

function M.restore_view()
  for winid in pairs(jumps) do restore_jump(winid) end
end

local function extract_diagram_type(source)
  for _, line in ipairs(vim.split(source or "", "\n", { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^%%%%") and not trimmed:match("^classDef") then
      return trimmed
    end
  end
  return "mermaid"
end

local function nearest_heading(bufnr, start_row)
  if not vim.api.nvim_buf_is_valid(bufnr) then return "" end
  local rows = math.min(start_row, vim.api.nvim_buf_line_count(bufnr) - 1)
  if rows < 0 then return "" end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, rows + 1, false)
  for index = #lines, 1, -1 do
    local line = lines[index]
    if line:match("^#+%s+") then
      return vim.trim(line)
    end
  end
  return ""
end

local function jump_to(winid, row)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local target_line = row + 1
  vim.api.nvim_win_call(winid, function()
    restore_jump(winid)
    jumps[winid] = { scrolloff = vim.wo[winid].scrolloff, row = target_line }
    vim.wo[winid].scrolloff = 0
    vim.api.nvim_win_set_cursor(winid, { target_line, 0 })
    vim.cmd("normal! zt")
  end)
end

function M.items(bufnr, dependencies)
  dependencies = dependencies or {}
  local parser = dependencies.parser or default_parser
  local projection = dependencies.projection or default_projection
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end

  local is_proj = projection.is_projection and projection:is_projection(bufnr)
  local source_bufnr = is_proj and projection:source_buffer(bufnr) or bufnr
  local blocks = parser.index(source_bufnr)
  local list = {}

  for _, block in ipairs(blocks) do
    local target_row = block.start_row
    if is_proj then
      local dblock = projection:display_block(source_bufnr, block)
      if dblock then target_row = dblock.start_row end
    end
    list[#list + 1] = {
      id = block.id,
      bufnr = bufnr,
      source_bufnr = source_bufnr,
      row = target_row,
      source_row = block.start_row,
      type = extract_diagram_type(block.source),
      heading = nearest_heading(source_bufnr, block.start_row),
      complete = block.complete,
    }
  end

  table.sort(list, function(a, b) return a.row < b.row end)
  return list
end

function M.next(bufnr, winid, dependencies)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  local items = M.items(bufnr, dependencies)
  if #items == 0 then return nil end

  local cursor_row = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local target
  for _, item in ipairs(items) do
    if item.row > cursor_row then
      target = item
      break
    end
  end
  if not target then
    target = items[1] -- wrap to first
  end

  jump_to(winid, target.row)
  return target.row
end

function M.prev(bufnr, winid, dependencies)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  local items = M.items(bufnr, dependencies)
  if #items == 0 then return nil end

  local cursor_row = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local target
  for index = #items, 1, -1 do
    local item = items[index]
    if item.row < cursor_row then
      target = item
      break
    end
  end
  if not target then
    target = items[#items] -- wrap to last
  end

  jump_to(winid, target.row)
  return target.row
end

function M.list(bufnr, winid, dependencies)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  local items = M.items(bufnr, dependencies)
  if #items == 0 then
    vim.notify("pele_mermaid: no Mermaid diagrams found in buffer", vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt = "Mermaid Diagrams:",
    format_item = function(item)
      local heading_part = item.heading ~= "" and (" — " .. item.heading) or ""
      return ("Line %d: %s%s"):format(item.row + 1, item.type, heading_part)
    end,
  }, function(choice)
    if choice and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      jump_to(winid, choice.row)
    end
  end)
end

return M
