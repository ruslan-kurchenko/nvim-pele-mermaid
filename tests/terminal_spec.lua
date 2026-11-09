local terminal = require("pele_mermaid.terminal")

local previous = {
  HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
  HERDR_CONFIG_PATH = vim.env.HERDR_CONFIG_PATH,
  TERM_PROGRAM = vim.env.TERM_PROGRAM,
}
local path = vim.fn.tempname()
vim.env.HERDR_PANE_ID = "test-pane"
vim.env.HERDR_CONFIG_PATH = path
vim.env.TERM_PROGRAM = "ghostty"

vim.fn.writefile({ "[experimental]", "kitty_graphics = false" }, path)
assert(terminal.detect() == "ghostty")
assert(terminal.supports_kitty_graphics("ghostty"))
assert(not terminal.kitty_graphics_available("ghostty"))

vim.fn.writefile({ "[experimental]", "kitty_graphics = true" }, path)
assert(terminal.kitty_graphics_available("ghostty"))

vim.env.TERM_PROGRAM = "tern"
assert(terminal.detect() == "tern")
assert(terminal.kitty_graphics_available("tern"))
assert(not terminal.supports_kitty_graphics("unknown"))
vim.env.HERDR_PANE_ID = previous.HERDR_PANE_ID
vim.env.HERDR_CONFIG_PATH = previous.HERDR_CONFIG_PATH
vim.env.TERM_PROGRAM = previous.TERM_PROGRAM
vim.fn.delete(path)
