local M = {}

function M.place(image)
  if vim.env.TERM_PROGRAM ~= "tern" then return end
  local options = image.global_state and image.global_state.options
  if not options or options.backend ~= "kitty" or options.kitty_method == "unicode-placeholders" then return end
  local geometry, bounds = image.rendered_geometry, image.bounds
  local size = require("image/utils/term").get_size()
  if not size or not geometry or not geometry.x or not bounds then return end
  local x, y = math.max(geometry.x, bounds.left), math.max(geometry.y, bounds.top)
  local width = math.min(geometry.x + geometry.width, bounds.right) - x
  local bottom = bounds.bottom + 1
  if image.window and vim.api.nvim_win_is_valid(image.window) then
    local info = vim.fn.getwininfo(image.window)[1]
    -- Positive-z placements must not cover the statusline below the text area.
    if info then bottom = math.min(bottom, info.winrow - 1 + info.height) end
  end
  local height = math.min(geometry.y + geometry.height, bottom) - y
  if width <= 0 or height <= 0 then return end

  -- Tern paints negative Kitty z layers underneath Neovim's opaque cell backgrounds.
  -- Re-place only this plugin's image above those backgrounds; image.nvim still owns
  -- transmission, clipping, overlap detection, scrolling and deletion.
  -- Keep native PNG pixels: specifying both cell rows and columns stretches the
  -- rounded final row (for example, a 110px image becomes 136px in 34px cells).
  require("image/backends/kitty/helpers").write_graphics_at({
    action = "p", quiet = 2, image_id = image.internal_id, placement_id = image.internal_id,
    display_zindex = 1, display_cursor_policy = 1,
    display_x = math.max(0, x - geometry.x) * size.cell_width,
    display_y = math.max(0, y - geometry.y) * size.cell_height,
    display_width = width * size.cell_width, display_height = height * size.cell_height,
  }, x + 1, y + 1)
end

return M
