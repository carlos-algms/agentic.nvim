local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WidgetLayout.Params
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field focus_prompt? boolean

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
        return math.max(1, pct and math.floor(max_dimension * pct / 100) or 0)
    end

    if size > 0 and size < 1 then
        return math.max(1, math.floor(max_dimension * size))
    end

    return math.max(1, size)
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

--- @param bufnr integer
--- @param max_height integer
--- @return integer
local function calculate_dynamic_height(bufnr, max_height)
    max_height = math.max(1, max_height)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    return math.min(line_count + 1, max_height)
end

--- @param position "right"|"bottom"
--- @return table<string, any>
local function get_chat_window_opts(position)
    --- @type table<string, any>
    local win_opts = {
        scrolloff = 4,
        winfixheight = position == "bottom",
        winfixwidth = true,
    }

    return win_opts
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
        style = "minimal",
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = true,
        linebreak = true,
        winfixbuf = true,
        winfixheight = true,
    }, win_opts or {}, config_win_opts)

    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(name, value, { win = winid })
    end

    return winid
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param panel_name string
--- @param bufnr integer
--- @param enter boolean
--- @param open_opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @return integer
local function get_or_create_window(
    win_nrs,
    panel_name,
    bufnr,
    enter,
    open_opts,
    win_opts
)
    local cached_winid = win_nrs[panel_name]
    if cached_winid and vim.api.nvim_win_is_valid(cached_winid) then
        return cached_winid
    end

    local new_winid =
        open_win(bufnr, enter, open_opts, panel_name, win_opts or {})
    win_nrs[panel_name] = new_winid
    WindowDecoration.render_header(bufnr, panel_name)
    return new_winid
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param open_win_opts vim.api.keyset.win_config
--- @param max_height integer
local function open_or_resize_dynamic_window(
    buf_nrs,
    win_nrs,
    window_name,
    open_win_opts,
    max_height
)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if BufHelpers.is_buffer_empty(bufnr) then
        if winid and vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end
        win_nrs[window_name] = nil
        return
    end

    local height = calculate_dynamic_height(bufnr, max_height)

    if not winid or not vim.api.nvim_win_is_valid(winid) then
        open_win_opts.height = height
        win_nrs[window_name] =
            open_win(bufnr, false, open_win_opts, window_name, {})
    else
        vim.api.nvim_win_set_config(winid, { height = height })
    end

    WindowDecoration.render_header(bufnr, window_name)
end

--- @param params agentic.ui.WidgetLayout.Params
local function show_right_layout(params)
    local should_focus = (
        params.focus_prompt == nil and true or params.focus_prompt
    ) == true

    get_or_create_window(params.win_nrs, "chat", params.buf_nrs.chat, false, {
        width = WidgetLayout.calculate_width(Config.windows.width),
    }, get_chat_window_opts("right"))

    get_or_create_window(
        params.win_nrs,
        "input",
        params.buf_nrs.input,
        should_focus,
        {
            win = params.win_nrs.chat,
            split = "below",
            height = Config.windows.input.height,
            fixed = true,
        },
        {}
    )

    open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "code", {
        win = params.win_nrs.chat,
        split = "below",
    }, Config.windows.code.max_height)

    open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "files", {
        win = params.win_nrs.input,
        split = "above",
    }, Config.windows.files.max_height)

    if Config.windows.todos.display then
        open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "todos", {
            win = params.win_nrs.chat,
            split = "below",
        }, Config.windows.todos.max_height)
    end

    if should_focus then
        vim.schedule(function()
            local winid = params.win_nrs.input
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_set_current_win(winid)
                BufHelpers.start_insert_on_last_char()
            end
        end)
    end
end

--- @param params agentic.ui.WidgetLayout.Params
local function show_bottom_layout(params)
    local should_focus = (
        params.focus_prompt == nil and true or params.focus_prompt
    ) == true

    get_or_create_window(params.win_nrs, "chat", params.buf_nrs.chat, false, {
        split = "below",
        win = -1,
        height = WidgetLayout.calculate_height(Config.windows.height),
    }, get_chat_window_opts("bottom"))

    local chat_width = vim.api.nvim_win_get_width(params.win_nrs.chat)
    local ratio = tonumber(Config.windows.stack_width_ratio) or 0.4
    local raw_width = math.floor(chat_width * ratio)
    local stack_width = math.max(1, math.min(raw_width, chat_width - 1))

    get_or_create_window(
        params.win_nrs,
        "input",
        params.buf_nrs.input,
        should_focus,
        {
            win = params.win_nrs.chat,
            split = "right",
            width = stack_width,
            fixed = true,
        },
        {}
    )

    open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "code", {
        win = params.win_nrs.input,
        split = "below",
    }, Config.windows.code.max_height)

    local ref_win = params.win_nrs.code or params.win_nrs.input
    open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "files", {
        win = ref_win,
        split = "below",
    }, Config.windows.files.max_height)

    ref_win = params.win_nrs.files
        or params.win_nrs.code
        or params.win_nrs.input

    if Config.windows.todos.display then
        open_or_resize_dynamic_window(params.buf_nrs, params.win_nrs, "todos", {
            win = ref_win,
            split = "below",
        }, Config.windows.todos.max_height)
    end

    if should_focus then
        vim.schedule(function()
            local winid = params.win_nrs.input
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_set_current_win(winid)
                BufHelpers.start_insert_on_last_char()
            end
        end)
    end
end

--- @param params agentic.ui.WidgetLayout.Params
function WidgetLayout.open(params)
    if
        not params.tab_page_id
        or not vim.api.nvim_tabpage_is_valid(params.tab_page_id)
    then
        Logger.notify(
            "Invalid tab_page_id in WidgetLayout.open: "
                .. tostring(params.tab_page_id),
            vim.log.levels.ERROR
        )
        return
    end

    local current_position = Config.windows.position

    local layout_fns = {
        right = show_right_layout,
        bottom = show_bottom_layout,
    }

    local layout_fn = layout_fns[current_position]

    if layout_fn then
        local ok, err = pcall(layout_fn, params)
        if not ok then
            Logger.notify(
                string.format(
                    "Failed to show %s layout (tab: %d): %s",
                    current_position,
                    params.tab_page_id,
                    tostring(err)
                ),
                vim.log.levels.ERROR
            )
        end
    else
        Logger.notify(
            "Invalid windows.position config: "
                .. tostring(Config.windows.position),
            vim.log.levels.ERROR
        )
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
function WidgetLayout.close(win_nrs)
    for name, winid in pairs(win_nrs) do
        win_nrs[name] = nil
        local ok = pcall(vim.api.nvim_win_close, winid, true)
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to close window '%s' with id: %d",
                    name,
                    winid
                )
            )
        end
    end
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
function WidgetLayout.resize_dynamic_window(buf_nrs, win_nrs, window_name)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if BufHelpers.is_buffer_empty(bufnr) then
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        win_nrs[window_name] = nil
        return
    end

    if winid and vim.api.nvim_win_is_valid(winid) then
        local window_config = Config.windows[window_name] or {}
        local max_height = window_config.max_height or 10

        local new_height = calculate_dynamic_height(bufnr, max_height)

        vim.api.nvim_win_set_config(winid, {
            height = new_height,
        })
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
function WidgetLayout.close_optional_window(win_nrs, window_name)
    local winid = win_nrs[window_name]
    if winid and vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
    win_nrs[window_name] = nil
end

return WidgetLayout
