local M = {}

local function is_flowchart(source)
  for line in (source or ""):gmatch("[^\n]+") do
    local kind = vim.trim(line)
    if kind:match("^flowchart%s") or kind:match("^graph%s") then return true end
    if kind ~= "" and not kind:match("^%%%%") then return false end
  end
  return false
end

local function shield_quotes(line, shield)
  local parts, start, index = {}, 1, 1
  while index <= #line do
    if line:sub(index, index) == '"' then
      parts[#parts + 1] = line:sub(start, index - 1)
      local first = index
      index = index + 1
      while index <= #line do
        local char = line:sub(index, index)
        if char == "\\" then
          index = index + 2
        elseif char == '"' then
          index = index + 1
          break
        else
          index = index + 1
        end
      end
      parts[#parts + 1] = shield(line:sub(first, index - 1))
      start = index
    else
      index = index + 1
    end
  end
  parts[#parts + 1] = line:sub(start)
  return table.concat(parts)
end

function M.lint(source)
  local issues = {}
  local lines = vim.split(source or "", "\n", { plain = true })
  if not is_flowchart(source) then return issues end

  for idx, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if not trimmed:match("^%%%%") then
      -- 1. Unquoted parentheses in node brackets
      if line:match("[%w_]+%[[^\"%]\r\n]*[%(%)][^\"%]\r\n]*%]") then
        issues[#issues + 1] = {
          line = idx,
          message = "Unquoted parentheses in node label; wrap in quotes like [\"...\"]",
          severity = "warn",
        }
      end

      -- 2. Trailing semicolons
      if line:match(";%s*$") then
        issues[#issues + 1] = {
          line = idx,
          message = "Trailing semicolon is unnecessary in Mermaid",
          severity = "info",
        }
      end

      -- 3. Invalid single-dash arrows in flowcharts
      if line:match("[%w_%)%]]%s*%->%s*[%w_%(%[]") then
        issues[#issues + 1] = {
          line = idx,
          message = "Single-dash arrow '->' is invalid in flowchart; use '-->'",
          severity = "warn",
        }
      end
    end
  end

  return issues
end

function M.fix(source)
  source = source or ""
  if not is_flowchart(source) then return { fixed = source, changed = false, count = 0 } end
  local lines = vim.split(source, "\n", { plain = true })
  local count = 0
  for index, line in ipairs(lines) do
    if not vim.trim(line):match("^%%%%") then
      -- Shield existing quoted text from all repairs.
      local quoted = {}
      local function shield(value)
        quoted[#quoted + 1] = value
        return "\1" .. #quoted .. "\2"
      end
      local current = shield_quotes(line, shield)
      local comment = ""
      local comment_start = current:find("%%", 1, true)
      if comment_start then
        comment = current:sub(comment_start)
        current = current:sub(1, comment_start - 1)
      end
      local changes
      current, changes = current:gsub(";%s*$", "")
      count = count + changes
      current, changes = current:gsub("([%w_%)%]])%s*%->%s*([%w_%(%[])", "%1 --> %2")
      count = count + changes
      current, changes = current:gsub('([%w_]+)%[([^%]%[\1]*[%(%)%/%:%+&%*][^%]%[\1]*)%]', function(id, label)
        return id .. "[" .. shield('"' .. label .. '"') .. "]"
      end)
      count = count + changes
      current, changes = current:gsub('([%w_]+)%(([^()\1]*[%[%]%/%:%+&%*][^()\1]*)%)', function(id, label)
        return id .. "(" .. shield('"' .. label .. '"') .. ")"
      end)
      count = count + changes
      lines[index] = (current .. comment):gsub("\1(%d+)\2", function(id) return quoted[tonumber(id)] end)
    end
  end
  local fixed = table.concat(lines, "\n")
  return { fixed = fixed, changed = fixed ~= source, count = count }
end

function M.fix_block(bufnr, block)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if not block or block.start_row >= block.end_row then return false end

  -- In source buffer: lines between opener and closer
  local opener_row = block.start_row
  local closer_row = block.complete and block.end_row or (block.end_row + 1)
  local inner_lines = vim.api.nvim_buf_get_lines(bufnr, opener_row + 1, closer_row, false)
  local inner_source = table.concat(inner_lines, "\n")

  local res = M.fix(inner_source)
  if res.changed then
    local new_lines = vim.split(res.fixed, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, opener_row + 1, closer_row, false, new_lines)
    vim.notify(("pele_mermaid: auto-fixed %d Mermaid syntax issue(s)"):format(res.count), vim.log.levels.INFO)
    return true
  else
    vim.notify("pele_mermaid: no auto-fixable syntax issues found in diagram", vim.log.levels.INFO)
    return false
  end
end

return M
