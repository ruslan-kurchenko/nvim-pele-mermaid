local M = {}

local namespace = vim.api.nvim_create_namespace("pele_mermaid.blocks")
local cache = {}
local scan_counts = {}

local function fence_parts(line)
  local indent = line:match("^( *)") or ""
  if #indent > 3 then
    return nil
  end
  local rest = line:sub(#indent + 1)
  local character = rest:sub(1, 1)
  if character ~= "`" and character ~= "~" then
    return nil
  end
  local run = rest:match("^(" .. character .. "+)")
  if not run or #run < 3 then
    return nil
  end
  return {
    character = character,
    length = #run,
    indent = #indent,
    suffix = rest:sub(#run + 1),
  }
end

local function is_mermaid_opener(line)
  local fence = fence_parts(line)
  if not fence then
    return nil
  end
  local token = fence.suffix:match("^%s*(%S+)")
  if not token or token:lower() ~= "mermaid" then
    return nil
  end
  return fence
end

local function is_closer(line, opener)
  local fence = fence_parts(line)
  return fence
    and fence.character == opener.character
    and fence.length >= opener.length
    and fence.suffix:match("^%s*$") ~= nil
end

local function strip_indent(line, count)
  local removed = 0
  while removed < count and line:sub(removed + 1, removed + 1) == " " do
    removed = removed + 1
  end
  return line:sub(removed + 1)
end

local function scan(bufnr)
  scan_counts[bufnr] = (scan_counts[bufnr] or 0) + 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local candidates = {}
  local row = 0

  while row < #lines do
    local opener = is_mermaid_opener(lines[row + 1])
    if not opener then
      local other = fence_parts(lines[row + 1])
      row = row + 1
      if other then
        while row < #lines and not is_closer(lines[row + 1], other) do row = row + 1 end
        row = row + 1
      end
    else
      local content = {}
      local closing_row
      local next_row = row + 1
      while next_row < #lines do
        if is_closer(lines[next_row + 1], opener) then
          closing_row = next_row
          break
        end
        content[#content + 1] = strip_indent(lines[next_row + 1], opener.indent)
        next_row = next_row + 1
      end

      local complete = closing_row ~= nil
      candidates[#candidates + 1] = {
        start_row = row,
        end_row = closing_row or math.max(row, #lines - 1),
        source = table.concat(content, "\n"),
        complete = complete,
        end_col = complete and #lines[closing_row + 1] or #(lines[#lines] or ""),
      }
      row = complete and (closing_row + 1) or #lines
    end
  end

  return candidates
end

local function current_ids_by_row(bufnr, previous)
  local by_row = {}
  for _, block in ipairs(previous or {}) do
    local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, block.id, {})
    if #position > 0 then
      by_row[position[1]] = block.id
    end
  end
  return by_row
end

local function reconcile(bufnr, candidates, previous)
  local ids_by_row = current_ids_by_row(bufnr, previous)
  local retained = {}
  local blocks = {}

  for _, candidate in ipairs(candidates) do
    local id = ids_by_row[candidate.start_row]
    local options = {
      id = id,
      end_row = candidate.end_row,
      end_col = candidate.end_col,
      right_gravity = false,
      end_right_gravity = true,
      strict = false,
    }
    id = vim.api.nvim_buf_set_extmark(bufnr, namespace, candidate.start_row, 0, options)
    retained[id] = true
    blocks[#blocks + 1] = {
      id = id,
      bufnr = bufnr,
      start_row = candidate.start_row,
      end_row = candidate.end_row,
      source = candidate.source,
      source_hash = vim.fn.sha256(candidate.source),
      complete = candidate.complete,
    }
  end

  for _, block in ipairs(previous or {}) do
    if not retained[block.id] then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, block.id)
    end
  end
  return blocks
end

function M.index(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = cache[bufnr]
  if entry and entry.changedtick == changedtick then
    return entry.blocks
  end

  local blocks = reconcile(bufnr, scan(bufnr), entry and entry.blocks or nil)
  cache[bufnr] = { changedtick = changedtick, blocks = blocks }
  return blocks
end

function M.at(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local blocks = M.index(bufnr)
  local low, high = 1, #blocks
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local block = blocks[middle]
    if row < block.start_row then
      high = middle - 1
    elseif row > block.end_row then
      low = middle + 1
    else
      return block
    end
  end
  return nil
end


function M.position(bufnr, id)
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, id, { details = true })
  if #position == 0 then
    return nil
  end
  local details = position[3]
  return {
    start_row = position[1],
    start_col = position[2],
    end_row = details.end_row,
    end_col = details.end_col,
  }
end

function M.invalidate(bufnr)
  cache[bufnr] = nil
end

function M.clear(bufnr)
  cache[bufnr] = nil
  scan_counts[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

function M.namespace()
  return namespace
end

function M._scan_count(bufnr)
  return scan_counts[bufnr] or 0
end

return M
