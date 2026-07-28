--- Renders winbar headers and buffer names for widget windows.
--- Statusline plugins (lualine et al.) must list the `Agentic*` filetypes in
--- `disabled_filetypes`, or they hijack the winbar — see `set_winbar`.

local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local WidgetRegistry = require("agentic.ui.widget_registry")

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
--- @field align? "left"|"center"|"right"
--- @field hl? string Header text
--- @field reverse_hl? string Separator
local default_config = {
    align = "center",
    hl = Theme.HL_GROUPS.WIN_BAR_TITLE,
    reverse_hl = "NormalFloat",
}

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

--- `title | provider - model - mode (used/size) $cost`
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

--- Only the chat panel gets the rich line; everything else, and any panel with
--- no session_state, falls back to plain concatenation.
--- @param window_name string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @param session_state agentic.acp.SessionState|nil
--- @return string header_text
function WindowDecoration._build_default_header(
    window_name,
    parts,
    session_state
)
    if session_state == nil or window_name ~= "chat" then
        return concat_header_parts(parts)
    end

    return build_chat_header(parts, session_state)
end

--- A copy: callers mutate `context`, so the module default is never handed out.
--- @return agentic.ui.ChatWidget.Headers
function WindowDecoration.default_headers()
    return vim.deepcopy(WINDOW_HEADERS)
end

--- Mutated in place by callers. That persists only when a widget owns `bufnr`;
--- the unowned fallback returns a fresh copy each call.
--- @param bufnr integer
--- @return agentic.ui.ChatWidget.Headers
function WindowDecoration.get_headers_state(bufnr)
    local widget = WidgetRegistry.get(bufnr)
    if widget == nil then
        return WindowDecoration.default_headers()
    end
    return widget.headers
end

--- Calls a user-supplied function, turning errors and non-string returns into a
--- formatted message rather than raising.
--- @param fn fun(...): any
--- @param arg any
--- @param label string Identifier for error text, e.g. "custom header"
--- @param name string Window name for error text
--- @param extra_arg any
--- @return string|nil result nil on error or nil-return
--- @return string|nil error_message
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

--- @param dynamic_header agentic.ui.ChatWidget.HeaderParts
--- @param window_name string
--- @param session_state agentic.acp.SessionState|nil Passed as 2nd arg to a user header fn
--- @return string|nil header_text nil for empty
--- @return string|nil error_message
local function resolve_header_text(dynamic_header, window_name, session_state)
    local user_header = Config.headers and Config.headers[window_name]

    if user_header == nil then
        return WindowDecoration._build_default_header(
            window_name,
            dynamic_header,
            session_state
        ),
            nil
    end

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
            return nil, nil
        end
        return result, nil
    end

    if type(user_header) == "table" then
        local merged = vim.tbl_extend("force", dynamic_header, user_header) --[[@as agentic.ui.ChatWidget.HeaderParts]]
        return concat_header_parts(merged), nil
    end

    return concat_header_parts(dynamic_header),
        string.format(
            "Header for '%s' must be function|table|nil, got %s",
            window_name,
            type(user_header)
        )
end

--- @type boolean|nil
local has_line_plugin = nil

--- @param winid integer
--- @param text string
local function set_winbar(winid, text)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    -- A non-empty winbar means lualine or similar owns it; ours would flicker.
    if has_line_plugin == nil then
        local current_winbar = vim.wo[winid].winbar
        has_line_plugin = current_winbar ~= ""
    end

    if has_line_plugin then
        return
    end

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

--- Mirrors nvim's own symlink resolution and cwd prefixing, so a name can be
--- compared against a stored buffer name.
--- @param name string
--- @return string
local function normalize(name)
    return vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
end

--- The buffer that would collide with `name` on `nvim_buf_set_name`, or nil.
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

--- Renames any pre-existing holder of `buf_name` to `<buf_name>-old-N`.
--- Required because `:mksession` persists agentic buffer names, so a direct
--- `nvim_buf_set_name` raises E95 on reopen.
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

--- @param window_name string
--- @param header_parts agentic.ui.ChatWidget.HeaderParts
--- @param fallback string|nil Used when `buffer_name` is unset
--- @param session_state agentic.acp.SessionState|nil Passed as 2nd arg to a user fn
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

--- @param bufnr integer
--- @param header_text string|nil
--- @param session_key integer|nil nil when no session owns the buffer
--- @param window_name string
--- @param header_parts agentic.ui.ChatWidget.HeaderParts
--- @param session_state agentic.acp.SessionState|nil Passed as 2nd arg to a user fn
local function set_buffer_name(
    bufnr,
    header_text,
    session_key,
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

    -- Suffixed by session, not by tab: a session outlives its tab.
    local SessionRegistry = require("agentic.session_registry")
    local total_sessions = vim.tbl_count(SessionRegistry.sessions)

    --- @type string
    local buf_name = name
    if session_key and total_sessions > 1 then
        buf_name = string.format("%s (%d)", name, session_key)
    end

    WindowDecoration._set_buffer_name(bufnr, buf_name)
end

--- Everything, including the owning widget and its window, is derived from
--- `bufnr` — the only handle stable across hide/show.
--- @param bufnr integer
--- @param window_name string
--- @param context string|nil e.g. "Mode: chat", "3 files"
--- @param session_state agentic.acp.SessionState|nil Forwarded to chat/input callbacks as their 2nd arg
function WindowDecoration.render_header(
    bufnr,
    window_name,
    context,
    session_state
)
    vim.schedule(function()
        local owner = WidgetRegistry.get(bufnr)
        local headers = WindowDecoration.get_headers_state(bufnr)
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

        -- BEFORE the window lookup's early return: nothing re-supplies the
        -- context, so a background session's chat winbar lost `Mode: X`.
        if context ~= nil then
            dynamic_header.context = context
        end

        -- The owner's own window, or a copy the user opened elsewhere takes the winbar.
        local winid = BufHelpers.find_visible_win(
            bufnr,
            owner and owner.win_nrs[window_name] or nil
        )
        if winid == nil then
            return
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
        -- The plain title, not the rich winbar text, whose "/" and "$" corrupt buffer basenames.
        set_buffer_name(
            bufnr,
            concat_header_parts(dynamic_header),
            owner and owner.session_key or nil,
            window_name,
            dynamic_header,
            callback_session_state
        )
    end)
end

return WindowDecoration
