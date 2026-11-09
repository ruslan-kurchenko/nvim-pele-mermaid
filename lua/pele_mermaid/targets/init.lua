local export_module = require("pele_mermaid.targets.external")
local float_module = require("pele_mermaid.targets.float")
local inspect_module = require("pele_mermaid.targets.inspect")
local split_module = require("pele_mermaid.targets.split")

local M = {}

function M.new(runtime, view, parser, config)
  return {
    float = float_module.new(runtime, view, config),
    split = split_module.new(runtime, view, config),
    export = export_module.new(runtime, view, parser),
    inspect = inspect_module.new(runtime, view, config),
  }
end

return M
