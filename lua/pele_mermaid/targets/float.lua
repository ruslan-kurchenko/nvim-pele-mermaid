local surface_module = require("pele_mermaid.targets.surface")

local M = {}
local Float = {}
Float.__index = Float

local function size(value, total)
  if value <= 1 then return math.max(1, math.floor(total * value)) end
  return math.min(total, value)
end

function Float:_dimensions()
  local width = size(self.config.float.max_width, vim.o.columns)
  local height = size(self.config.float.max_height, vim.o.lines - 2)
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

function Float:_resize(session)
  if not session:is_open() then return end
  local dimensions = self:_dimensions()
  vim.api.nvim_win_set_config(session.preview_win, {
    relative = "editor",
    row = dimensions.row,
    col = dimensions.col,
    width = dimensions.width,
    height = dimensions.height,
  })
end

function Float:_debounce(session)
  if session.timer and not session.timer:is_closing() then
    session.timer:stop()
    session.timer:close()
  end
  local timer = vim.uv.new_timer()
  session.timer = timer
  timer:start(self.config.debounce_ms, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(function()
      if session.timer ~= timer or session.closed then return end
      session.timer = nil
      session:refresh()
    end)
  end)
end

function Float:_open(source_win)
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  if self.runtime.projection and self.runtime.projection:is_projection(source_buf) then
    source_buf = self.runtime.projection:source_buffer(source_buf) or source_buf
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "mermaid-preview"
  local dimensions = self:_dimensions()
  local preview_win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = dimensions.row,
    col = dimensions.col,
    width = dimensions.width,
    height = dimensions.height,
    style = "minimal",
    border = "rounded",
    title = " Mermaid Preview ",
    title_pos = "center",
  })

  local session
  session = surface_module.new({
    runtime = self.runtime,
    view = self.view,
    source_win = source_win,
    source_buf = source_buf,
    preview_win = preview_win,
    preview_buf = buffer,
    image_id = "pele-mermaid-float:" .. source_win,
    resize_window = function(current) self:_resize(current) end,
    on_close = function()
      if session.timer and not session.timer:is_closing() then session.timer:stop(); session.timer:close() end
      if session.group then pcall(vim.api.nvim_del_augroup_by_id, session.group) end
      self.sessions[source_win] = nil
    end,
  })
  self.sessions[source_win] = session

  vim.keymap.set("n", "q", function() session:close() end, { buffer = buffer, silent = true })
  vim.keymap.set("n", "<Esc>", function() session:close() end, { buffer = buffer, silent = true })
  session.group = vim.api.nvim_create_augroup("PeleMermaidFloat" .. source_win, { clear = true })
  session:subscribe(session.group, function() self:_debounce(session) end)
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = session.group,
    callback = function() session:resize() end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = session.group,
    callback = function(event)
      local closed = tonumber(event.match)
      if closed == source_win or closed == session.preview_win then vim.schedule(function() session:close() end) end
    end,
  })
  vim.api.nvim_set_current_win(source_win)
  session:refresh()
  return session
end

function Float:toggle()
  local source_win = vim.api.nvim_get_current_win()
  local session = self.sessions[source_win]
  if session and session:is_open() then
    session:close()
    return false
  end
  self:_open(source_win)
  return true
end

function Float:close_all()
  local sessions = {}
  for _, session in pairs(self.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do session:close() end
end

function Float:is_open(source_win)
  local session = self.sessions[source_win or vim.api.nvim_get_current_win()]
  return session and session:is_open() or false
end

function M.new(runtime, view, config)
  return setmetatable({ runtime = runtime, view = view, config = config, sessions = {} }, Float)
end

return M
