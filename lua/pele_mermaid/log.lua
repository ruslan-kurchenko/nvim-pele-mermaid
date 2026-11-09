local M = {}

local path = vim.fn.stdpath("state") .. "/pele-mermaid.log"

local function encode_fields(fields)
  if not fields then return "" end
  local keys = {}
  for key in pairs(fields) do keys[#keys + 1] = key end
  table.sort(keys)
  local values = {}
  for index, key in ipairs(keys) do values[index] = key .. "=" .. tostring(fields[key]) end
  return " " .. table.concat(values, " ")
end

function M.write(event, fields)
  if vim.g.pele_mermaid_debug ~= true then return end
  local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. event .. encode_fields(fields)
  local function append()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ line }, path, "a")
  end
  if vim.in_fast_event() then
    vim.schedule(append)
  else
    append()
  end
end

function M.now()
  return vim.uv.hrtime()
end

function M.duration_ms(started)
  return math.floor((vim.uv.hrtime() - started) / 100000) / 10
end

function M.path()
  return path
end

return M
