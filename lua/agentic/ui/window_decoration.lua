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
--- @field enabled? boolean Whether to enable the header
--- @field hl? string Highlight group for the header text
--- @field reverse_hl? string Highlight group for the separator
local default_config = {
    enabled = true,
    align = "center",
    hl = Theme.HL_GROUPS.WIN_BAR_TITLE,
    reverse_hl = "NormalFloat",
}

--- Format a text segment with highlight group
--- @param text string
--- @param highlight string
--- @return string
local function format_segment(text, highlight)
    return "%#" .. highlight .. "#" .. text
end

--- @param winid integer
--- @param opts? { title?: string, hl?: string, reverse_hl?: string, suffix?: string|number }
function WindowDecoration.render_window_header(winid, opts)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    opts = opts or {}

    local title = opts.title or ""

    if opts.suffix then
        title = title .. " " .. opts.suffix
    end

    WindowDecoration._render_header(winid, title, {
        enabled = true,
        hl = opts.hl,
        reverse_hl = opts.reverse_hl,
    })
end

--- Render a header/title for a window using winbar
--- @param winid integer
--- @param text string Header text to display
--- @param opts? agentic.ui.WindowDecoration.Config
function WindowDecoration._render_header(winid, text, opts)
    opts = vim.tbl_extend("force", default_config, opts or {}) --[[@as agentic.ui.WindowDecoration.Config ]]

    if not opts.enabled then
        return
    end

    local winbar_text

    if opts.align == "left" then
        winbar_text = format_segment(" " .. text .. " %=", opts.hl)
    elseif opts.align == "center" then
        winbar_text = format_segment("%= " .. text .. " %=", opts.hl)
    elseif opts.align == "right" then
        winbar_text = format_segment("%=" .. text .. " ", opts.hl)
    end

    vim.api.nvim_set_option_value("winbar", winbar_text, { win = winid })
end

return WindowDecoration
