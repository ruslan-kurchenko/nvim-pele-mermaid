-- Run from the repository: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run.lua
local specs = {
  "config_spec", "renderer_spec", "rasterizer_spec", "parser_spec", "artifact_spec", "cache_spec",
  "runtime_spec", "navigation_spec", "projection_spec", "read_mode_spec",
  "terminal_spec", "tern_spec", "inspect_spec", "linter_spec", "yank_spec", "log_spec",
  "in_buffer_spec", "image_backend_spec", "targets_spec", "workflow_spec",
}
for _, name in ipairs(specs) do dofile("tests/" .. name .. ".lua") end
print("Pele Mermaid regression specifications passed")
