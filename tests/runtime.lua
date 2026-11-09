local config = require("pele_mermaid.config")
local runtime = require("pele_mermaid.deps.runtime")
local renderer = require("pele_mermaid.deps.renderer")
local root = vim.fn.tempname()
local saved = {
  path = vim.env.PATH,
  install = vim.env.BUN_INSTALL,
  home = vim.uv.os_homedir,
  notify = vim.notify,
  executable = vim.fn.executable,
  exepath = vim.fn.exepath,
}

local function fixture(path, version)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "#!/bin/sh", "printf '" .. (version or "v22.0.0") .. "\\n'", "exit 0" }, path)
  assert(vim.fn.setfperm(path, "rwx------") == 1, "fixture must be executable")
  return path
end

local function resolve(command)
  return runtime.resolve({ renderer = { command = command } })
end

local function run()
  local home = root .. "/home"
  local bin = root .. "/path"
  local install = root .. "/install"
  vim.fn.mkdir(bin, "p")
  vim.env.PATH = bin
  vim.env.BUN_INSTALL = install
  vim.uv.os_homedir = function() return home end

  local cfg = config.defaults()
  assert(config.normalize({ mermaid = { options = { font = "Custom Font" } } }).mermaid.options.font == "Custom Font",
    "explicit font must be preserved")

  local notifications, probes = 0, 0
  vim.notify = function() notifications = notifications + 1 end
  vim.fn.executable = function() probes = probes + 1; return 0 end
  vim.fn.exepath = function() probes = probes + 1; return "" end
  for _ = 1, 10 do
    config.normalize(cfg)
  end
  assert(notifications == 0 and probes == 0, "configuration reads must not probe or warn about executables")
  vim.fn.executable = saved.executable
  vim.fn.exepath = saved.exepath

  local command, err = resolve("auto")
  assert(command == nil and err:find("renderer.command", 1, true), "missing runtime must offer an actionable override")
  local instance = renderer.new(cfg.renderer)
  assert(not instance:is_available(), "availability must agree with failed discovery")
  local calls = 0
  instance:render({ source = "flowchart LR\nA --> B", output = "svg" }, function(result)
    calls = calls + 1
    assert(not result.ok and result.error == err, "render must return the runtime failure")
  end)
  assert(calls == 1 and notifications == 0, "render must report once through its callback without duplicate notification")

  local node = fixture(bin .. "/node")
  assert(resolve("auto") == node, "Node on PATH must work when Bun is unavailable")
  assert(resolve("node") == node, "explicit Node command must work")
  assert(resolve("bun") == nil, "explicit Bun must not fall back to Node")

  local old_node = fixture(root .. "/old/node", "v18.20.0")
  vim.env.PATH = root .. "/old"
  command, err = resolve("auto")
  assert(command == nil and err:find("Node.js >=20", 1, true), "unsupported automatic Node must report its minimum version")
  assert(resolve(old_node) == nil, "unsupported explicit Node must not pass health discovery")
  vim.env.PATH = bin

  local home_bun = fixture(home .. "/.bun/bin/bun")
  assert(resolve("auto") == home_bun, "standard Bun installation must work without shell PATH")
  assert(resolve("bun") == home_bun, "explicit Bun name must discover standard installation")
  local installed_bun = fixture(install .. "/bin/bun")
  assert(resolve("auto") == installed_bun, "BUN_INSTALL must take precedence over home installation")
  local path_bun = fixture(bin .. "/bun")
  assert(resolve("auto") == path_bun, "PATH Bun must take precedence over standard locations")

  local custom = fixture(root .. "/custom runtime/js-runner")
  assert(resolve(custom) == custom, "absolute overrides need not contain bun in their name")
  assert(config.normalize({ renderer = { command = custom } }).renderer.command == custom,
    "normalization must preserve explicit runtime paths")
  local missing = root .. "/missing-bun"
  command, err = resolve(missing)
  assert(command == nil and err:find(missing, 1, true), "invalid absolute override must not fall back to installed runtimes")
  assert(resolve("") == nil and resolve(false) == nil, "invalid command values must fail without probing")

  vim.fn.setfperm(path_bun, "rw-------")
  assert(resolve("auto") == installed_bun, "non-executable PATH entry must not block standard installation")
  vim.fn.delete(installed_bun)
  vim.env.BUN_INSTALL = ""
  assert(resolve("auto") == home_bun, "empty BUN_INSTALL must still allow standard home location")
  print("PASS: GUI runtime discovery, explicit overrides, Bun/Node precedence, silent configuration, one actionable render failure, bundled-font default")
end

local ok, err = xpcall(run, debug.traceback)
vim.env.PATH = saved.path
vim.env.BUN_INSTALL = saved.install
vim.uv.os_homedir = saved.home
vim.notify = saved.notify
vim.fn.executable = saved.executable
vim.fn.exepath = saved.exepath
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
