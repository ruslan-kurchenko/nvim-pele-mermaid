local saved = {
  image = package.loaded.image,
  backend = package.loaded["pele_mermaid.deps.image_backend"],
  term = package.loaded["image/utils/term"],
  helpers = package.loaded["image/backends/kitty/helpers"],
  program = vim.env.TERM_PROGRAM,
}
vim.env.TERM_PROGRAM = "test"
local created, renders = {}, 0
package.loaded.image = {
  from_file = function(path, options)
    local image = {
      path = path, options = options, geometry = { x = options.x, y = options.y },
      buffer = options.buffer, window = options.window, inline = options.inline,
    }
    function image:render(geometry)
      if self.fail then error("render rejected") end
      self.geometry = geometry or self.geometry
      self.is_rendered = true
      renders = renders + 1
    end
    function image:clear() self.is_rendered = false end
    created[#created + 1] = image
    return image
  end,
}
package.loaded["pele_mermaid.deps.image_backend"] = nil
local backend = require("pele_mermaid.deps.image_backend")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, bufnr)
local winid = vim.api.nvim_get_current_win()
local one, two = vim.fn.tempname() .. ".png", vim.fn.tempname() .. ".png"
vim.fn.writefile({ "one" }, one)
vim.fn.writefile({ "two" }, two)
local options = { id = "owned-test", path = one, buffer = bufnr, window = winid, row = 0, col = 0 }
assert(backend.render(options))
assert(#created == 1 and renders == 1)
assert(created[1].options.width == nil and created[1].options.height == nil)
local placement_path = created[1].path
assert(vim.uv.fs_lstat(placement_path).type == "file" and vim.fn.readfile(placement_path)[1] == "one")
options.path = two
assert(backend.render(options))
assert(#created == 1 and renders == 2, "updates must reuse stable owned image placement")
assert(vim.fn.readfile(placement_path)[1] == "two")
vim.uv.fs_unlink(two)
assert(backend.render(options), "an evicted cache artifact must redraw from its owned placement")
assert(vim.fn.readfile(placement_path)[1] == "two")
vim.fn.writefile({ "replacement" }, two)
assert(backend.render(options), "refreshing the same source path must update its owned pixels")
assert(vim.fn.readfile(placement_path)[1] == "replacement")
options.inline, options.with_virtual_padding, options.native_pixels = false, false, true
assert(backend.render(options))
assert(created[1].ignore_global_max_size and not created[1].inline and not created[1].with_virtual_padding)
backend.clear_window(winid)
assert(not backend._placements()[options.id] and not vim.uv.fs_lstat(placement_path))
assert(not vim.uv.fs_lstat(vim.fn.fnamemodify(placement_path, ":h")), "last placement must remove its private directory")
local before = renders
created[1]:render()
assert(renders == before, "detached images must not reappear on delayed redraw")
assert(backend.render(options))
created[2].fail = true
local ok, err = backend.render(options)
assert(not ok and err:find("render rejected", 1, true))
assert(backend._placements()[options.id], "failed rendering must preserve the prior placement")
created[2].fail = false
assert(backend.render(options))
backend.clear_buffer(bufnr)
assert(next(backend._placements()) == nil)

assert(backend.render(options))
local prior_path = backend._placements()[options.id].image.path
local prior_image = backend._placements()[options.id].image
local original_render = prior_image.render
prior_image.render = function(self, geometry)
  if vim.fn.readfile(prior_path)[1] == "one" then error("replacement rejected") end
  return original_render(self, geometry)
end
options.path = one
local replaced, replacement_error = backend.render(options)
assert(not replaced and replacement_error:find("replacement rejected", 1, true))
assert(backend._placements()[options.id].path == two and vim.fn.readfile(prior_path)[1] == "replacement")
options.path = two
backend.clear(options.id)

-- Independently loaded sessions with identical buffer/window IDs never share files.
assert(backend.render(options))
local first_path = backend._placements()[options.id].image.path
package.loaded["pele_mermaid.deps.image_backend"] = nil
local other_backend = require("pele_mermaid.deps.image_backend")
assert(other_backend.render(options))
local other_path = other_backend._placements()[options.id].image.path
assert(first_path ~= other_path, "placements must be session-private")
backend.stop()
assert(not vim.uv.fs_lstat(first_path))
assert(vim.fn.readfile(other_path)[1] == "replacement", "stopping one session must not remove another's owned file")
other_backend.stop()
assert(not vim.uv.fs_lstat(vim.fn.fnamemodify(other_path, ":h")))

-- Only Tern-owned Kitty placement is raised, and native PNG pixels are never
-- stretched to rounded terminal rows/columns (110px is not 4 * 34px).
local writes = {}
package.loaded["image/utils/term"] = { get_size = function() return { cell_width = 8, cell_height = 34 } end }
package.loaded["image/backends/kitty/helpers"] = {
  write_graphics_at = function(command, x, y) writes[#writes + 1] = { command = command, x = x, y = y } end,
}
vim.env.TERM_PROGRAM = "tern"
local tern = require("pele_mermaid.deps.tern")
local image = {
  internal_id = 123,
  global_state = { options = { backend = "kitty" } },
  rendered_geometry = { x = 2, y = 3, width = 20, height = 4 },
  bounds = { left = 0, top = 0, right = 100, bottom = 30 },
}
tern.place(image)
assert(#writes == 1)
local command = writes[1].command
assert(command.display_zindex == 1 and command.image_id == 123 and command.placement_id == 123)
assert(command.display_columns == nil and command.display_rows == nil)
assert(command.columns == nil and command.rows == nil)
assert(writes[1].x == 3 and writes[1].y == 4)
image.global_state.options.kitty_method = "unicode-placeholders"
tern.place(image)
assert(#writes == 1)

package.loaded.image = saved.image
package.loaded["pele_mermaid.deps.image_backend"] = saved.backend
package.loaded["image/utils/term"] = saved.term
package.loaded["image/backends/kitty/helpers"] = saved.helpers
vim.env.TERM_PROGRAM = saved.program
vim.fn.delete(one)
vim.fn.delete(two)
vim.api.nvim_buf_delete(bufnr, { force = true })
