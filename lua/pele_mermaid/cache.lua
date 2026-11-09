local M = {}
local Cache = {}
Cache.__index = Cache
local lease_root = vim.fn.stdpath("cache") .. "/pele_mermaid/leases"
vim.fn.mkdir(lease_root, "p", 448)

-- Reclaim only our dead-process leases; never touch a live editor's files.
local scan = vim.uv.fs_scandir(lease_root)
if scan then
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    local pid = kind == "directory" and tonumber(name:match("^(%d+)%-"))
    if pid then
      local _, _, code = vim.uv.kill(pid, 0)
      if code == "ESRCH" then
        local directory = lease_root .. "/" .. name
        local files = vim.uv.fs_scandir(directory)
        if files then
          while true do
            local file, file_kind = vim.uv.fs_scandir_next(files)
            if not file then break end
            if file_kind == "file" and file:match("^artifact%.") then vim.uv.fs_unlink(directory .. "/" .. file) end
          end
        end
        vim.uv.fs_rmdir(directory)
      end
    end
  end
end

local function stable_encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  end
  if kind == "boolean" or kind == "number" then
    return tostring(value)
  end
  if kind == "string" then
    return vim.json.encode(value)
  end
  if kind ~= "table" then
    error("pele_mermaid cache cannot encode " .. kind)
  end

  if vim.islist(value) then
    local encoded = {}
    for index, item in ipairs(value) do
      encoded[index] = stable_encode(item)
    end
    return "[" .. table.concat(encoded, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local encoded = {}
  for index, key in ipairs(keys) do
    encoded[index] = vim.json.encode(key) .. ":" .. stable_encode(value[key])
  end
  return "{" .. table.concat(encoded, ",") .. "}"
end

local function cache_directory()
  return vim.fn.stdpath("cache") .. "/pele_mermaid"
end

local function temporary_path(path)
  return ("%s.tmp-%d-%d"):format(path, vim.uv.os_getpid(), vim.uv.hrtime())
end

-- Private paths are outside the shared, prunable cache. The caller owns them
-- until release; a hard link preserves the inode even if another editor evicts it.
local function stage(path, uv)
  local directory, directory_error = vim.uv.fs_mkdtemp(lease_root .. "/" .. vim.uv.os_getpid() .. "-XXXXXX")
  if not directory then return nil, tostring(directory_error) end
  local private = directory .. "/artifact." .. (path:match("%.([%w]+)$") or "data")
  local linked = uv.fs_link(path, private)
  if not linked then
    local copied, message = uv.fs_copyfile(path, private)
    if not copied then
      uv.fs_unlink(private)
      vim.uv.fs_rmdir(directory)
      return nil, tostring(message)
    end
  end
  local stat = uv.fs_stat(private)
  if not stat or stat.type ~= "file" or stat.size == 0 then
    uv.fs_unlink(private)
    vim.uv.fs_rmdir(directory)
    return nil, "empty or invalid artifact"
  end
  local released = false
  return { path = private, release = function()
    if released then return end
    released = true
    uv.fs_unlink(private)
    vim.uv.fs_rmdir(directory)
  end }
end

function M.stage(path)
  return stage(path, vim.uv)
end

function Cache:stage(path)
  return stage(path, self.uv)
end

function Cache:path(key, extension)
  return ("%s/%s.%s"):format(self.directory, key, extension)
end

function Cache:exists(path)
  local stat = self.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file" and stat.size > 0
end

-- Local pins defer local eviction only; asynchronous consumers use private stages.
function Cache:pin(path)
  self.pinned[path] = (self.pinned[path] or 0) + 1
  local released = false
  return function()
    if released then return end
    released = true
    local count = self.pinned[path] - 1
    self.pinned[path] = count > 0 and count or nil
    self:_prune_due()
  end
end
function Cache:read(path, callback)
  self.uv.fs_open(path, "r", 438, function(open_error, descriptor)
    if open_error then
      self.schedule(function() callback(false, tostring(open_error)) end)
      return
    end
    self.uv.fs_fstat(descriptor, function(stat_error, stat)
      if stat_error then
        self.uv.fs_close(descriptor)
        self.schedule(function() callback(false, tostring(stat_error)) end)
        return
      end
      self.uv.fs_read(descriptor, stat.size, 0, function(read_error, content)
        self.uv.fs_close(descriptor, function(close_error)
          self.schedule(function()
            if read_error or close_error then
              callback(false, tostring(read_error or close_error))
            else
              callback(true, content)
            end
          end)
        end)
      end)
    end)
  end)
end


function Cache:_start_pruning()
  if self.stopped or self.prune_timer then return end
  self.prune_timer = self.new_timer()
  self.prune_timer:start(60000, 60000, function()
    self.schedule(function()
      if self.prune_timer then
        self.last_prune = os.time()
        self:prune(self.last_prune)
      end
    end)
  end)
  if self.prune_timer.unref then self.prune_timer:unref() end
end

function Cache:_prune_due()
  if self.stopped then self:prune(); return end
  self:_start_pruning()
  local now = os.time()
  if now - self.last_prune >= 60 then
    self.last_prune = now
    self:prune(now)
  end
end

function Cache:stop()
  self.stopped = true
  if self.prune_timer then
    self.prune_timer:stop()
    self.prune_timer:close()
    self.prune_timer = nil
  end
  self:prune()
end

function Cache:_finish_write(path, stable, callback)
  self.schedule(function()
    local ok, message = pcall(callback, true, path, stable.path)
    stable.release()
    self:_prune_due()
    if not ok then error(message) end
  end)
end

function Cache:atomic_write(path, content, callback)
  local temporary = self:temporary_path(path)
  self.uv.fs_open(temporary, "w", 384, function(open_error, descriptor)
    if open_error then
      self.active_temporary[temporary] = nil
      self.schedule(function() callback(false, tostring(open_error)) end)
      return
    end

    local offset = 0
    local function close_with_error(message)
      self.uv.fs_close(descriptor, function()
        self.uv.fs_unlink(temporary)
        self.active_temporary[temporary] = nil
        self.schedule(function() callback(false, tostring(message)) end)
      end)
    end

    local function write_remaining()
      if offset >= #content then
        self.uv.fs_close(descriptor, function(close_error)
          if close_error then
            self.uv.fs_unlink(temporary)
            self.active_temporary[temporary] = nil
            self.schedule(function() callback(false, tostring(close_error)) end)
            return
          end
          self:commit_temporary(temporary, path, callback)
        end)
        return
      end

      self.uv.fs_write(descriptor, content:sub(offset + 1), offset, function(write_error, written)
        if write_error or not written or written <= 0 then
          close_with_error(write_error or "zero-byte cache write")
          return
        end
        offset = offset + written
        write_remaining()
      end)
    end

    write_remaining()
  end)
end

function Cache:commit_temporary(temporary, path, callback)
  local stable, stage_error = self:stage(temporary)
  if not stable then
    self:discard_temporary(temporary)
    self.schedule(function() callback(false, stage_error) end)
    return
  end
  -- Publication must be an atomic rename on the cache filesystem, even when
  -- the private input lives on a different filesystem.
  local publishing = temporary_path(path)
  self.active_temporary[publishing] = true
  local function failed(message)
    self.active_temporary[publishing] = nil
    self.uv.fs_unlink(publishing)
    self:discard_temporary(temporary)
    stable.release()
    self.schedule(function() callback(false, tostring(message)) end)
  end
  local function publish(copy_error)
    if copy_error then failed(copy_error); return end
    self.uv.fs_rename(publishing, path, function(rename_error)
      if rename_error then failed(rename_error); return end
      self.active_temporary[publishing] = nil
      self:discard_temporary(temporary)
      self:_finish_write(path, stable, callback)
    end)
  end
  self.uv.fs_link(temporary, publishing, function(link_error)
    if link_error then self.uv.fs_copyfile(temporary, publishing, publish) else publish() end
  end)
end

function Cache:temporary_path(path)
  local temporary = vim.fn.tempname() .. "." .. (path:match("%.([%w]+)$") or "artifact")
  self.active_temporary[temporary] = true
  return temporary
end
function Cache:discard_temporary(temporary)
  self.active_temporary[temporary] = nil
  self.uv.fs_unlink(temporary)
end


function Cache:prune(now)
  now = now or os.time()
  local maximum_age = self.options.max_age_days * 86400
  local files = {}
  local total_bytes = 0

  local ok, iterator = pcall(vim.fs.dir, self.directory)
  if not ok or not iterator then
    return 0
  end

  local removed = 0
  for name, kind in iterator do
    if kind == "file" then
      local path = self.directory .. "/" .. name
      local stat = self.uv.fs_stat(path)
      if name:find(".tmp-", 1, true) then
        local modified = stat and stat.mtime and stat.mtime.sec or now
        if not self.active_temporary[path] and now - modified > 3600 and self.uv.fs_unlink(path) then
          removed = removed + 1
        end
      elseif stat and not self.pinned[path] then
        local modified = stat.mtime and stat.mtime.sec or now
        if now - modified > maximum_age then
          if self.uv.fs_unlink(path) then
            removed = removed + 1
          end
        else
          files[#files + 1] = { path = path, size = stat.size or 0, modified = modified }
          total_bytes = total_bytes + (stat.size or 0)
        end
      end
    end
  end

  table.sort(files, function(left, right)
    if left.modified == right.modified then
      return left.path < right.path
    end
    return left.modified < right.modified
  end)
  local index = 1
  while total_bytes > self.options.max_bytes and files[index] do
    if self.uv.fs_unlink(files[index].path) then
      total_bytes = total_bytes - files[index].size
      removed = removed + 1
    end
    index = index + 1
  end
  return removed
end

function M.new(options, dependencies)
  options = options or {}
  dependencies = dependencies or {}
  local directory = dependencies.directory or cache_directory()
  vim.fn.mkdir(directory, "p")
  local instance = setmetatable({
    directory = directory,
    options = {
      max_bytes = options.max_bytes or 104857600,
      max_age_days = options.max_age_days or 7,
    },
    uv = dependencies.uv or vim.uv,
    schedule = dependencies.schedule or vim.schedule,
    new_timer = dependencies.new_timer or vim.uv.new_timer,
    active_temporary = {},
    pinned = {},
    last_prune = 0,
  }, Cache)
  instance:prune()
  instance.last_prune = os.time()
  instance:_start_pruning()
  return instance
end

function M.key(value)
  return vim.fn.sha256(stable_encode(value))
end

function M.stable_encode(value)
  return stable_encode(value)
end

return M
