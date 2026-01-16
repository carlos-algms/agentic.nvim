---Window decoration module for managing window titles, statuslines, and highlights.
---
---This module provides utilities to render headers (winbar) and statuslines for windows.
---
---## Lualine Compatibility
---
---If you're using lualine or similar statusline plugins, ensure windows have their
---statusline set to prevent the plugin from hijacking them:
---
---```lua
---vim.api.nvim_set_option_value("statusline", " ", { win = winid })
---```
---
---Alternatively, configure lualine to ignore specific filetypes:
---```lua
---require('lualine').setup({
---  options = {
---    disabled_filetypes = {
---      statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
---      winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
---    }
---  }
---})
---```

local Theme = require("agentic.theme")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}

--- @class agentic.ui.WindowDecoration.Config
--- @field align? "left"|"center"|"right" Header text alignment
--- @field hl? string Highlight group for the header text
--- @field reverse_hl? string Highlight group for the separator
local default_config = {
    align = "center",
    hl = Theme.HL_GROUPS.WIN_BAR_TITLE,
    reverse_hl = "NormalFloat",
}

--- @param winid integer
--- @param pieces string[]
function WindowDecoration.render_window_header(winid, pieces)
    vim.schedule(function()
        -- win_is_valid needs the schedule wrapper
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            return
        end

        local text = table.concat(pieces, " | ")

        -- Handle empty string case - disable winbar completely
        if text == "" then
            vim.api.nvim_set_option_value("winbar", nil, { win = winid })
            return
        end

        local opts = default_config

        local winbar_text = string.format("%%#%s# %s %%#Normal#", opts.hl, text)

        if opts.align == "left" then
            winbar_text = winbar_text .. "%="
        elseif opts.align == "center" then
            winbar_text = "%=" .. winbar_text .. "%="
        elseif opts.align == "right" then
            winbar_text = "%=" .. winbar_text
        end

        winbar_text = "%#Normal#" .. winbar_text

        vim.api.nvim_set_option_value("winbar", winbar_text, { win = winid })
    end)
end

return WindowDecoration
