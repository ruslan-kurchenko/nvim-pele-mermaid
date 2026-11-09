local rasterizer = require("pele_mermaid.deps.rasterizer")
local config = require("pele_mermaid.config")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local svg, png, executable = root .. "/input.svg", root .. "/cached.png", root .. "/resvg"
vim.fn.writefile({ '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><rect width="120" height="40" fill="white"/><text x="5" y="26" font-family="Maple Mono NF" font-size="20">Maple</text></svg>' }, svg)

local function fixture(action)
  vim.fn.writefile({ "#!/bin/sh", 'printf partial > "$6"', "printf started > " .. vim.fn.shellescape(root .. "/started"), action }, executable)
  assert(vim.fn.setfperm(executable, "rwx------") == 1)
end

local function invoke(cfg)
  local done, success, message = false
  rasterizer.new(cfg):rasterize(svg, png, 240, function(result)
    done, success, message = true, result.ok, result.error
  end)
  assert(vim.wait(10000, function() return done end, 10), "asynchronous rasterizer never completed")
  return success, message
end

local function run()
  local cfg = config.normalize({ rasterizer = { command = executable } })
  for _, action in ipairs({ "exit 7", "exec /bin/sleep 10" }) do
    fixture(action)
    vim.fn.delete(root .. "/started")
    vim.fn.writefile({ "previous cached image" }, png)
    local start = vim.uv.hrtime()
    local ok, err = invoke(cfg)
    assert(not ok and err, "failed child must report failure")
    assert((vim.uv.hrtime() - start) / 1e9 < 5, "configured timeout must bound the pipeline")
    assert(vim.fn.filereadable(root .. "/started") == 1, "rasterizer fixture was not reached: " .. tostring(err))
    if action == "exit 7" then assert(err:find("code 7", 1, true), err)
    else assert(err:find("timed out", 1, true), err) end
    assert(vim.fn.readfile(png)[1] == "previous cached image", "failed or timed-out child must preserve cached PNG")
    assert(vim.wait(2000, function() return #vim.fn.glob(png .. ".*.png", false, true) == 0 end, 10), "failed child leaked partial PNG")
    -- The first call warms font preparation; the second tests the external child's deadline.
    cfg.rasterizer.timeout_ms = 1000
  end
  cfg = config.normalize({ rasterizer = { command = vim.fn.exepath("resvg") } })
  assert(cfg.rasterizer.command ~= "", "resvg required for this integration check")
  local ok, err = invoke(cfg)
  assert(ok, err)
  local file = assert(io.open(png, "rb"))
  local signature = file:read(8)
  file:close()
  assert(signature == "\137PNG\r\n\26\n", "successful absolute-path rasterizer must atomically replace cache with PNG")
  print("PASS: absolute rasterizer paths, warm font preparation, bounded timeout, partial cache preservation and atomic replacement")
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
