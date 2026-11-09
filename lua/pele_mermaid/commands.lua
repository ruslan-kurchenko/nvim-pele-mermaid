local M = {}

function M.setup(api)
  vim.api.nvim_create_user_command("MermaidToggle", function()
    api.toggle()
  end, { desc = "Toggle Mermaid buffer between read and edit modes", force = true })

  vim.api.nvim_create_user_command("MermaidRefresh", function()
    api.refresh()
  end, { desc = "Refresh all Mermaid diagrams without cache", force = true })

  vim.api.nvim_create_user_command("MermaidPreview", function()
    api.preview_toggle()
  end, { desc = "Toggle Mermaid preview for the block under cursor", force = true })

  vim.api.nvim_create_user_command("MermaidSplit", function()
    api.split_toggle()
  end, { desc = "Toggle the tab-local Mermaid split preview", force = true })

  vim.api.nvim_create_user_command("MermaidExport", function(options)
    api.export_current(options.args ~= "" and options.args or nil, options.bang)
  end, {
    nargs = "?",
    bang = true,
    complete = "file",
    force = true,
    desc = "Export the Mermaid block under cursor",
  })

  vim.api.nvim_create_user_command("MermaidExportAll", function(options)
    api.export_all(options.args ~= "" and options.args or nil, options.bang)
  end, {
    nargs = "?",
    bang = true,
    complete = "dir",
    force = true,
    desc = "Export every complete Mermaid block in document order",
  })
  vim.api.nvim_create_user_command("MermaidNext", function()
    api.next()
  end, { desc = "Jump to the next Mermaid diagram in the document", force = true })

  vim.api.nvim_create_user_command("MermaidPrev", function()
    api.prev()
  end, { desc = "Jump to the previous Mermaid diagram in the document", force = true })

  vim.api.nvim_create_user_command("MermaidList", function()
    api.list()
  end, { desc = "Fuzzy search and jump to Mermaid diagrams in buffer", force = true })

  vim.api.nvim_create_user_command("MermaidYank", function()
    api.yank()
  end, { desc = "Copy retina PNG of current Mermaid diagram to system clipboard", force = true })

  vim.api.nvim_create_user_command("MermaidFix", function()
    api.fix()
  end, { desc = "Auto-fix common syntax issues in the Mermaid block under cursor", force = true })

  vim.api.nvim_create_user_command("MermaidInspect", function()
    api.inspect_toggle()
  end, { desc = "Toggle maximized zoom and pan inspector for the diagram under cursor", force = true })
end

return M
