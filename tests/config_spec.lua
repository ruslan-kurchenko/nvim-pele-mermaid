local config = require("pele_mermaid.config")

local custom = config.normalize({
  debounce_ms = 0,
  mermaid = { theme = "catppuccin-mocha", options = { bg = "#123456", padding = 3 } },
  split = { position = "left", width = 72 },
})
assert(custom.debounce_ms == 0)
assert(custom.mermaid.options.bg == "#123456")
assert(custom.mermaid.options.padding == 3)
assert(custom.split.width == 72)

local function rejects(options, fragment)
  local ok, message = pcall(config.normalize, options)
  assert(not ok, "configuration unexpectedly passed")
  assert(tostring(message):find(fragment, 1, true), message)
end

rejects({ render = { target = "inline" } }, "render")
rejects({ mermaid = { theme = "bamboo" } }, "mermaid.theme")
rejects({ inline = { max_width = 1.5 } }, "inline.max_width")
rejects({ keymaps = {} }, "keymaps")
rejects({ mermaid = { options = { unknown = true } } }, "mermaid.options.unknown")
rejects({ split = { position = "top" } }, "split.position")
rejects({ renderer = { timeout_ms = 0 } }, "renderer.timeout_ms")
rejects({ cache = { max_bytes = 0 } }, "cache.max_bytes")

