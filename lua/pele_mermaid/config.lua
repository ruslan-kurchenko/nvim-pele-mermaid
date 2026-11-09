local M = {}

local defaults = {
  enabled = true,
  filetypes = { "markdown" },
  debounce_ms = 100,
  mermaid = { theme = "nvim", options = { font = "Maple Mono NF", padding = 8 } },
  inline = { enabled = true, max_width = 0.90, max_height = 0.60 },
  float = { max_width = 0.90, max_height = 0.80 },
  split = { position = "right", width = 0.45 },
  renderer = { command = "auto", timeout_ms = 5000 },
  rasterizer = { command = "auto", timeout_ms = 3000 },
  cache = { max_bytes = 104857600, max_age_days = 7 },
  keymaps = false,
}

local valid_themes = {
  default = true,
  light = true,
  dark = true,
  nvim = true,
  ["catppuccin-mocha"] = true,
}

local schema = {
  enabled = true,
  filetypes = true,
  debounce_ms = true,
  mermaid = { theme = true, options = true },
  inline = { enabled = true, max_width = true, max_height = true },
  float = { max_width = true, max_height = true },
  split = { position = true, width = true },
  renderer = { command = true, timeout_ms = true },
  rasterizer = { command = true, timeout_ms = true },
  cache = { max_bytes = true, max_age_days = true },
  keymaps = true,
}

local option_schema = {
  bg = "string",
  fg = "string",
  line = "string",
  accent = "string",
  muted = "string",
  surface = "string",
  border = "string",
  font = "string",
  transparent = "boolean",
  padding = "number",
  nodeSpacing = "number",
  layerSpacing = "number",
}

local function fail(path, message)
  error(("pele_mermaid: invalid `%s`: %s"):format(path, message), 3)
end

local function reject_unknown(value, allowed, path)
  if type(value) ~= "table" then
    fail(path, "expected table")
  end
  for key, nested in pairs(value) do
    local expected = allowed[key]
    local child = path == "" and key or (path .. "." .. key)
    if expected == nil then
      fail(child, "unknown option")
    end
    if type(expected) == "table" then
      reject_unknown(nested, expected, child)
    end
  end
end

local function expect_type(value, expected, path)
  if type(value) ~= expected then
    fail(path, ("expected %s, got %s"):format(expected, type(value)))
  end
end

local function expect_integer(value, minimum, path)
  expect_type(value, "number", path)
  if value % 1 ~= 0 or value < minimum then
    fail(path, ("expected an integer >= %d"):format(minimum))
  end
end

local function expect_size(value, path)
  expect_type(value, "number", path)
  if value <= 0 or (value > 1 and value % 1 ~= 0) then
    fail(path, "expected a fraction in (0, 1] or a positive integer")
  end
end

local function validate_filetypes(filetypes)
  expect_type(filetypes, "table", "filetypes")
  if #filetypes == 0 then
    fail("filetypes", "expected at least one filetype")
  end
  for index, filetype in ipairs(filetypes) do
    if type(filetype) ~= "string" or filetype == "" then
      fail(("filetypes[%d]"):format(index), "expected a non-empty string")
    end
  end
end

local function validate_options(options)
  expect_type(options, "table", "mermaid.options")
  for key, value in pairs(options) do
    local expected = option_schema[key]
    if not expected then
      fail("mermaid.options." .. key, "unknown Pele option")
    end
    expect_type(value, expected, "mermaid.options." .. key)
    if expected == "string" and value == "" then
      fail("mermaid.options." .. key, "expected a non-empty string")
    end
    if expected == "number" and value < 0 then
      fail("mermaid.options." .. key, "expected a non-negative number")
    end
  end
end

local function validate(cfg)
  expect_type(cfg.enabled, "boolean", "enabled")
  validate_filetypes(cfg.filetypes)
  expect_integer(cfg.debounce_ms, 0, "debounce_ms")

  expect_type(cfg.mermaid.theme, "string", "mermaid.theme")
  if cfg.mermaid.theme ~= "auto" and not valid_themes[cfg.mermaid.theme] then
    fail("mermaid.theme", "expected auto, default, light, dark, nvim, or catppuccin-mocha")
  end
  validate_options(cfg.mermaid.options)

  expect_type(cfg.inline.enabled, "boolean", "inline.enabled")
  expect_size(cfg.inline.max_width, "inline.max_width")
  expect_size(cfg.inline.max_height, "inline.max_height")
  expect_size(cfg.float.max_width, "float.max_width")
  expect_size(cfg.float.max_height, "float.max_height")

  if cfg.split.position ~= "left" and cfg.split.position ~= "right" then
    fail("split.position", "expected `left` or `right`")
  end
  expect_size(cfg.split.width, "split.width")

  for _, section in ipairs({ "renderer", "rasterizer" }) do
    if type(cfg[section].command) ~= "string" or cfg[section].command == "" then
      fail(section .. ".command", "expected a non-empty string")
    end
    expect_integer(cfg[section].timeout_ms, 1, section .. ".timeout_ms")
  end

  expect_integer(cfg.cache.max_bytes, 1, "cache.max_bytes")
  expect_integer(cfg.cache.max_age_days, 1, "cache.max_age_days")
  if cfg.keymaps ~= false then
    fail("keymaps", "only `false` is supported; define buffer-local mappings in your plugin manager")
  end
end

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.normalize(user_options)
  user_options = user_options or {}
  reject_unknown(user_options, schema, "")
  local cfg = vim.tbl_deep_extend("force", M.defaults(), user_options)
  validate(cfg)
  return cfg
end

function M.is_valid_theme(name)
  return valid_themes[name] == true
end

return M
