vim.cmd("highlight clear")
vim.g.colors_name = "pearl-material"
vim.api.nvim_set_hl(0, "Normal", { fg = "{{colors.on_surface.default.hex}}", bg = "{{colors.surface.default.hex}}" })
vim.api.nvim_set_hl(0, "Comment", { fg = "{{colors.on_surface_variant.default.hex}}" })
vim.api.nvim_set_hl(0, "String", { fg = "{{colors.tertiary.default.hex}}" })
vim.api.nvim_set_hl(0, "Function", { fg = "{{colors.primary.default.hex}}" })
vim.api.nvim_set_hl(0, "Keyword", { fg = "{{colors.secondary.default.hex}}" })
vim.api.nvim_set_hl(0, "Visual", { fg = "{{colors.on_primary_container.default.hex}}", bg = "{{colors.primary_container.default.hex}}" })
vim.api.nvim_set_hl(0, "Error", { fg = "{{colors.error.default.hex}}", bg = "{{colors.error_container.default.hex}}" })
vim.api.nvim_set_hl(0, "StatusLine", { fg = "{{colors.on_primary.default.hex}}", bg = "{{colors.primary.default.hex}}" })
vim.api.nvim_set_hl(0, "LineNr", { fg = "{{colors.outline.default.hex}}" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "{{colors.surface_container.default.hex}}" })
vim.api.nvim_set_hl(0, "NormalFloat", { fg = "{{colors.on_surface.default.hex}}", bg = "{{colors.surface_container_high.default.hex}}" })
vim.api.nvim_set_hl(0, "Pmenu", { fg = "{{colors.on_surface.default.hex}}", bg = "{{colors.surface_container.default.hex}}" })
vim.api.nvim_set_hl(0, "PmenuSel", { fg = "{{colors.on_primary.default.hex}}", bg = "{{colors.primary.default.hex}}" })
vim.g.terminal_color_0 = "{{base16.base00.default.hex}}"
vim.g.terminal_color_1 = "{{base16.base08.default.hex}}"
vim.g.terminal_color_2 = "{{base16.base0b.default.hex}}"
vim.g.terminal_color_3 = "{{base16.base0a.default.hex}}"
vim.g.terminal_color_4 = "{{base16.base0d.default.hex}}"
vim.g.terminal_color_5 = "{{base16.base0e.default.hex}}"
vim.g.terminal_color_6 = "{{base16.base0c.default.hex}}"
vim.g.terminal_color_7 = "{{base16.base05.default.hex}}"
vim.g.terminal_color_8 = "{{base16.base03.default.hex}}"
vim.g.terminal_color_9 = "{{base16.base08.default.hex}}"
vim.g.terminal_color_10 = "{{base16.base0b.default.hex}}"
vim.g.terminal_color_11 = "{{base16.base0a.default.hex}}"
vim.g.terminal_color_12 = "{{base16.base0d.default.hex}}"
vim.g.terminal_color_13 = "{{base16.base0e.default.hex}}"
vim.g.terminal_color_14 = "{{base16.base0c.default.hex}}"
vim.g.terminal_color_15 = "{{base16.base07.default.hex}}"
