local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local Fold = require("agentic.ui.tool_call_fold")
local ToolBlockBorder = require("agentic.ui.tool_block_border")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WidgetLayout.Params
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field focus_prompt? boolean
--- @field position agentic.UserConfig.Windows.Position
--- @field size? agentic.ui.ChatWidget.Size Overrides the configured size on this layout's axis
--- @field with_programmatic_close? fun(fn: fun())

--- @class agentic.ui.WidgetLayout
local WidgetLayout = {}

--- @param size number|string
--- @param max_dimension integer
--- @param default_percentage number|string
--- @return integer
local function calculate_dimension(size, max_dimension, default_percentage)
    size = size or default_percentage

    if type(size) == "string" then
        local pct = string.sub(size, -1) == "%"
            and tonumber(string.sub(size, 1, -2))
        if not pct then
            Logger.notify(
                "Invalid size string: "
                    .. size
                    .. ", expected format like '40%'",
                vim.log.levels.WARN
            )

            return calculate_dimension(
                default_percentage,
                max_dimension,
                default_percentage
            )
        end
        return math.max(1, math.floor(max_dimension * pct / 100))
    end

    if size > 0 and size < 1 then
        return math.max(1, math.floor(max_dimension * size))
    end

    return math.max(1, math.floor(size))
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_width(size)
    return calculate_dimension(size, vim.o.columns, DefaultConfig.windows.width)
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_height(size)
    return calculate_dimension(size, vim.o.lines, DefaultConfig.windows.height)
end

--- Falls back to the buffer line count when the API rejects the window (e.g. zero width during construction).
--- @param winid integer
--- @param bufnr integer
--- @return integer
local function visual_row_count(winid, bufnr)
    local ok, result = pcall(vim.api.nvim_win_text_height, winid, {})
    if ok and type(result) == "table" and type(result.all) == "number" then
        return result.all
    end
    return vim.api.nvim_buf_line_count(bufnr)
end

--- @param winid integer
--- @param bufnr integer
--- @param max_height integer
--- @param position agentic.UserConfig.Windows.Position
--- @return integer
local function calculate_dynamic_height(winid, bufnr, max_height, position)
    max_height = math.max(1, max_height)
    local rows = visual_row_count(winid, bufnr)
    -- 2 in bottom layout keeps the panel off the screen edge.
    local padding = position == "bottom" and 2 or 1
    return math.min(rows + padding, max_height)
end

-- Blends the statuscolumn gutter into the chat background whatever the colorscheme.
local CHAT_GUTTER_WINHIGHLIGHT = "EndOfBuffer:"
    .. ",LineNr:Normal,CursorLineNr:Normal"
    .. ",SignColumn:Normal,CursorLineSign:Normal"
    .. ",FoldColumn:Normal,CursorLineFold:Normal"

--- @type table<string, any>
local PANEL_WINDOW_OPTS = {
    number = false,
    relativenumber = false,
    cursorline = false,
    cursorcolumn = false,
    foldcolumn = "0",
    spell = false,
    list = false,
    signcolumn = "no",
    colorcolumn = "",
    statuscolumn = "",
    fillchars = "eob: ,fold: ",
    winhighlight = "EndOfBuffer:",
}

--- @param winid integer
--- @param bufnr integer
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param win_opts table<string, any>
local function apply_panel_window_opts(winid, bufnr, window_name, win_opts)
    -- Read by BufferGuard to resolve the window's rightful buffer.
    vim.w[winid].agentic_bufnr = bufnr

    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = true,
        linebreak = true,
        winfixheight = true,
    }, PANEL_WINDOW_OPTS, win_opts or {}, config_win_opts)

    -- `[0]` is the `:setlocal` sentinel; without it these leak to buffers that later cohabit the window.
    for name, value in pairs(merged_win_opts) do
        vim.wo[winid][0][name] = value
    end
end

--- @param bufnr integer
--- @param enter boolean
--- @param opts vim.api.keyset.win_config
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param win_opts table<string, any>
--- @return integer
local function open_win(bufnr, enter, opts, window_name, win_opts)
    --- @type vim.api.keyset.win_config
    local default_opts = {
        split = "right",
        win = -1,
        noautocmd = true,
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    apply_panel_window_opts(winid, bufnr, window_name, win_opts)

    return winid
end

--- Reusable only in the CURRENT tabpage: a handle from another tab renders nothing
--- where the user is looking, and splits one widget's topology across two tabs.
--- @param winid integer|nil
--- @return boolean
local function is_in_current_tabpage(winid)
    if not BufHelpers.is_win_usable(winid) then
        return false
    end

    ---@cast winid integer
    return vim.api.nvim_win_get_tabpage(winid)
        == vim.api.nvim_get_current_tabpage()
end

--- @param winid integer|nil
--- @param with_programmatic_close fun(fn: fun())|nil
local function close_layout_window(winid, with_programmatic_close)
    if not BufHelpers.is_win_usable(winid) then
        return
    end

    ---@cast winid integer
    local function close()
        vim.api.nvim_win_close(winid, true)
    end

    if with_programmatic_close then
        with_programmatic_close(close)
    else
        pcall(close)
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param panel_name string
--- @param bufnr integer
--- @param open_opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @param with_programmatic_close fun(fn: fun())|nil
--- @return integer
local function get_or_create_window(
    win_nrs,
    panel_name,
    bufnr,
    open_opts,
    win_opts,
    with_programmatic_close
)
    local cached_winid = win_nrs[panel_name]
    if is_in_current_tabpage(cached_winid) then
        ---@cast cached_winid integer
        return cached_winid
    end

    -- A stale handle from another tab would otherwise be left untracked once
    -- `win_nrs` is repointed, showing a second copy of the widget in the tab
    -- the user left.
    close_layout_window(cached_winid, with_programmatic_close)

    local new_winid =
        open_win(bufnr, false, open_opts, panel_name, win_opts or {})
    win_nrs[panel_name] = new_winid
    WindowDecoration.render_header(bufnr, panel_name)
    return new_winid
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param open_win_opts vim.api.keyset.win_config
--- @param max_height integer
--- @param position agentic.UserConfig.Windows.Position
--- @param with_programmatic_close fun(fn: fun())|nil
local function open_or_resize_dynamic_window(
    buf_nrs,
    win_nrs,
    window_name,
    open_win_opts,
    max_height,
    position,
    with_programmatic_close
)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if BufHelpers.is_buffer_empty(bufnr) then
        close_layout_window(winid, with_programmatic_close)
        win_nrs[window_name] = nil
        return
    end

    if not is_in_current_tabpage(winid) then
        -- A stale handle from another tab would otherwise be left untracked
        -- once `win_nrs` is repointed at the new window.
        close_layout_window(winid, with_programmatic_close)

        -- Opened at min height so wrapped rows can be measured against the real
        -- window width, then resized; a buffer-line count understates wraps.
        open_win_opts.height = 1
        winid = open_win(bufnr, false, open_win_opts, window_name, {})
        win_nrs[window_name] = winid
    end

    ---@cast winid integer
    local height = calculate_dynamic_height(winid, bufnr, max_height, position)
    vim.api.nvim_win_set_config(winid, { height = height })

    WindowDecoration.render_header(bufnr, window_name)
end

--- @param params agentic.ui.WidgetLayout.Params
--- @param position agentic.UserConfig.Windows.Position
local function show_layout(params, position)
    local is_bottom = position == "bottom"
    local win_nrs = params.win_nrs
    local buf_nrs = params.buf_nrs
    local with_close = params.with_programmatic_close
    local should_focus = params.focus_prompt == nil
        or params.focus_prompt == true

    local split_direction = is_bottom and "below"
        or (position == "left" and "left" or "right")

    --- @type vim.api.keyset.win_config
    local chat_opts = {
        win = -1,
        split = split_direction,
    }

    local size = params.size or {}

    if is_bottom then
        chat_opts.height = size.height
            or WidgetLayout.calculate_height(Config.windows.height)
    else
        chat_opts.width = size.width
            or WidgetLayout.calculate_width(Config.windows.width)
    end

    get_or_create_window(win_nrs, "chat", buf_nrs.chat, chat_opts, {
        scrolloff = 4,
        statuscolumn = ToolBlockBorder.STATUSCOLUMN_EXPR,
        winhighlight = CHAT_GUTTER_WINHIGHLIGHT,
        winfixheight = is_bottom,
        winfixwidth = not is_bottom,
    }, with_close)

    Fold.setup_window(win_nrs.chat, buf_nrs.chat)

    --- @type vim.api.keyset.win_config
    local input_opts = { win = win_nrs.chat, fixed = true }
    if is_bottom then
        local chat_width = vim.api.nvim_win_get_width(win_nrs.chat)
        local ratio = tonumber(Config.windows.stack_width_ratio) or 0.4
        local raw_width = math.floor(chat_width * ratio)
        input_opts.split = "right"
        input_opts.width = math.max(1, math.min(raw_width, chat_width - 1))
    else
        input_opts.split = "below"
        input_opts.height = Config.windows.input.height
    end

    get_or_create_window(win_nrs, "input", buf_nrs.input, input_opts, {
        winfixheight = not is_bottom,
    }, with_close)

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "code", {
        win = is_bottom and win_nrs.input or win_nrs.chat,
        split = "below",
    }, Config.windows.code.max_height, position, with_close)

    local ref_win = is_bottom and (win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "files", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.files.max_height, position, with_close)

    ref_win = is_bottom and (win_nrs.files or win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "diagnostics", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.diagnostics.max_height, position, with_close)

    if Config.windows.todos.display then
        ref_win = is_bottom
                and (win_nrs.diagnostics or win_nrs.files or win_nrs.code or win_nrs.input)
            or win_nrs.chat

        open_or_resize_dynamic_window(buf_nrs, win_nrs, "todos", {
            win = ref_win,
            split = "below",
        }, Config.windows.todos.max_height, position, with_close)
    end

    if should_focus then
        vim.schedule(function()
            local winid = win_nrs.input
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_set_current_win(winid)
                BufHelpers.start_insert_on_last_char()
            end
        end)
    end
end

--- @param bufnr integer Chat buffer
--- @return integer|nil winid nil on failure (graceful degradation)
function WidgetLayout.open_hidden_chat_window(bufnr)
    -- The CONFIGURED width, not the visible chat's real one, so
    -- `nvim_win_text_height` has a stable basis while hidden (ADR 0001).
    local width = WidgetLayout.calculate_width(Config.windows.width)

    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = width,
        height = 20,
        hide = true,
        focusable = false,
        noautocmd = true,
    })

    if not ok or type(winid) ~= "number" then
        Logger.debug("open_hidden_chat_window failed: " .. tostring(winid))
        return nil
    end

    vim.wo[winid][0].winbar = ""

    apply_panel_window_opts(winid, bufnr, "chat", {
        statuscolumn = ToolBlockBorder.STATUSCOLUMN_EXPR,
    })

    Fold.setup_window(winid, bufnr)

    return winid
end

--- @param params agentic.ui.WidgetLayout.Params
function WidgetLayout.open(params)
    local position = params.position

    if position ~= "right" and position ~= "left" and position ~= "bottom" then
        Logger.notify(
            "Invalid windows.position config: "
                .. tostring(position)
                .. ', falling back to "right"',
            vim.log.levels.ERROR
        )

        position = "right"
    end

    local ok, err = pcall(show_layout, params, position)
    if not ok then
        Logger.notify(
            string.format(
                "Failed to show %s layout: %s",
                position,
                tostring(err)
            ),
            vim.log.levels.ERROR
        )
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
function WidgetLayout.close(win_nrs)
    for name, winid in pairs(win_nrs) do
        win_nrs[name] = nil
        -- `is_win_usable`, not bare validity: on 0.11.5 Linux tabclose leaves
        -- handles that answer valid but segfault in `nvim_win_close`.
        if BufHelpers.is_win_usable(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param position agentic.UserConfig.Windows.Position
function WidgetLayout.close_optional_window(win_nrs, window_name, position)
    local winid = win_nrs[window_name]

    -- In bottom layout Neovim redistributes the freed height to siblings.
    local chat_winid = win_nrs.chat
    local chat_height = nil
    if position == "bottom" and BufHelpers.is_win_usable(chat_winid) then
        ---@cast chat_winid integer
        chat_height = vim.api.nvim_win_get_height(chat_winid)
    end

    if BufHelpers.is_win_usable(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
    win_nrs[window_name] = nil

    if chat_height then
        ---@cast chat_winid integer
        vim.api.nvim_win_set_config(chat_winid, { height = chat_height })
    end
end

return WidgetLayout
