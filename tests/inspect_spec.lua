local inspect_module = require("pele_mermaid.targets.inspect")

local requests = {}
local runtime = {
  current_block_val = { id = 1, source = "flowchart LR\n  A --> B", complete = true, bufnr = 1 },
}
function runtime:current_block() return self.current_block_val end
function runtime:request(block, options, callback)
  requests[#requests + 1] = { block = block, options = options }
  callback({ ok = true, key = "inspect-png-" .. options.width_px, png_path = "/tmp/inspect.png" })
  return { cancel = function() end }
end

local view = { rendered = {}, cleared = {} }
function view:graphics_available() return true end
function view:width_px() return 800 end
local backend = {
  render = function(opts) view.rendered[#view.rendered + 1] = opts; return true end,
  clear = function(id) view.cleared[#view.cleared + 1] = id end,
}

local config = {
  inspect = { max_width = 0.95, max_height = 0.90 },
}

local crops = {}
local image = {
  cell_size = function() return 8, 16 end,
  viewport = function(options, callback)
    crops[#crops + 1] = options
    callback({ ok = true, path = "viewport.png", x = options.x, y = options.y })
    return { cancel = function() end }
  end,
}
local inspector = inspect_module.new(runtime, view, config, { backend = backend, image = image })

-- 1. Open inspector
assert(inspector:is_open() == false)
local opened = inspector:toggle()
assert(opened == true)
assert(inspector:is_open() == true)
assert(#requests >= 1)
assert(inspector.zoom_level == 1.0)

-- 2. Zoom in
local prev_reqs = #requests
inspector:zoom_in()
assert(inspector.zoom_level == 1.5)
assert(#requests > prev_reqs)
assert(requests[#requests].options.width_px > requests[1].options.width_px, "zoom in must increase raster width")

local render = view.rendered[#view.rendered]
assert(render.native_pixels and render.inline == false and render.with_virtual_padding == false)
assert(render.max_width_window_percentage == nil and render.max_height_window_percentage == nil)
local before_pan = #requests
inspector:pan(3, 2)
assert(crops[#crops].x == 24 and crops[#crops].y == 32, "pan must change viewport pixels")
assert(#requests == before_pan, "pan must reuse the zoomed artifact")
inspector:pan(-20, -20)
assert(crops[#crops].x == 0 and crops[#crops].y == 0)

-- 3. Reset zoom
inspector:reset_zoom()
assert(inspector.zoom_level == 1.0)

-- Failed replacement must leave both the artifact and displayed crop intact.
local old_artifact = inspector.artifact
local old_crop = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "last good crop" }, old_crop)
inspector.viewport_path = old_crop
local clears_before_failure = #view.cleared
local request_ok, crop_ok, render_ok = runtime.request, image.viewport, backend.render
runtime.request = function(_, _, _, callback)
  callback({ ok = false, error = "render failed" })
  return { cancel = function() end }
end
inspector:_render_current()
assert(inspector.artifact == old_artifact and inspector.viewport_path == old_crop)
assert(#view.cleared == clears_before_failure and vim.fn.filereadable(old_crop) == 1)
runtime.request = request_ok
local candidate_released = 0
local function candidate()
  return { ok = true, png_path = "candidate.png", release = function() candidate_released = candidate_released + 1 end }
end
image.viewport = function(_, callback)
  callback({ ok = false, error = "crop failed" })
  return { cancel = function() end }
end
inspector:_display(candidate())
assert(candidate_released == 1 and inspector.artifact == old_artifact and inspector.viewport_path == old_crop)
local rejected_crop = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "rejected" }, rejected_crop)
image.viewport = function(_, callback)
  callback({ ok = true, path = rejected_crop, temporary = true, x = 0, y = 0 })
  return { cancel = function() end }
end
backend.render = function() return false, "backend failed" end
inspector:_display(candidate())
assert(candidate_released == 2 and vim.fn.filereadable(rejected_crop) == 0)
assert(inspector.artifact == old_artifact and inspector.viewport_path == old_crop)
assert(vim.fn.filereadable(old_crop) == 1 and #view.cleared == clears_before_failure)
image.viewport, backend.render = crop_ok, render_ok
inspector:_display(candidate())
assert(inspector.artifact ~= old_artifact and vim.fn.filereadable(old_crop) == 0)

local delayed_crop
local cancelled_crop = false
image.viewport = function(_, callback)
  delayed_crop = callback
  return { cancel = function() cancelled_crop = true end }
end
inspector:_display(candidate())
local pending_artifact = inspector.candidate
assert(pending_artifact ~= inspector.artifact)
inspector:close()
assert(cancelled_crop and candidate_released == 4, "closing must release both displayed and pending artifacts")
local late_crop = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "late" }, late_crop)
delayed_crop({ ok = true, path = late_crop, temporary = true, x = 0, y = 0 })
assert(vim.fn.filereadable(late_crop) == 0, "a late crop must not leak after close")
image.viewport = crop_ok

-- 4. Close inspector
inspector:close()
assert(inspector:is_open() == false)
assert(#view.cleared > 0, "closing inspector must clear image placement")

-- Exercise real viewport geometry without starting ImageMagick.
local viewport = require("pele_mermaid.deps.image")
local fixture = vim.fn.tempname() .. ".png"
local file = assert(io.open(fixture, "wb"))
file:write("\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\6\64\0\0\3\32")
file:close() -- IHDR width 1600, height 800.
local original_system = vim.system
local commands, completions = {}, {}
vim.system = function(command, _, callback)
  commands[#commands + 1] = command
  completions[#completions + 1] = callback
  return { kill = function() end }
end
local cropped
viewport.viewport({ path = fixture, width = 800, height = 400, x = 900, y = 500 }, function(result) cropped = result end)
assert(commands[1][4] == "800x400+800+400", "pan must clamp to the final visible native pixels")
assert(commands[1][5] == "+repage")
completions[1]({ code = 0 })
assert(vim.wait(100, function() return cropped ~= nil end, 1))
assert(cropped.ok and cropped.temporary and cropped.x == 800 and cropped.y == 400)
vim.uv.fs_unlink(cropped.path)
local whole
viewport.viewport({ path = fixture, width = 2000, height = 1000 }, function(result) whole = result end)
assert(whole.ok and whole.path == fixture and not whole.temporary and #commands == 1)
local delivered = false
local pending_crop = viewport.viewport({ path = fixture, width = 800, height = 400 }, function() delivered = true end)
pending_crop.cancel()
completions[2]({ code = 0 })
vim.wait(20, function() return delivered end, 1)
assert(not delivered, "cancelled viewport must not replace a newer image")
vim.system = original_system
vim.fn.delete(fixture)
