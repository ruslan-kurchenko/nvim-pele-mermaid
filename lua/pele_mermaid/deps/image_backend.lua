local M = {}

local placements = {}
local api
local load_error
local checked = false
local placement_directory = ("%s/pele_mermaid/placements/%d-%s"):format(
  vim.fn.stdpath("cache"), vim.fn.getpid(), tostring(vim.uv.hrtime())
)

local function image_api()
  if checked then
    return api, load_error
  end
  checked = true
  local ok, result = pcall(require, "image")
  if not ok then
    load_error = tostring(result)
    return nil, load_error
  end
  api = result
  return api
end

local function display_path(id)
  return placement_directory .. "/" .. vim.fn.sha256(id) .. ".png"
end

local function relink(source, destination)
  local temporary = destination .. ".tmp"
  vim.uv.fs_unlink(temporary)
  local ok, error_message = vim.uv.fs_link(source, temporary)
  if not ok then ok, error_message = vim.uv.fs_copyfile(source, temporary) end
  if not ok then
    vim.uv.fs_unlink(temporary)
    return false, tostring(error_message)
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary, destination)
  if not renamed then
    vim.uv.fs_unlink(temporary)
    return false, tostring(rename_error)
  end
  -- POSIX rename is a no-op when both names already reference the same inode.
  vim.uv.fs_unlink(temporary)
  return true
end

local function detach(entry)
  if not entry or not entry.image then
    return
  end
  entry.active = false
  pcall(entry.image.clear, entry.image)
  entry.image.buffer = nil
  entry.image.window = nil
end

function M.is_available()
  return image_api() ~= nil
end

function M.get_load_error()
  image_api()
  return load_error
end

function M.render(options)
  local current_api, error_message = image_api()
  if not current_api then
    return false, "image.nvim unavailable: " .. tostring(error_message)
  end
  if not vim.api.nvim_buf_is_valid(options.buffer)
    or not vim.api.nvim_win_is_valid(options.window)
    or vim.api.nvim_win_get_buf(options.window) ~= options.buffer then
    return false, "image source window is no longer valid"
  end
  local entry = placements[options.id]
  local path = display_path(options.id)
  local readable = vim.fn.filereadable(options.path) == 1
  if not readable and not (entry and entry.path == options.path and vim.fn.filereadable(path) == 1) then
    return false, "PNG artifact is not readable: " .. options.path
  end
  vim.fn.mkdir(placement_directory, "p")

  local backup = path .. ".previous"
  if entry then
    local saved, save_error = relink(path, backup)
    if not saved then return false, "image.nvim placement backup failed: " .. save_error end
  end
  if readable then
    local linked, link_error = relink(options.path, path)
    if not linked then
      vim.uv.fs_unlink(backup)
      return false, "image.nvim placement copy failed: " .. link_error
    end
  end

  local image = entry and entry.image
  local previous = image and vim.tbl_extend("force", {}, image)
  if not image then
    local ok, result = pcall(current_api.from_file, path, {
      id = options.id,
      window = options.window,
      buffer = options.buffer,
      inline = options.inline ~= false,
      with_virtual_padding = options.with_virtual_padding ~= false,
      namespace = "pele_mermaid",
      x = options.col or 0,
      y = options.row,
      max_width_window_percentage = options.max_width_window_percentage,
      max_height_window_percentage = options.max_height_window_percentage,
    })
    if not ok or not result then
      vim.uv.fs_unlink(path)
      return false, "image.nvim load failed: " .. tostring(result)
    end
    image = result
    entry = { image = image, active = true }
    local native_render = image.render
    image.render = function(self, geometry)
      if not entry.active then return end
      if self.inline and vim.api.nvim_win_is_valid(self.window) then
        local row = geometry and geometry.y or self.geometry.y
        local height = vim.api.nvim_win_text_height(self.window, { start_row = row, end_row = row })
        if height.all == 0 then
          if self.is_rendered then self:clear(true) end
          return
        end
      end
      native_render(self, geometry)
      if self.is_rendered then require("pele_mermaid.deps.tern").place(self) end
    end
    placements[options.id] = entry
  end
  image.buffer = options.buffer
  image.window = options.window
  image.inline = options.inline ~= false
  image.with_virtual_padding = options.with_virtual_padding ~= false
  image.ignore_global_max_size = options.native_pixels == true
  image.max_width_window_percentage = options.max_width_window_percentage
  image.max_height_window_percentage = options.max_height_window_percentage
  if readable then image.last_modified = nil end
  local ok, render_error = pcall(image.render, image, {
    x = options.col or 0,
    y = options.row,
  })
  if not ok then
    if previous then
      vim.uv.fs_rename(backup, path)
      for key in pairs(image) do if previous[key] == nil then image[key] = nil end end
      for key, value in pairs(previous) do image[key] = value end
      image.last_modified = nil
      pcall(image.render, image, previous.geometry)
    else
      M.clear(options.id)
    end
    vim.uv.fs_unlink(backup)
    return false, "image.nvim render failed: " .. tostring(render_error)
  end
  entry.path = options.path
  entry.buffer = options.buffer
  entry.window = options.window
  vim.uv.fs_unlink(backup)
  return true
end

function M.clear(id)
  local entry = placements[id]
  if not entry then
    return
  end
  detach(entry)
  vim.uv.fs_unlink(display_path(id))
  placements[id] = nil
  if next(placements) == nil then vim.uv.fs_rmdir(placement_directory) end
end

function M.clear_buffer(bufnr)
  local ids = {}
  for id, entry in pairs(placements) do
    if entry.buffer == bufnr then
      ids[#ids + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    M.clear(id)
  end
end

function M.clear_window(winid)
  local ids = {}
  for id, entry in pairs(placements) do
    if entry.window == winid then
      ids[#ids + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    M.clear(id)
  end
end

function M.stop()
  local ids = {}
  for id in pairs(placements) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do M.clear(id) end
  vim.uv.fs_rmdir(placement_directory)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  desc = "Remove this Neovim session's Mermaid image placements",
  callback = function() M.stop() end,
})

function M._placements()
  return placements
end

return M
