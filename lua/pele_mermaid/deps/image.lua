-- Inspector viewport cropping keeps zoomed pixels native instead of asking
-- image.nvim to fit an oversized image back into the terminal's cell grid.
local M = {}

function M.cell_size()
  local ok, term = pcall(require, "image/utils/term")
  local size = ok and term.get_size() or nil
  return size and size.cell_width or 8, size and size.cell_height or 16
end

local function dimensions(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, nil, err end
  local header = file:read(24)
  file:close()
  if not header or #header < 24 or header:sub(1, 8) ~= "\137PNG\r\n\26\n" or header:sub(13, 16) ~= "IHDR" then
    return nil, nil, "invalid PNG header"
  end
  local function integer(offset)
    local a, b, c, d = header:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return integer(17), integer(21)
end

function M.viewport(options, callback)
  local width, height, err = dimensions(options.path)
  if not width or width < 1 or height < 1 then
    callback({ ok = false, error = err or "invalid PNG dimensions" })
    return { cancel = function() end }
  end
  local crop_width = math.max(1, math.min(width, math.floor(options.width)))
  local crop_height = math.max(1, math.min(height, math.floor(options.height)))
  local x = math.max(0, math.min(width - crop_width, math.floor(options.x or 0)))
  local y = math.max(0, math.min(height - crop_height, math.floor(options.y or 0)))
  if crop_width == width and crop_height == height then
    callback({ ok = true, path = options.path, temporary = false, x = x, y = y })
    return { cancel = function() end }
  end
  local path = vim.fn.tempname() .. ".png"
  local cancelled = false
  local ok, process = pcall(vim.system, {
    "magick", options.path, "-crop", ("%dx%d+%d+%d"):format(crop_width, crop_height, x, y), "+repage", path,
  }, { text = true }, function(result)
    vim.schedule(function()
      if cancelled or result.code ~= 0 then
        vim.uv.fs_unlink(path)
        if not cancelled then
          local message = result.stderr
          if not message or message == "" then message = "viewport crop failed (exit " .. tostring(result.code) .. ")" end
          callback({ ok = false, error = message })
        end
        return
      end
      callback({ ok = true, path = path, temporary = true, x = x, y = y })
    end)
  end)
  if not ok then
    vim.uv.fs_unlink(path)
    callback({ ok = false, error = tostring(process) })
  end
  return { cancel = function()
    cancelled = true
    if ok and process then pcall(process.kill, process, 15) end
    vim.uv.fs_unlink(path)
  end }
end

return M
