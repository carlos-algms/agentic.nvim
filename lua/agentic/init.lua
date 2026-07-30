local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
local SessionNavigation = require("agentic.session_navigation")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- @class agentic.DestroySessionOpts
--- @field session? integer Session key to destroy; defaults to the resolved session

--- @param session agentic.SessionManager
--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
local function show_session(session, opts)
    local session_key = session.session_key

    if session_key then
        SessionRegistry.show_session(session_key, opts)
    end
end

--- Opens the chat widget in the current tab page
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.open(opts)
    SessionRegistry.resolve_or_create(function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        show_session(session, opts)
    end)
end

--- Hides the session visible in the current tab page
function Agentic.close()
    local session = SessionRegistry.visible_here()

    if session then
        session.widget:hide()
    end
end

--- Toggles the chat widget in the current tab page
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.toggle(opts)
    SessionRegistry.resolve_or_create(function(session)
        if
            session.widget:get_visible_tab_id()
            == vim.api.nvim_get_current_tabpage()
        then
            session.widget:hide()
        else
            if not opts or opts.auto_add_to_context ~= false then
                session:add_selection_or_file_to_session()
            end

            show_session(session, opts)
        end
    end)
end

--- Rotates the layout of the session visible in the current tab page
--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function Agentic.rotate_layout(layouts)
    local session = SessionRegistry.visible_here()

    if session then
        session.widget:rotate_layout(layouts)
    end
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    SessionRegistry.resolve_or_create(function(session)
        session:add_selection_to_session()
        show_session(session, opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    SessionRegistry.resolve_or_create(function(session)
        session:add_file_to_session()
        show_session(session, opts)
    end)
end

--- Add a list of file paths or buffer numbers to the Chat context
--- You can add 1 or more in a single call
--- @param opts agentic.ui.ChatWidget.AddFilesToContextOpts
function Agentic.add_files_to_context(opts)
    SessionRegistry.resolve_or_create(function(session)
        local files = opts.files

        if files and type(files) == "table" then
            for _, path in ipairs(files) do
                session:add_file_to_session(path)
            end
        else
            Logger.notify(
                "Wrong parameters passed to `add_files_to_context()`: "
                    .. vim.inspect(opts)
            )
        end

        show_session(session, opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.resolve_or_create(function(session)
        session:add_selection_or_file_to_session()
        show_session(session, opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.ui.ChatWidget.ShowOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    SessionRegistry.resolve_or_create(function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            show_session(session, opts)
        else
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_buffer_diagnostics(opts)
    SessionRegistry.resolve_or_create(function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            show_session(session, opts)
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Creates an additional Chat session after resolving the current one's lifecycle.
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    local provider = opts and opts.provider

    SessionRegistry.create_with_current_session_guard(function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        show_session(session, opts)
    end, provider)
end

--- Destroys a Chat session and its widget
--- @param opts agentic.DestroySessionOpts|nil
function Agentic.destroy_session(opts)
    local target = opts and opts.session

    if target then
        SessionRegistry.destroy(target)
        return
    end

    SessionRegistry.destroy_current()
end

--- Shows a picker over every live session and opens the chosen one
function Agentic.select_session()
    SessionNavigation.select()
end

--- Opens the session with the next higher key, wrapping at the end
function Agentic.next_session()
    SessionNavigation.next()
end

--- Opens the session with the next lower key, wrapping at the start
function Agentic.prev_session()
    SessionNavigation.previous()
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.new_session_with_provider(opts)
    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            local merged_opts = vim.tbl_deep_extend("force", opts or {}, {
                provider = provider_name,
            }) --[[@as agentic.ui.NewSessionOpts]]

            Agentic.new_session(merged_opts)
        end
    end)
end

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Logger.debug(
        "apply_provider_switch: starting for provider " .. provider_name
    )
    SessionRegistry.resolve_or_create(function(session)
        if not session.session_id then
            Logger.notify(
                "Cannot switch provider: session is initializing. Please wait.",
                vim.log.levels.WARN
            )
            return
        end

        if session.is_generating then
            Logger.notify(
                "Cannot switch provider while generating. Stop generation first.",
                vim.log.levels.WARN
            )
            return
        end

        Logger.debug(
            "apply_provider_switch: saving "
                .. tostring(#session.chat_history.messages)
                .. " messages"
        )
        local saved_messages = session.chat_history.messages
        local saved_files = session.file_list:get_files()
        local saved_selections = session.code_selection:get_selections()
        local widget_was_open = session.widget:is_open()
        local session_key = session.session_key
        -- Captured BEFORE the destroy, while the old widget still has windows.
        local anchor_win = widget_was_open
                and session.widget:find_first_non_widget_window()
            or nil

        -- Validated BEFORE destroying the old session.
        local ok, new_agent = pcall(
            AgentInstance.get_instance,
            provider_name,
            function() end
        )
        if not ok or not new_agent then
            Logger.notify(
                "Provider '" .. provider_name .. "' not available.",
                vim.log.levels.ERROR
            )
            return
        end

        Logger.debug("apply_provider_switch: destroying old session")
        if session_key then
            SessionRegistry.destroy(session_key)
        end

        Config.provider = provider_name

        Logger.debug("apply_provider_switch: creating new session")
        local new_session = SessionRegistry.create()
        if not new_session then
            Logger.notify(
                "Failed to create session for provider '"
                    .. provider_name
                    .. "'.",
                vim.log.levels.ERROR
            )
            return
        end

        Logger.debug(
            "apply_provider_switch: new_session created, session_id="
                .. tostring(new_session.session_id)
        )
        for _, file_path in ipairs(saved_files) do
            new_session.file_list:add(file_path)
        end
        for _, selection in ipairs(saved_selections) do
            new_session.code_selection:add(selection)
        end

        -- Set here, not earlier: `new_session()` clears `history_to_send`.
        new_session:on_session_ready(function(ready_session)
            Logger.debug(
                "Replaying "
                    .. tostring(#saved_messages)
                    .. " messages after provider switch"
            )

            ready_session.chat_history.messages = saved_messages
            ready_session.history_to_send = saved_messages

            ready_session.message_writer:replay_history_messages(saved_messages)
        end)

        local new_key = new_session.session_key

        if not new_key then
            return
        end

        if not widget_was_open then
            SessionRegistry.set_most_recent(new_key)
            return
        end

        -- `anchor_win` re-tested for LuaLS, which cannot narrow it through a boolean.
        local anchor_is_elsewhere = anchor_win ~= nil
            and vim.api.nvim_win_is_valid(anchor_win)
            and vim.api.nvim_win_get_tabpage(anchor_win)
                ~= vim.api.nvim_get_current_tabpage()

        if not anchor_win or not anchor_is_elsewhere then
            SessionRegistry.show_session(new_key)
            return
        end

        -- `focus_prompt = false`: the focus hop is scheduled inside `show_layout` and
        -- would drag the cursor into the anchor's tabpage.
        vim.api.nvim_win_call(anchor_win, function()
            SessionRegistry.show_session(new_key, { focus_prompt = false })
        end)
    end)
end

--- Switch provider while preserving chat UI and history. No `opts.provider` shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function Agentic.switch_provider(opts)
    if opts and opts.provider then
        apply_provider_switch(opts.provider)
        return
    end

    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            apply_provider_switch(provider_name)
        end
    end)
end

--- Stops the agent's current generation or tool execution, keeping the session alive
function Agentic.stop_generation()
    SessionRegistry.resolve_or_create(function(session)
        if session.is_generating and session.session_id then
            session.agent:stop_generation(session.session_id)
        end
        session.permission_manager:clear()
        session.is_generating = false
        session.status_animation:stop()
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    SessionRegistry.resolve_or_create(function(session)
        SessionRestore.show_picker(session)
    end)
end

--- Restore a session by its ID.
--- @param session_id string
function Agentic.restore_session_by_id(session_id)
    SessionRegistry.resolve_or_create(function(session)
        SessionRestore.restore_by_id(session, session_id)
    end)
end

--- Guards signal handlers and autocmds against a repeated `setup` call
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the user configuration with the defaults. Safe to call multiple times.
--- @param opts agentic.PartialUserConfig
function Agentic.setup(opts)
    -- An invalid user config must not leave setup half-initialized.
    local ok, err = pcall(function()
        Object.merge_config(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Agentic] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic: user config merge error" }
        )
    end

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

    Theme.setup()

    -- Agent edits always win: reload silently instead of prompting, as Cursor/Zed do.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = cleanup_group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    if Config.image_paste.enabled then
        local WidgetRegistry = require("agentic.ui.widget_registry")

        --- Never `resolve_or_create`: this runs on EVERY `vim.paste`.
        --- @return agentic.SessionManager|nil
        local function get_current_session()
            local widget = WidgetRegistry.get(vim.api.nvim_get_current_buf())
            local session_key = widget and widget.session_key

            return session_key and SessionRegistry.sessions[session_key] or nil
        end

        local Clipboard = require("agentic.ui.clipboard")

        Clipboard.setup({
            is_cursor_in_widget = function()
                local session = get_current_session()
                return session and session.widget:is_cursor_in_widget() or false
            end,
            on_paste = function(file_path)
                local session = get_current_session()

                if not session then
                    return false
                end

                local ret = session.file_list:add(file_path) or false

                if ret then
                    session.widget:show({
                        focus_prompt = false,
                    })
                end

                return ret
            end,
        })
    end

    -- sigint may not trigger in raw terminal mode.
    for _, signal in ipairs({ "sigterm", "sigint" }) do
        local handler = vim.uv.new_signal()

        if handler then
            vim.uv.signal_start(handler, signal, function(_sigName)
                AgentInstance:cleanup_all()
            end)
        end
    end
end

return Agentic
