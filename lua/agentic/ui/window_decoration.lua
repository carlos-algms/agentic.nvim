--- Window decoration module for managing window titles, statuslines, and highlights.
---
--- This module provides utilities to render headers (winbar) and statuslines for windows.
---
--- ## Lualine Compatibility
---
--- If you're using lualine or similar statusline plugins, ensure windows have their
--- statusline set to prevent the plugin from hijacking them:
---
--- ```lua
--- vim.api.nvim_set_option_value("statusline", " ", { win = winid })
--- ```
---
--- Alternatively, configure lualine to ignore specific filetypes:
--- ```lua
--- require('lualine').setup({
---   options = {
---     disabled_filetypes = {
---       statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
---       winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
---     }
---   }
--- })
--- ```

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
        suffix = "<S-Tab>: change mode",
    },
    input = { title = "󰦨 Prompt", suffix = "<C-s>: submit" },
    code = {
        title = "󰪸 Selected Code Snippets",
        suffix = "d: remove block",
    },
    files = {
        title = " Referenced Files",
        suffix = "d: remove file",
    },
    todos = {
        title = " TODO Items",
    },
}

--- @class agentic.ui.WindowDecoration.Config
--- @field align? "left"|"center"|"right" Header text alignment
--- @field hl? string Highlight group for the header text
--- @field reverse_hl? string Highlight group for the separator
local default_config = {
    align = "center",
    hl = Theme.HL_GROUPS.WIN_BAR_TITLE,
    reverse_hl = "NormalFloat",
}

--- Concatenates header parts (title, context, suffix) into a single string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @return string header_text
local function concat_header_parts(parts)
    local pieces = { parts.title }
    if parts.context ~= nil then
        table.insert(pieces, parts.context)
    end
    if parts.suffix ~= nil then
        table.insert(pieces, parts.suffix)
    end
    return table.concat(pieces, " | ")
end

--- Gets or initializes headers for a tabpage
--- @param tab_page_id integer
--- @return agentic.ui.ChatWidget.Headers
function WindowDecoration.get_headers_state(tab_page_id)
    if vim.t[tab_page_id].agentic_headers == nil then
        vim.t[tab_page_id].agentic_headers = WINDOW_HEADERS
    end
    return vim.t[tab_page_id].agentic_headers
end

--- Sets headers for a tabpage
--- @param tab_page_id integer
--- @param headers agentic.ui.ChatWidget.Headers
function WindowDecoration.set_headers_state(tab_page_id, headers)
    if vim.api.nvim_tabpage_is_valid(tab_page_id) then
        vim.t[tab_page_id].agentic_headers = headers
    end
end

--- Resolves the final header text applying user customization
--- Returns the header text and an error message if user function failed
--- @param dynamic_header agentic.ui.ChatWidget.HeaderParts Runtime header parts
--- @param window_name string Window name for Config.headers lookup and error messages
--- @return string|nil header_text The resolved header text or nil for empty
--- @return string|nil error_message Error message if user function failed
local function resolve_header_text(dynamic_header, window_name)
    local user_header = Config.headers and Config.headers[window_name]
    -- No user customization: use default parts
    if user_header == nil then
        return concat_header_parts(dynamic_header), nil
    end

    -- User function: call it and validate return
    if type(user_header) == "function" then
        local ok, result = pcall(user_header, dynamic_header)
        if not ok then
            return concat_header_parts(dynamic_header),
                string.format(
                    "Error in custom header function for '%s': %s",
                    window_name,
                    result
                )
        end
        if result == nil or result == "" then
            return nil, nil -- User explicitly wants no header
        end
        if type(result) ~= "string" then
            return concat_header_parts(dynamic_header),
                string.format(
                    "Custom header function for '%s' must return string|nil, got %s",
                    window_name,
                    type(result)
                )
        end
        return result, nil
    end

    -- User table: merge with dynamic header
    if type(user_header) == "table" then
        local merged = vim.tbl_extend("force", dynamic_header, user_header) --[[@as agentic.ui.ChatWidget.HeaderParts]]
        return concat_header_parts(merged), nil
    end

    -- Invalid type: warn and use default
    return concat_header_parts(dynamic_header),
        string.format(
            "Header for '%s' must be function|table|nil, got %s",
            window_name,
            type(user_header)
        )
end

--- Cache if there's a lualine like plugin managing the winbar
--- @type boolean|nil
local has_line_plugin = nil

--- @param winid integer
--- @param text string
local function set_winbar(winid, text)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    -- If winbar is already set (not empty), a plugin like lualine is managing it
    -- Skip setting ours to prevent flickering
    if has_line_plugin == nil then
        local current_winbar = vim.wo[winid].winbar
        has_line_plugin = current_winbar ~= ""
    end

    if has_line_plugin then
        return
    end

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
end

--- Sets the buffer name based on header text and tab count
--- @param bufnr integer Buffer number
--- @param header_text string|nil Resolved header text
--- @param tab_page_id integer Tab page ID for suffix
local function set_buffer_name(bufnr, header_text, tab_page_id)
    if not header_text or header_text == "" then
        return
    end

    -- Determine if we should show tab suffix based on total tab count
    local total_tabs = #vim.api.nvim_list_tabpages()

    --- @type string|nil
    local buf_name
    if total_tabs > 1 then
        buf_name = string.format("%s (Tab %d)", header_text, tab_page_id)
    else
        buf_name = header_text
    end

    vim.api.nvim_buf_set_name(bufnr, buf_name)
end

--- Renders a header for a window, handling user customization, winbar, and buffer naming
--- Derives all context from bufnr: winid, tab_page_id, and dynamic header from vim.t
--- @param bufnr integer Buffer number - stable reference to derive window and tab context
--- @param window_name string Name of the window (for Config.headers lookup and error messages)
--- @param context string|nil Optional context to set in header (e.g., "Mode: chat", "3 files")
function WindowDecoration.render_header(bufnr, window_name, context)
    vim.schedule(function()
        local winid = vim.fn.bufwinid(bufnr)
        if winid == -1 then
            -- Buffer not displayed in any window, skip rendering
            return
        end

        local tab_page_id = vim.api.nvim_win_get_tabpage(winid)

        local headers = WindowDecoration.get_headers_state(tab_page_id)
        local dynamic_header = headers[window_name]

        if not dynamic_header then
            Logger.debug(
                string.format(
                    "No header configuration found for window name '%s'",
                    window_name
                )
            )
            return
        end

        -- Set context if provided (must reassign to vim.t due to copy semantics)
        if context ~= nil then
            dynamic_header.context = context
            headers[window_name] = dynamic_header
            WindowDecoration.set_headers_state(tab_page_id, headers)
        end

        local header_text, err =
            resolve_header_text(dynamic_header, window_name)

        if err then
            Logger.notify(err)
        end

        local text = (header_text and header_text ~= "") and header_text or ""

        set_winbar(winid, text)
        set_buffer_name(bufnr, header_text, tab_page_id)
    end)
end

return WindowDecoration
