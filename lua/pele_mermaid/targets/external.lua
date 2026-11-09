local M = {}
local Export = {}
Export.__index = Export

local function extension(path)
  return vim.fn.fnamemodify(path, ":e"):lower()
end

local function default_current_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = name ~= "" and vim.fn.fnamemodify(name, ":r") or (vim.fn.getcwd() .. "/mermaid")
  return root .. "-mermaid.svg"
end

local function atomic_copy(source, destination, overwrite, callback)
  local directory = vim.fn.fnamemodify(destination, ":h")
  if vim.fn.isdirectory(directory) == 0 and vim.fn.mkdir(directory, "p") == 0 then
    callback(false, "cannot create export directory: " .. directory)
    return
  end
  local temporary = ("%s.tmp-%d-%d"):format(destination, vim.fn.getpid(), vim.uv.hrtime())
  vim.uv.fs_copyfile(source, temporary, function(copy_error)
    if copy_error then
      vim.uv.fs_unlink(temporary)
      vim.schedule(function() callback(false, tostring(copy_error)) end)
      return
    end

    local function finish(commit_error)
      if commit_error or not overwrite then vim.uv.fs_unlink(temporary) end
      vim.schedule(function()
        callback(commit_error == nil, commit_error and tostring(commit_error) or destination)
      end)
    end
    if overwrite then
      vim.uv.fs_rename(temporary, destination, finish)
    else
      vim.uv.fs_link(temporary, destination, finish)
    end
  end)
end

function Export:current(path, bang)
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local block = self.runtime:current_block(bufnr, winid)
  if self.runtime.projection and self.runtime.projection:is_projection(bufnr) then
    bufnr = self.runtime.projection:source_buffer(bufnr) or bufnr
  end
  if not block or not block.complete then
    vim.notify("pele_mermaid: current Mermaid block is incomplete or missing", vim.log.levels.ERROR)
    return
  end

  path = vim.fn.fnamemodify(path or default_current_path(bufnr), ":p")
  local suffix = extension(path)
  if suffix ~= "svg" and suffix ~= "png" then
    vim.notify("pele_mermaid: export path must end in .svg or .png", vim.log.levels.ERROR)
    return
  end
  if not bang and vim.uv.fs_lstat(path) then
    vim.notify("pele_mermaid: destination exists; use :MermaidExport! to overwrite", vim.log.levels.ERROR)
    return
  end

  local options = { output = "svg", want_png = suffix == "png" }
  if options.want_png then options.width_px = self.view:width_px(winid, 1) end
  self.runtime:request(block, options, function(result)
    if not result.ok then
      vim.notify("pele_mermaid: export failed: " .. result.error, vim.log.levels.ERROR)
      return
    end
    atomic_copy(options.want_png and result.png_path or result.svg_path, path, bang, function(ok, value)
      if result.release then result.release() end
      vim.notify(ok and ("pele_mermaid: exported " .. value) or ("pele_mermaid: export failed: " .. value), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end)
end

function Export:all(directory, bang)
  local bufnr = vim.api.nvim_get_current_buf()
  if self.runtime.projection and self.runtime.projection:is_projection(bufnr) then
    bufnr = self.runtime.projection:source_buffer(bufnr) or bufnr
  end
  local blocks = self.parser.index(bufnr)
  if #blocks == 0 then
    vim.notify("pele_mermaid: no Mermaid blocks in buffer", vim.log.levels.ERROR)
    return
  end
  for _, block in ipairs(blocks) do
    if not block.complete then
      vim.notify("pele_mermaid: cannot export an incomplete Mermaid block", vim.log.levels.ERROR)
      return
    end
  end

  local source_name = vim.api.nvim_buf_get_name(bufnr)
  local source_directory = source_name ~= "" and vim.fn.fnamemodify(source_name, ":h") or vim.fn.getcwd()
  local stem = source_name ~= "" and vim.fn.fnamemodify(source_name, ":t:r") or "mermaid"
  directory = vim.fn.fnamemodify(directory or source_directory, ":p")
  if vim.fn.isdirectory(directory) == 0 and vim.fn.mkdir(directory, "p") == 0 then
    vim.notify("pele_mermaid: cannot create export directory", vim.log.levels.ERROR)
    return
  end

  local destinations = {}
  for index = 1, #blocks do
    local path = ("%s/%s-mermaid-%d.svg"):format(directory, stem, index)
    if not bang and vim.uv.fs_lstat(path) then
      vim.notify("pele_mermaid: destination exists; use :MermaidExportAll! to overwrite", vim.log.levels.ERROR)
      return
    end
    destinations[index] = path
  end

  local results = {}
  local remaining = #blocks
  local failed = false
  for index, block in ipairs(blocks) do
    self.runtime:request(block, { output = "svg" }, function(result)
      if failed then
        if result.release then result.release() end
        return
      end
      if not result.ok then
        failed = true
        for _, artifact in pairs(results) do
          if artifact.release then artifact.release() end
        end
        vim.notify("pele_mermaid: export failed: " .. result.error, vim.log.levels.ERROR)
        return
      end
      results[index] = result
      remaining = remaining - 1
      if remaining ~= 0 then return end

      local copies_left = #results
      local copy_failed = false
      for result_index, artifact in ipairs(results) do
        atomic_copy(artifact.svg_path, destinations[result_index], bang, function(ok, message)
          if artifact.release then artifact.release() end
          if copy_failed then return end
          if not ok then
            copy_failed = true
            vim.notify("pele_mermaid: export failed: " .. message, vim.log.levels.ERROR)
            return
          end
          copies_left = copies_left - 1
          if copies_left == 0 then
            vim.notify(("pele_mermaid: exported %d diagrams to %s"):format(#results, directory), vim.log.levels.INFO)
          end
        end)
      end
    end)
  end
end

function M.new(runtime, view, parser)
  return setmetatable({ runtime = runtime, view = view, parser = parser }, Export)
end

return M
