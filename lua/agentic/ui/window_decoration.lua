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
---       statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
---       winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
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
    },
    input = {
        title = "󰦨 Prompt",
        suffix = "submit: <C-s> | change mode: <S-Tab>",
    },
    code = {
        title = "󰪸 Selected Code Snippets",
        suffix = "d: remove block",
    },
    files = {
        title = " Referenced Files",
        suffix = "d: remove file",
    },
    diagnostics = {
        title = " Diagnostics",
        suffix = "d: remove diagnostic",
    },
    todos = {
        title = " Tasks list",
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
    --- @type string[]
    local pieces = { parts.title }
    if parts.context ~= nil then
        pieces[#pieces + 1] = parts.context
    end
    if parts.suffix ~= nil then
        pieces[#pieces + 1] = parts.suffix
    end
    return table.concat(pieces, " | ")
end

--- Builds the rich default header for the chat panel from live session state:
--- `title | provider - model - mode (used/size) $cost`. The chat panel carries
--- no key hint; submit/change-mode hints live on the input header.
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @param session_state agentic.acp.SessionState
--- @return string header_text
local function build_chat_header(parts, session_state)
    --- @type string[]
    local segments = {}
    --- @param value string|nil
    local function add_segment(value)
        if value ~= nil and value ~= "" then
            segments[#segments + 1] = value
        end
    end

    add_segment(session_state:get_provider_name())
    add_segment(session_state:get_model_name() or "unknown")
    add_segment(session_state:get_mode_name())

    local header =
        string.format("%s | %s", parts.title, table.concat(segments, " - "))

    local used = session_state:get_context_used()
    local size = session_state:get_context_size()
    if used ~= nil and size ~= nil then
        header = header .. string.format(" (%s/%s)", used, size)
    end

    local cost = session_state:get_cost_amount_raw()
    if cost ~= nil and cost ~= 0 then
        local amount = session_state:get_cost_amount() or ""
        local currency = session_state:get_cost_currency()
        if currency then
            header = header .. " " .. currency .. " " .. amount
        else
            header = header .. " " .. amount
        end
    end

    return header
end

--- Builds the default header from live session state. The chat panel gets the
--- rich provider/model/mode/usage/cost line. Every other panel (including
--- input, whose `parts.suffix` carries the mode-aware submit/change-mode
--- hints), and any panel with a nil session_state, falls back to the plain
--- title|context|suffix concatenation.
--- @param window_name string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @param session_state agentic.acp.SessionState|nil
--- @return string header_text
function WindowDecoration._build_default_header(
    window_name,
    parts,
    session_state
)
    if session_state == nil then
        return concat_header_parts(parts)
    end

    if window_name == "chat" then
        return build_chat_header(parts, session_state)
    end

    return concat_header_parts(parts)
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

--- Calls a user-supplied function expected to return `string|nil`, capturing
--- runtime errors and type violations as a formatted message.
--- @param fn fun(...): any User function to call
--- @param arg any First argument passed to the function
--- @param label string Identifier (e.g. "custom header"/"buffer_name") for error text
--- @param name string Window name for error text
--- @param extra_arg any Second argument passed to the function (session_state, nil allowed)
--- @return string|nil result The returned string, or nil on error/nil-return
--- @return string|nil error_message Formatted error, or nil when valid
local function call_string_fn(fn, arg, label, name, extra_arg)
    local ok, result = pcall(fn, arg, extra_arg)
    if not ok then
        return nil,
            string.format(
                "Error in %s function for '%s': %s",
                label,
                name,
                result
            )
    end
    if result == nil then
        return nil, nil
    end
    if type(result) ~= "string" then
        return nil,
            string.format(
                "%s function for '%s' must return string|nil, got %s",
                label,
                name,
                type(result)
            )
    end
    return result, nil
end

--- Resolves the final header text applying user customization
--- Returns the header text and an error message if user function failed
--- @param dynamic_header agentic.ui.ChatWidget.HeaderParts Runtime header parts
--- @param window_name string Window name for Config.headers lookup and error messages
--- @param session_state agentic.acp.SessionState|nil Live session state passed as 2nd arg to user header fn
--- @return string|nil header_text The resolved header text or nil for empty
--- @return string|nil error_message Error message if user function failed
local function resolve_header_text(dynamic_header, window_name, session_state)
    local user_header = Config.headers and Config.headers[window_name]
    -- No user customization: build the default header (rich for chat/input
    -- when a session is live, plain concat otherwise)
    if user_header == nil then
        return WindowDecoration._build_default_header(
            window_name,
            dynamic_header,
            session_state
        ),
            nil
    end

    -- User function: call it and validate return
    if type(user_header) == "function" then
        local result, err = call_string_fn(
            user_header,
            dynamic_header,
            "custom header",
            window_name,
            session_state
        )
        if err then
            return concat_header_parts(dynamic_header), err
        end
        if result == nil or result == "" then
            return nil, nil -- User explicitly wants no header
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
        vim.wo[winid][0].winbar = ""
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

    vim.wo[winid][0].winbar = winbar_text
end

--- Returns a normalized path comparable across nvim's stored buffer
--- names and the input given to `nvim_buf_set_name`. nvim resolves
--- symlinks and prefixes the cwd; we mirror both.
--- @param name string
--- @return string
local function normalize(name)
    return vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
end

--- Returns the buffer that would collide with `name` on
--- `nvim_buf_set_name`, or nil. Excludes `bufnr` itself so callers
--- can use the result to decide whether to rename a different buffer.
--- @param name string
--- @param exclude_bufnr integer|nil
--- @return integer|nil
local function find_buf_by_name(name, exclude_bufnr)
    local target = normalize(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= exclude_bufnr then
            local existing = vim.api.nvim_buf_get_name(b)
            if existing ~= "" and normalize(existing) == target then
                return b
            end
        end
    end
    return nil
end

--- Assigns `buf_name` to `bufnr`, renaming any pre-existing buffer
--- that already holds the name to `<buf_name>-old-N` (lowest free N
--- starting at 1) to keep names unique.
--- Required to survive session restore: `:mksession` (with `blank` in
--- `sessionoptions`) persists agentic buffer names; on reopen
--- `nvim_buf_set_name` would otherwise raise E95.
--- @param bufnr integer
--- @param buf_name string
function WindowDecoration._set_buffer_name(bufnr, buf_name)
    if normalize(vim.api.nvim_buf_get_name(bufnr)) == normalize(buf_name) then
        return
    end

    local collider = find_buf_by_name(buf_name, bufnr)
    local n = 1

    while collider do
        local candidate = buf_name .. "-old-" .. n
        if not find_buf_by_name(candidate, bufnr) then
            vim.api.nvim_buf_set_name(collider, candidate)
            break
        end
        n = n + 1
    end

    vim.api.nvim_buf_set_name(bufnr, buf_name)
end

--- Resolves the buffer name from config, supporting string or function values
--- @param window_name string Window name for Config.windows[name].buffer_name lookup
--- @param header_parts agentic.ui.ChatWidget.HeaderParts Header parts passed to function-type buffer_name
--- @param fallback string|nil Fallback name (resolved header text) when buffer_name is not set
--- @param session_state agentic.acp.SessionState|nil Live session state passed as 2nd arg to user buffer_name fn
--- @return string|nil name
local function resolve_buffer_name(
    window_name,
    header_parts,
    fallback,
    session_state
)
    local win_cfg = Config.windows[window_name]
    local buffer_name = win_cfg and win_cfg.buffer_name

    if buffer_name == nil then
        return fallback
    end

    if type(buffer_name) == "string" then
        return buffer_name
    end

    if type(buffer_name) == "function" then
        local result, err = call_string_fn(
            buffer_name,
            header_parts,
            "buffer_name",
            window_name,
            session_state
        )
        if err then
            Logger.notify(err)
        end
        if result == nil then
            return fallback
        end
        return result
    end

    Logger.notify(
        string.format(
            "buffer_name for '%s' must be string|function|nil, got %s",
            window_name,
            type(buffer_name)
        )
    )
    return fallback
end

--- Sets the buffer name based on header text and tab count
--- @param bufnr integer Buffer number
--- @param header_text string|nil Resolved header text
--- @param tab_page_id integer Tab page ID for suffix
--- @param window_name string Window name for Config.windows[name].buffer_name lookup
--- @param header_parts agentic.ui.ChatWidget.HeaderParts Header parts for function-type buffer_name
--- @param session_state agentic.acp.SessionState|nil Live session state passed as 2nd arg to user buffer_name fn
local function set_buffer_name(
    bufnr,
    header_text,
    tab_page_id,
    window_name,
    header_parts,
    session_state
)
    local name = resolve_buffer_name(
        window_name,
        header_parts,
        header_text,
        session_state
    )
    if not name or name == "" then
        return
    end

    -- Determine if we should show tab suffix based on total tab count
    local total_tabs = #vim.api.nvim_list_tabpages()

    --- @type string
    local buf_name
    if total_tabs > 1 then
        buf_name = string.format("%s (Tab %d)", name, tab_page_id)
    else
        buf_name = name
    end

    WindowDecoration._set_buffer_name(bufnr, buf_name)
end

--- Renders a header for a window, handling user customization, winbar, and buffer naming
--- Derives all context from bufnr: winid, tab_page_id, and dynamic header from vim.t
--- @param bufnr integer Buffer number - stable reference to derive window and tab context
--- @param window_name string Name of the window (for Config.headers lookup and error messages)
--- @param context string|nil Optional context to set in header (e.g., "Mode: chat", "3 files")
--- @param session_state agentic.acp.SessionState|nil Live session state forwarded to chat/input header/buffer_name callbacks as their 2nd arg
function WindowDecoration.render_header(
    bufnr,
    window_name,
    context,
    session_state
)
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

        local callback_session_state = nil
        if window_name == "chat" or window_name == "input" then
            callback_session_state = session_state
        end

        local header_text, err = resolve_header_text(
            dynamic_header,
            window_name,
            callback_session_state
        )

        if err then
            Logger.notify(err)
        end

        local text = (header_text and header_text ~= "") and header_text or ""

        set_winbar(winid, text)
        -- Buffer name mirrors the header title, not the rich winbar text:
        -- the rich format embeds "/" and "$" which corrupt buffer basenames.
        set_buffer_name(
            bufnr,
            concat_header_parts(dynamic_header),
            tab_page_id,
            window_name,
            dynamic_header,
            callback_session_state
        )
    end)
end

return WindowDecoration
