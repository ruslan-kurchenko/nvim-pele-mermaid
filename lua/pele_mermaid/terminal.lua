local M = {}

local function env(name)
  local value = vim.env[name]
  return value ~= nil and tostring(value) or nil
end

local function herdr_kitty_graphics_enabled()
  if not env("HERDR_PANE_ID") then return true end
  local path = env("HERDR_CONFIG_PATH") or vim.fn.expand("~/.config/herdr/config.toml")
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return false end

  local section
  for _, line in ipairs(lines) do
    local current = line:match("^%s*%[([^%]]+)%]%s*$")
    if current then
      section = current
    elseif section == "experimental" then
      local value = line:match("^%s*kitty_graphics%s*=%s*(%a+)")
      if value then return value == "true" end
    end
  end
  return false
end

function M.is_tmux()
  return env("TMUX") ~= nil
end

function M.detect()
  local term = (env("TERM") or ""):lower()
  local term_program = (env("TERM_PROGRAM") or ""):lower()
  if term_program == "tern" then return "tern" end
  if env("GHOSTTY") or term_program == "ghostty" or term:find("ghostty", 1, true) then return "ghostty" end
  if env("KITTY_WINDOW_ID") or term:find("kitty", 1, true) then return "kitty" end
  if env("WEZTERM_EXECUTABLE") or env("WEZTERM_PANE") then return "wezterm" end
  if env("ALACRITTY_LOG") or term_program == "alacritty" or term == "alacritty" then return "alacritty" end
  return "unknown"
end

function M.supports_kitty_graphics(application)
  return application == "tern" or application == "ghostty" or application == "kitty" or application == "wezterm"
end

function M.kitty_graphics_available(application)
  return M.supports_kitty_graphics(application) and herdr_kitty_graphics_enabled()
end

return M
