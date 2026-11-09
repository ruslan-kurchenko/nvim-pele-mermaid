---@class PeleMermaidTimer
---@field start fun(self: PeleMermaidTimer, timeout: integer, repeat_interval: integer, callback: function)
---@field stop fun(self: PeleMermaidTimer)
---@field close fun(self: PeleMermaidTimer)
---@field is_closing fun(self: PeleMermaidTimer): boolean

local log = require("pele_mermaid.log")
local default_parser = require("pele_mermaid.parser")
local default_projection = require("pele_mermaid.projection")
local default_theme = require("pele_mermaid.theme")

local M = {}
local Runtime = {}
Runtime.__index = Runtime

local diagnostic_namespace = vim.api.nvim_create_namespace("pele_mermaid.diagnostics")

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function release_artifact(artifact)
  if artifact and artifact.release then artifact.release() end
end

local function release_state(state)
  for _, artifact in pairs(state.last_good) do release_artifact(artifact) end
  state.current, state.last_good = {}, {}
end

local function block_visible(session, id)
  for winid, visible in pairs(session.visible) do
    if visible[id] and vim.api.nvim_win_is_valid(winid) then return true end
  end
  return false
end

local function release_offscreen(session)
  for id, state in pairs(session.blocks) do
    -- An unfinished fence consumes the rest of the document: retain its one
    -- last-valid preview while the source buffer remains loaded for editing.
    if state.block.complete and not block_visible(session, id) then release_state(state) end
  end
end

local function contains(list, expected)
  for _, value in ipairs(list) do
    if value == expected then
      return true
    end
  end
  return false
end

local function windows_for_buffer(bufnr)
  local windows = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      windows[#windows + 1] = winid
    end
  end
  return windows
end

function Runtime:_enabled(bufnr)
  return self.config.enabled and contains(self.config.filetypes, vim.bo[bufnr].filetype)
end

function Runtime:_session(bufnr)
  local session = self.sessions[bufnr]
  if not session then
    session = { blocks = {}, visible = {}, timer = nil, mode = "edit", prefetch_queue = nil }
    self.sessions[bufnr] = session
  end
  return session
end

function Runtime:_theme(bufnr)
  if not self.resolved_theme then
    self.resolved_theme = self.theme.resolve(self.config, bufnr)
  end
  return self.resolved_theme
end

function Runtime:_cancel_pending(state)
  for key, pending in pairs(state.pending) do
    if pending.subscription then
      pending.subscription.cancel()
    end
    state.pending[key] = nil
  end
end

function Runtime:_publish_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local diagnostics = {}
  local session = self.sessions[bufnr]
  if session then
    for _, state in pairs(session.blocks) do
      if state.error then
        diagnostics[#diagnostics + 1] = {
          lnum = state.start_row,
          col = 0,
          severity = vim.diagnostic.severity.ERROR,
          source = "pele_mermaid",
          message = "Mermaid preview stale: " .. state.error,
        }
      end
    end
  end
  vim.diagnostic.set(diagnostic_namespace, bufnr, diagnostics, {})
end

function Runtime:_sync_states(bufnr, blocks, theme, force)
  local session = self:_session(bufnr)
  local retained = {}
  for _, block in ipairs(blocks) do
    retained[block.id] = true
    local state = session.blocks[block.id]
    if not state then
      state = {
        generation = 0,
        pending = {},
        current = {},
        last_good = {},
        failed = {},
      }
      session.blocks[block.id] = state
    end

    local signature = block.source_hash .. ":" .. tostring(block.complete) .. ":" .. theme.signature
    if force or state.signature ~= signature then
      self:_cancel_pending(state)
      state.generation = state.generation + 1
      state.signature = signature
      state.source_hash = block.source_hash
      state.theme_signature = theme.signature
      state.theme = theme
      state.current = {}
      state.failed = {}
      state.error = nil
    end
    state.block = block
    state.start_row = block.start_row
    if not block.complete then
      state.error = "incomplete Mermaid fence"
    end
  end

  for id, state in pairs(session.blocks) do
    if not retained[id] then
      self:_cancel_pending(state)
      release_state(state)
      for winid in pairs(session.visible) do
        self.view:clear_block(bufnr, winid, id)
      end
      session.blocks[id] = nil
    end
  end
  return session
end

function Runtime:_show(display_bufnr, state, display_block, winid, target, artifact, active)
  local ok, message = self.view:update(display_bufnr, winid, display_block, artifact, {
    active = active,
    error = state.error,
  })
  if ok == false then
    state.failed[target] = state.signature
    state.error = message or "Image display failed; check :checkhealth pele_mermaid, then :MermaidRefresh"
    local source_bufnr = self.projection:source_buffer(display_bufnr) or display_bufnr
    self:_publish_diagnostics(source_bufnr)
    self.view:clear_window(winid)
    if self.projection:is_projection(display_bufnr) then
      self.projection:leave(display_bufnr, winid)
    end
    vim.notify("pele_mermaid: " .. state.error, vim.log.levels.ERROR)
    return false, state.error
  end
  return true
end

function Runtime:_request_artifact(bufnr, state, block, winid, request)
  local pending = state.pending[request.target]
  if pending and pending.generation == request.generation then
    if request.done then pending.waiters[#pending.waiters + 1] = request.done end
    return
  end
  if state.failed[request.target] == request.signature and not request.bypass_cache then
    if request.done then self.schedule(request.done) end
    return
  end
  local current = state.current[request.target]
  if current and current.signature == request.signature and not request.bypass_cache then
    if request.done then self.schedule(request.done) end
    return
  end

  if pending and pending.subscription then
    pending.subscription.cancel()
  end
  local marker = { generation = request.generation, subscription = nil, waiters = {} }
  if request.done then marker.waiters[1] = request.done end
  state.pending[request.target] = marker
  local subscription = self.artifact:resolve({
    source = block.source,
    source_hash = block.source_hash,
    theme_signature = request.theme.signature,
    theme = request.theme.name,
    options = request.theme.options,
    width_px = request.width_px,
    want_png = request.want_png,
    output = request.output,
    bypass_cache = request.bypass_cache,
  }, function(result)
    if state.pending[request.target] == marker then
      state.pending[request.target] = nil
    end
    for _, done in ipairs(marker.waiters) do self.schedule(done) end
    local session = self.sessions[bufnr]
    if
      not vim.api.nvim_buf_is_valid(bufnr)
      or not session or session.blocks[block.id] ~= state
      or not self.parser.position(bufnr, block.id)
      or state.generation ~= request.generation
      or state.signature ~= request.signature
    then
      log.write("generation_drop", { block_id = block.id, bufnr = bufnr, generation = request.generation })
      release_artifact(result)
      return
    end

    if not result.ok then
      state.failed[request.target] = request.signature
      state.error = result.error
      self:_publish_diagnostics(bufnr)
      self:_redraw_block(bufnr, block.id)
      return
    end

    if not block_visible(session, block.id) then
      release_artifact(result)
      return
    end
    release_artifact(state.last_good[request.target])
    state.failed[request.target] = nil
    state.error = nil
    state.current[request.target] = { signature = request.signature, artifact = result }
    state.last_good[request.target] = result
    self:_trim_artifacts(bufnr, state, request.target)
    self:_publish_diagnostics(bufnr)
    self:_redraw_block(bufnr, block.id)
  end)
  if state.pending[request.target] == marker then
    marker.subscription = subscription
  else
    subscription.cancel()
  end
end

function Runtime:_target_for_window(winid)
  if self.view:graphics_available() then
    local width = self.view:width_px(winid, self.config.inline.max_width)
    return {
      target = "png:" .. width,
      output = "svg",
      width_px = width,
      want_png = true,
    }
  end
  return nil
end

function Runtime:_trim_artifacts(bufnr, state, newest)
  local retained = { [newest] = true }
  local projected = self.projection:projection_buffer(bufnr)
  if projected then
    for _, winid in ipairs(windows_for_buffer(projected)) do
      local target = self:_target_for_window(winid)
      if target then retained[target.target] = true end
    end
  end
  for target, artifact in pairs(state.last_good) do
    if not retained[target] and not state.pending[target] then
      release_artifact(artifact)
      state.last_good[target], state.current[target] = nil, nil
    end
  end
end

function Runtime:_apply_display_block(source_bufnr, display_bufnr, state, display_block, winid, theme, bypass_cache)
  local target = self:_target_for_window(winid)
  if not target then return end

  local last_good = state.last_good[target.target]
  if not last_good then
    for key, artifact in pairs(state.last_good) do
      if key:sub(1, 4) == "png:" then
        last_good = artifact
        break
      end
    end
  end

  if last_good then
    self:_show(display_bufnr, state, display_block, winid, target.target, last_good, false)
  end

  if not state.block.complete then
    return
  end
  target.generation = state.generation
  target.signature = state.signature
  target.theme = theme
  target.bypass_cache = bypass_cache
  self:_request_artifact(source_bufnr, state, state.block, winid, target)
end

function Runtime:_redraw_block(source_bufnr, block_id)
  local session = self.sessions[source_bufnr]
  local state = session and session.blocks[block_id]
  if not state then
    return
  end

  local projected_bufnr = self.projection:projection_buffer(source_bufnr)
  local display_bufnr = (projected_bufnr and vim.api.nvim_buf_is_valid(projected_bufnr)) and projected_bufnr or source_bufnr
  local display_block = self.projection:display_block(source_bufnr, state.block) or state.block


  for winid, visible in pairs(session.visible) do
    if visible[block_id] and vim.api.nvim_win_is_valid(winid)
      and vim.api.nvim_win_get_buf(winid) == display_bufnr then
      local target = self:_target_for_window(winid)
      local artifact = target and (state.current[target.target] and state.current[target.target].artifact
        or state.last_good[target.target])
      if artifact then
        self:_show(display_bufnr, state, display_block, winid, target.target, artifact, false)
      elseif state.error then
        self.view:update(display_bufnr, winid, display_block, nil, { error = state.error })
      end
    end
  end
end

function Runtime:_window_range(winid)
  local topline = 0
  local botline = 100000
  local ok_top, top = pcall(vim.fn.line, "w0", winid)
  local ok_bot, bot = pcall(vim.fn.line, "w$", winid)
  if ok_top and ok_bot and top and bot and top > 0 and bot > 0 then
    topline = top - 1
    botline = bot - 1
  else
    topline = 0
    botline = math.max(100000, vim.api.nvim_win_get_height(winid))
  end
  return topline, botline
end

function Runtime:_prefetch_blocks(source_bufnr, offscreen_blocks, winid, theme, bypass_cache)
  local session = self.sessions[source_bufnr]
  if not session then return end
  local queue = { blocks = offscreen_blocks or {}, index = 1 }
  session.prefetch_queue = queue
  local function step()
    if self.sessions[source_bufnr] ~= session or session.prefetch_queue ~= queue
      or not vim.api.nvim_buf_is_valid(source_bufnr)
      or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= self.projection:projection_buffer(source_bufnr) then return end
    -- Yield to all visible/in-flight work, then submit just one idle artifact.
    for _, state in pairs(session.blocks) do
      for _, pending in pairs(state.pending) do
        pending.waiters[#pending.waiters + 1] = step
        return
      end
    end
    local block = queue.blocks[queue.index]
    if not block then return end
    queue.index = queue.index + 1
    local state = session.blocks[block.id]
    if not state or not state.block.complete then self.schedule(step); return end
    local target = self:_target_for_window(winid)
    if not target then return end
    target.generation = state.generation
    target.signature = state.signature
    target.theme = theme
    target.bypass_cache = bypass_cache
    target.done = step
    self:_request_artifact(source_bufnr, state, state.block, winid, target)
  end
  self.schedule(step)
end

function Runtime:reconcile_projection(source_bufnr, projected_bufnr, winid, options)
  options = options or {}
  if not vim.api.nvim_buf_is_valid(source_bufnr) or not vim.api.nvim_buf_is_valid(projected_bufnr) then return end
  if self.projection.track_window then self.projection:track_window(source_bufnr, winid) end

  local blocks = self.parser.index(source_bufnr)
  local theme = self:_theme(source_bufnr)
  local session = self:_sync_states(source_bufnr, blocks, theme, options.force)

  local display_blocks = self.projection:display_blocks(source_bufnr)
  if #display_blocks == 0 then
    for _, block in ipairs(blocks) do
      display_blocks[#display_blocks + 1] = block
    end
  end

  local topline, botline = self:_window_range(winid)
  local visible_blocks = {}
  local offscreen_blocks = {}
  local visible_ids = {}

  for _, dblock in ipairs(display_blocks) do
    if dblock.start_row >= (topline - 2) and dblock.start_row <= (botline + 2) then
      visible_blocks[#visible_blocks + 1] = dblock
      visible_ids[dblock.id] = true
    else
      offscreen_blocks[#offscreen_blocks + 1] = dblock
    end
  end

  local previous_visible = session.visible[winid] or {}
  for prev_id in pairs(previous_visible) do
    if not visible_ids[prev_id] then
      self.view:clear_block(projected_bufnr, winid, prev_id)
    end
  end
  session.visible[winid] = visible_ids
  release_offscreen(session)

  for _, dblock in ipairs(visible_blocks) do
    local state = session.blocks[dblock.id]
    if state then
      self:_apply_display_block(source_bufnr, projected_bufnr, state, dblock, winid, theme, options.bypass_cache)
    end
  end

  self:_publish_diagnostics(source_bufnr)
  self:_prefetch_blocks(source_bufnr, offscreen_blocks, winid, theme, options.bypass_cache)
end

function Runtime:_on_win_scrolled(projected_bufnr, winid)
  local source_bufnr = self.projection:source_buffer(projected_bufnr)
  if not source_bufnr or not vim.api.nvim_buf_is_valid(source_bufnr) then return end
  local session = self.sessions[source_bufnr]
  if not session or session.mode == "edit" then return end

  local display_blocks = self.projection:display_blocks(source_bufnr)
  local topline, botline = self:_window_range(winid)
  local visible_ids = {}
  local theme = self:_theme(source_bufnr)

  for _, dblock in ipairs(display_blocks) do
    local is_vis = dblock.start_row >= (topline - 2) and dblock.start_row <= (botline + 2)
    if is_vis then
      visible_ids[dblock.id] = true
    end
  end

  local previous_visible = session.visible[winid] or {}
  for prev_id in pairs(previous_visible) do
    if not visible_ids[prev_id] then
      self.view:clear_block(projected_bufnr, winid, prev_id)
    end
  end
  session.visible[winid] = visible_ids
  release_offscreen(session)
  for _, dblock in ipairs(display_blocks) do
    if visible_ids[dblock.id] and not previous_visible[dblock.id] then
      local state = session.blocks[dblock.id]
      if state then self:_apply_display_block(source_bufnr, projected_bufnr, state, dblock, winid, theme, false) end
    end
  end
end

function Runtime:reconcile(bufnr, options)
  options = options or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  if self.projection:is_projection(bufnr) then
    local source_bufnr = self.projection:source_buffer(bufnr)
    if self.projection.refresh then self.projection:refresh(source_bufnr) end
    for _, winid in ipairs(windows_for_buffer(bufnr)) do
      self:reconcile_projection(source_bufnr, bufnr, winid, options)
      options = vim.tbl_extend("force", options, { force = false })
    end
    return
  end

  if not self:_enabled(bufnr) then
    if self.sessions[bufnr] then self:cleanup_buffer(bufnr, false) end
    return
  end

  local session = self:_session(bufnr)
  local projected_bufnr = self.projection:projection_buffer(bufnr)

  if projected_bufnr and self.projection:active_window(bufnr) then
    self:reconcile(projected_bufnr, options)
    return
  end

  -- Edit/source mode: sync states without rendering inline images
  local blocks = self.parser.index(bufnr)
  local theme = self:_theme(bufnr)
  self:_sync_states(bufnr, blocks, theme, options.force)

  local windows = windows_for_buffer(bufnr)
  for _, winid in ipairs(windows) do
    self.view:clear_window(winid)
    session.visible[winid] = {}
  end
  self:_publish_diagnostics(bufnr)
end

function Runtime:_debounce(bufnr)
  local session = self:_session(bufnr)
  close_timer(session.timer)
  ---@type PeleMermaidTimer
  local timer = self.new_timer()
  session.timer = timer
  timer:start(self.config.debounce_ms, 0, function()
    self.schedule(function()
      if session.timer ~= timer then return end
      close_timer(timer)
      session.timer = nil
      local projected_bufnr = self.projection:projection_buffer(bufnr)
      local winid = self.projection:active_window(bufnr)
      if projected_bufnr and winid then
        self.projection:enter(bufnr, winid)
      end
      self:reconcile(bufnr)
    end)
  end)
end

function Runtime:toggle(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = (winid and winid ~= 0) and winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  local source_bufnr = bufnr
  local is_proj = self.projection:is_projection(bufnr)
  if is_proj then
    source_bufnr = self.projection:source_buffer(bufnr) or bufnr
  end

  local session = self:_session(source_bufnr)
  if is_proj then
    local proj_buf = is_proj and bufnr or self.projection:projection_buffer(source_bufnr)
    if proj_buf and vim.api.nvim_buf_is_valid(proj_buf) then
      self.projection:leave(proj_buf, winid)
    end
    session.mode = self.projection:active_window(source_bufnr) and "read" or "edit"
    session.visible[winid] = nil
    session.prefetch_queue = nil
    self.view:clear_window(winid)
    release_offscreen(session)
    return "edit"
  end

  if not self:_enabled(source_bufnr) then return nil end
  if not self.config.inline.enabled or not self.view:graphics_available() then
    vim.notify("pele_mermaid: inline graphics unavailable; enable inline rendering and image.nvim in a Kitty-compatible terminal, then run :checkhealth pele_mermaid. Source retained.", vim.log.levels.ERROR)
    return "edit"
  end

  local blocks = self.parser.index(source_bufnr)
  if #blocks == 0 then
    vim.notify("pele_mermaid: no Mermaid blocks in buffer", vim.log.levels.INFO)
    return "edit"
  end

  local projected_bufnr = self.projection:enter(source_bufnr, winid, blocks)
  if not projected_bufnr then return nil end
  session.mode = "read"

  self:reconcile_projection(source_bufnr, projected_bufnr, winid)
  return "read"
end

function Runtime:refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  self:reconcile(bufnr, { force = true, bypass_cache = true })
end

function Runtime:current_block(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = winid or vim.api.nvim_get_current_win()
  if self.projection:is_projection(bufnr) then
    local source_bufnr = self.projection:source_buffer(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local row = cursor[1] - 1
    local block = self.projection:block_at(bufnr, row)
    if block then return block end
    local source_row = self.projection:projected_to_source_row(source_bufnr, row)
    return self.parser.at(source_bufnr, source_row)
  end
  return self.parser.at(bufnr, vim.api.nvim_win_get_cursor(winid)[1] - 1)
end

function Runtime:request(block, options, callback)
  options = options or {}
  if not block or not block.complete then
    callback({ ok = false, stage = "parser", error = "Mermaid block is incomplete or missing" })
    return { cancel = function() return false end }
  end
  local theme = self:_theme(block.bufnr)
  return self.artifact:resolve({
    source = block.source,
    source_hash = block.source_hash,
    theme_signature = theme.signature,
    theme = theme.name,
    options = theme.options,
    width_px = options.width_px,
    scale = options.scale,
    want_png = options.want_png,
    output = options.output or "svg",
    bypass_cache = options.bypass_cache,
  }, callback)
end

function Runtime:cleanup_window(winid)
  self.view:clear_window(winid)
  if self.projection.cleanup_window then self.projection:cleanup_window(winid) end
  for _, session in pairs(self.sessions) do
    session.visible[winid] = nil
    release_offscreen(session)
  end
end

function Runtime:cleanup_buffer(bufnr, clear_parser)
  local session = self.sessions[bufnr]
  if session then
    close_timer(session.timer)
    for _, state in pairs(session.blocks) do
      self:_cancel_pending(state)
      release_state(state)
    end
  end
  self.sessions[bufnr] = nil
  self.view:clear_buffer(bufnr)
  vim.diagnostic.reset(diagnostic_namespace, bufnr)
  if clear_parser ~= false then
    self.parser.clear(bufnr)
  end
  if self.projection:is_projection(bufnr) then
    self.projection:cleanup_projection(bufnr)
  else
    self.projection:cleanup_source(bufnr)
  end
end

function Runtime:start()
  if self.group then
    return
  end
  self.group = vim.api.nvim_create_augroup("PeleMermaidRuntime", { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = self.group,
    callback = function(event)
      if self.projection:is_projection(event.buf) then
        self:reconcile(event.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = self.group,
    callback = function(event)
      if not self.projection:is_projection(event.buf) then return end
      local winid = vim.api.nvim_get_current_win()
      self.schedule(function()
        if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= event.buf then
          self:cleanup_window(winid)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = self.group,
    callback = function(event)
      if self.projection:is_projection(event.buf) then
        self:reconcile(event.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.group,
    callback = function(event)
      if self:_enabled(event.buf) then self:_debounce(event.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = self.group,
    callback = function(event)
      local winid = tonumber(event.match)
      if winid and vim.api.nvim_win_is_valid(winid) then
        local current_buf = vim.api.nvim_win_get_buf(winid)
        if self.projection:is_projection(current_buf) then
          self:_on_win_scrolled(current_buf, winid)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = self.group,
    callback = function()
      for bufnr in pairs(self.sessions) do
        local proj = self.projection:projection_buffer(bufnr)
        if proj and vim.api.nvim_buf_is_valid(proj) then
          self:reconcile(proj)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.group,
    callback = function()
      self.resolved_theme = nil
      self.theme.invalidate()
      for bufnr in pairs(self.sessions) do
        local proj = self.projection:projection_buffer(bufnr)
        if proj and vim.api.nvim_buf_is_valid(proj) then
          self:reconcile(proj, { force = true })
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(event) self:cleanup_window(tonumber(event.match)) end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    callback = function(event) self:cleanup_buffer(event.buf) end,
  })
end

function Runtime:stop()
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  local buffers = {}
  for bufnr in pairs(self.sessions) do buffers[#buffers + 1] = bufnr end
  for _, bufnr in ipairs(buffers) do self:cleanup_buffer(bufnr) end
  self.artifact:stop("pele_mermaid runtime stopped")
end

function Runtime:_state(bufnr)
  return self.sessions[bufnr]
end

function M.new(config, dependencies)
  dependencies = dependencies or {}
  local parser = dependencies.parser or default_parser
  return setmetatable({
    config = config,
    parser = parser,
    projection = dependencies.projection or default_projection.new({ parser = parser }),
    artifact = assert(dependencies.artifact, "runtime requires an artifact pipeline"),
    view = assert(dependencies.view, "runtime requires an inline view"),
    theme = dependencies.theme or default_theme,
    new_timer = dependencies.new_timer or vim.uv.new_timer,
    schedule = dependencies.schedule or vim.schedule,
    sessions = {},
    resolved_theme = nil,
    group = nil,
  }, Runtime)
end

function M.diagnostic_namespace()
  return diagnostic_namespace
end

return M
