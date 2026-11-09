local M = {}

local workers = {}
local next_id = 0
local exiting = false
local stderr_limit = 8192
local pump

local function complete(entry, result)
  if not entry or not entry.cb then return end
  local cb = entry.cb
  entry.cb = nil
  if entry.timer then
    entry.timer:stop()
    entry.timer:close()
    entry.timer = nil
  end
  local ok, err = pcall(cb, result)
  if not ok then vim.schedule(function() error(err) end) end
end

local function disconnect(worker)
  local job = worker.job
  worker.job = nil
  worker.generation = worker.generation + 1
  worker.fragments = {}
  worker.stderr = ""
  if job and job > 0 then pcall(vim.fn.jobstop, job) end
end

local function fail_active(worker, message, cancelled)
  local entry = worker.active
  worker.active = nil
  disconnect(worker)
  complete(entry, { ok = false, error = message, cancelled = cancelled })
  -- Only the active request reached the failed process. Queued requests have
  -- never been sent, so starting them on a fresh process is not a retry.
  pump(worker)
end

local function finish(worker, result)
  local entry = worker.active
  worker.active = nil
  complete(entry, result)
  pump(worker)
end

local function receive(worker, line)
  local ok, envelope = pcall(vim.fn.json_decode, line)
  if not ok or type(envelope) ~= "table" then
    fail_active(worker, "pele_mermaid: invalid renderer response")
    return
  end
  local result = envelope.result
  if type(envelope.id) ~= "number" or not worker.active or envelope.id ~= worker.active.id then
    local message = type(result) == "table" and type(result.error) == "string" and result.error
      or "pele_mermaid: invalid renderer response"
    fail_active(worker, message)
  elseif type(result) ~= "table" then
    fail_active(worker, "pele_mermaid: invalid renderer response")
  elseif type(result.error) == "string" then
    finish(worker, { ok = false, error = result.error })
  elseif type(result.output) == "string" and result.output ~= "" then
    finish(worker, { ok = true, output = result.output })
  else
    fail_active(worker, "pele_mermaid: invalid renderer response")
  end
end

local function start(worker)
  local generation = worker.generation
  local function current() return not worker.dead and worker.generation == generation end
  local ok, job = pcall(vim.fn.jobstart, { worker.cmd, worker.script, "--server" }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not current() or not data then return end
      for index, chunk in ipairs(data) do
        if chunk ~= "" then worker.fragments[#worker.fragments + 1] = chunk end
        if index < #data then
          local line = table.concat(worker.fragments)
          worker.fragments = {}
          receive(worker, line)
          if not current() then return end
        end
      end
    end,
    on_stderr = function(_, data)
      if not current() or not data then return end
      worker.stderr = (worker.stderr .. table.concat(data, "\n")):sub(-stderr_limit)
    end,
    on_exit = function(_, code)
      if not current() then return end
      local message = worker.stderr
      if message == "" then message = ("pele_mermaid: renderer exited with code %d"):format(code) end
      fail_active(worker, message)
    end,
  })
  if not ok or job <= 0 then
    return nil, "pele_mermaid: failed to start renderer" .. (not ok and (": " .. tostring(job)) or "")
  end
  worker.job = job
  return true
end

pump = function(worker)
  if worker.dead or worker.pumping then return end
  worker.pumping = true
  while not worker.dead and not worker.active and #worker.queue > 0 do
    local entry = table.remove(worker.queue, 1)
    if entry.cb then
      worker.active = entry
      local ok, message = true
      if not worker.job then ok, message = start(worker) end
      if not ok then
        fail_active(worker, message)
      else
        -- The server is serial: queue time is not execution time. No deadline
        -- or protocol write exists until this entry owns the process.
        if entry.timeout and entry.timeout > 0 then
          entry.timer = vim.uv.new_timer()
          entry.timer:start(entry.timeout, 0, vim.schedule_wrap(function()
            if worker.active == entry then fail_active(worker, "pele_mermaid: renderer timeout") end
          end))
        end
        local sent_ok, sent = pcall(vim.fn.chansend, worker.job,
          '{"id":' .. entry.id .. ',"request":' .. entry.request .. '}\n')
        if not sent_ok or sent == 0 then fail_active(worker, "pele_mermaid: failed to send renderer request") end
      end
    end
  end
  worker.pumping = false
end

function M.request(cmd, script, request_json, timeout, cb)
  local entry = { cb = cb, request = request_json, timeout = timeout }
  if exiting then
    complete(entry, { ok = false, error = "pele_mermaid: renderer shutting down" })
    return function() return false end
  end
  local key = cmd .. "\0" .. script
  local worker = workers[key]
  if not worker then
    worker = { key = key, cmd = cmd, script = script, queue = {}, fragments = {}, stderr = "", generation = 0 }
    workers[key] = worker
  end
  next_id = next_id + 1
  entry.id = next_id
  worker.queue[#worker.queue + 1] = entry
  pump(worker)
  return function()
    if not entry.cb then return false end
    if worker.active == entry then
      fail_active(worker, "render cancelled", true)
    else
      for index, queued in ipairs(worker.queue) do
        if queued == entry then table.remove(worker.queue, index); break end
      end
      complete(entry, { ok = false, cancelled = true, error = "render cancelled" })
    end
    return true
  end
end

function M.stop(cmd, script, reason)
  local key = cmd .. "\0" .. script
  local worker = workers[key]
  if not worker then return end
  workers[key] = nil
  worker.dead = true
  disconnect(worker)
  local active, queue = worker.active, worker.queue
  worker.active, worker.queue = nil, {}
  local result = { ok = false, error = reason or "pele_mermaid: renderer stopped" }
  complete(active, result)
  for _, entry in ipairs(queue) do complete(entry, result) end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("PeleMermaidWorker", { clear = true }),
  callback = function()
    exiting = true
    for _, worker in pairs(workers) do M.stop(worker.cmd, worker.script, "pele_mermaid: renderer shutting down") end
  end,
})

return M
