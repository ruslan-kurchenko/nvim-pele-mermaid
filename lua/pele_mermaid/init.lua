local artifact_module = require("pele_mermaid.artifact")
local commands = require("pele_mermaid.commands")
local config_module = require("pele_mermaid.config")
local parser = require("pele_mermaid.parser")
local runtime_module = require("pele_mermaid.runtime")
local targets_module = require("pele_mermaid.targets")
local view_module = require("pele_mermaid.targets.in_buffer")

local M = {}
local state = {
  config = config_module.defaults(),
  runtime = nil,
  targets = nil,
  leave_group = nil,
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "MermaidPreview", { default = true, link = "Normal" })
end

local function require_runtime()
  return assert(state.runtime, "pele_mermaid.setup() must be called first")
end

function M.get_config()
  return vim.deepcopy(state.config)
end

function M.toggle()
  require("pele_mermaid.navigation").restore_view()
  return require_runtime():toggle()
end

function M.refresh()
  require_runtime():refresh()
end

function M.preview_toggle()
  return assert(state.targets, "pele_mermaid.setup() must be called first").float:toggle()
end

function M.inspect_toggle()
  return assert(state.targets, "pele_mermaid.setup() must be called first").inspect:toggle()
end

function M.split_toggle()
  return assert(state.targets, "pele_mermaid.setup() must be called first").split:toggle()
end

function M.export_current(path, bang)
  assert(state.targets, "pele_mermaid.setup() must be called first").export:current(path, bang)
end

function M.export_all(path, bang)
  assert(state.targets, "pele_mermaid.setup() must be called first").export:all(path, bang)
end

function M.next()
  local runtime = require_runtime()
  return require("pele_mermaid.navigation").next(nil, nil, {
    parser = parser,
    projection = runtime.projection,
  })
end

function M.prev()
  local runtime = require_runtime()
  return require("pele_mermaid.navigation").prev(nil, nil, {
    parser = parser,
    projection = runtime.projection,
  })
end

function M.list()
  local runtime = require_runtime()
  return require("pele_mermaid.navigation").list(nil, nil, {
    parser = parser,
    projection = runtime.projection,
  })
end

function M.yank()
  local runtime = require_runtime()
  state.yank = state.yank or require("pele_mermaid.yank").new({ runtime = runtime })
  return state.yank:current()
end

function M.fix()
  local runtime = require_runtime()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local block = runtime:current_block(bufnr, winid)
  if not block then
    vim.notify("pele_mermaid: no Mermaid block under cursor", vim.log.levels.WARN)
    return
  end
  local target_bufnr = block.bufnr or bufnr
  if runtime.projection and runtime.projection:is_projection(target_bufnr) then
    target_bufnr = runtime.projection:source_buffer(target_bufnr) or target_bufnr
  end
  if require("pele_mermaid.linter").fix_block(target_bufnr, block) then
    local projected = runtime.projection:projection_buffer(target_bufnr)
    local window = runtime.projection:active_window(target_bufnr)
    if projected and window then runtime.projection:enter(target_bufnr, window) end
    runtime:refresh(target_bufnr)
  end
end
function M.stop()
  require("pele_mermaid.navigation").restore_view()
  if state.targets then
    state.targets.float:close_all()
    state.targets.split:close_all()
    if state.targets.inspect then state.targets.inspect:close() end
    state.targets = nil
  end
  if state.yank then
    if state.yank.stop then state.yank:stop() end
    state.yank = nil
  end
  if state.runtime then
    state.runtime:stop()
    state.runtime = nil
  end
  require("pele_mermaid.deps.image_backend").stop()
  if state.leave_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.leave_group)
    state.leave_group = nil
  end
end

function M.setup(options)
  local normalized = config_module.normalize(options or {})
  M.stop()
  state.config = normalized
  setup_highlights()

  local artifact = artifact_module.new(normalized)
  local view = view_module.new(normalized)
  local runtime = runtime_module.new(normalized, { artifact = artifact, view = view })
  state.runtime = runtime
  state.targets = targets_module.new(runtime, view, parser, normalized)
  commands.setup(M)
  runtime:start()

  state.leave_group = vim.api.nvim_create_augroup("PeleMermaidLeave", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.leave_group,
    once = true,
    callback = M.stop,
  })

end

function M._runtime()
  return state.runtime
end

function M._targets()
  return state.targets
end

return M
