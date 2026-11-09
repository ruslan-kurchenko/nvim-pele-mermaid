local surface_module = require("pele_mermaid.targets.surface")

local M = {}
local Split = {}
Split.__index = Split

function Split:_width()
  local total = vim.o.columns
  local configured = self.config.split.width
  if configured <= 1 then return math.max(1, math.floor(total * configured)) end
  return math.min(total - 1, configured)
end

function Split:_resize(session)
  if session:is_open() then vim.api.nvim_win_set_width(session.preview_win, self:_width()) end
end

function Split:_debounce(session)
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

function Split:_open(tabpage)
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  if self.runtime.projection and self.runtime.projection:is_projection(source_buf) then
    source_buf = self.runtime.projection:source_buffer(source_buf) or source_buf
  end
  local command = self.config.split.position == "left" and "topleft vsplit" or "botright vsplit"
  vim.cmd(command)
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(preview_win, preview_buf)
  vim.api.nvim_win_set_width(preview_win, self:_width())
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].filetype = "mermaid-preview"
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].swapfile = false

  local session
  session = surface_module.new({
    runtime = self.runtime,
    view = self.view,
    source_win = source_win,
    source_buf = source_buf,
    preview_win = preview_win,
    preview_buf = preview_buf,
    image_id = "pele-mermaid-split:" .. tabpage,
    resize_window = function(current) self:_resize(current) end,
    on_close = function()
      if session.timer and not session.timer:is_closing() then session.timer:stop(); session.timer:close() end
      if session.group then pcall(vim.api.nvim_del_augroup_by_id, session.group) end
      self.sessions[tabpage] = nil
    end,
  })
  self.sessions[tabpage] = session

  vim.keymap.set("n", "q", function() session:close() end, { buffer = preview_buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() session:close() end, { buffer = preview_buf, silent = true })
  session.group = vim.api.nvim_create_augroup("PeleMermaidSplit" .. tabpage, { clear = true })
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

function Split:toggle()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = self.sessions[tabpage]
  if session and session:is_open() then
    session:close()
    return false
  end
  self:_open(tabpage)
  return true
end

function Split:close_all()
  local sessions = {}
  for _, session in pairs(self.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do session:close() end
end

function Split:is_open(tabpage)
  local session = self.sessions[tabpage or vim.api.nvim_get_current_tabpage()]
  return session and session:is_open() or false
end

function M.new(runtime, view, config)
  return setmetatable({ runtime = runtime, view = view, config = config, sessions = {} }, Split)
end

return M
