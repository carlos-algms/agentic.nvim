local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.open(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        session.widget:show(opts)
    end)
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:hide()
    end)
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.toggle(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.widget:is_open() then
            session.widget:hide()
        else
            if not opts or opts.auto_add_to_context ~= false then
                session:add_selection_or_file_to_session()
            end

            session.widget:show(opts)
        end
    end)
end

--- Rotates through predefined window layouts for the chat widget
--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function Agentic.rotate_layout(layouts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:rotate_layout(layouts)
    end)
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_to_session()
        session.widget:show(opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_file_to_session()
        session.widget:show(opts)
    end)
end

--- Add a list of file paths or buffer numbers to the Chat context
--- You can add 1 or more in a single call
--- @param opts agentic.ui.ChatWidget.AddFilesToContextOpts
function Agentic.add_files_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
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

        session.widget:show(opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        session.widget:show(opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.ui.ChatWidget.ShowOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Destroys the current Chat session and starts a new one
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    if opts and opts.provider then
        Config.provider = opts.provider
    end

    local session = SessionRegistry.new_session()
    if session then
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts)
    end
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        -- Guard: reject if session is being created or generating
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

        -- Save state before destroying
        Logger.debug(
            "apply_provider_switch: saving "
                .. tostring(#session.chat_history.messages)
                .. " messages"
        )
        local saved_messages = session.chat_history.messages
        local saved_files = session.file_list:get_files()
        local saved_selections = session.code_selection:get_selections()
        local widget_was_open = session.widget:is_open()
        local tab_page_id = session.tab_page_id

        -- Validate new provider exists BEFORE destroying old session
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

        -- Destroy old session
        Logger.debug("apply_provider_switch: destroying old session")
        SessionRegistry.destroy_session(tab_page_id)

        -- Update config for new session
        Config.provider = provider_name

        -- Create new session via registry
        Logger.debug("apply_provider_switch: creating new session")
        local new_session =
            SessionRegistry.get_session_for_tab_page(tab_page_id)
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
        -- Restore files and code selections immediately (don't wait for session ready)
        for _, file_path in ipairs(saved_files) do
            new_session.file_list:add(file_path)
        end
        for _, selection in ipairs(saved_selections) do
            new_session.code_selection:add(selection)
        end

        -- Register callback for when session is ready
        -- This waits for: agent ready -> session created -> welcome banner written
        new_session:on_session_ready(function(ready_session)
            Logger.debug(
                "Replaying "
                    .. tostring(#saved_messages)
                    .. " messages after provider switch"
            )

            -- Restore chat history and history_to_send for persistence
            -- Must be set here (not before) because new_session() clears history_to_send
            ready_session.chat_history.messages = saved_messages
            ready_session.history_to_send = saved_messages

            -- Replay messages visually in the chat buffer (after welcome header is written)
            ready_session.message_writer:replay_history_messages(saved_messages)
        end)

        -- Open widget immediately if it was open before
        if widget_was_open then
            new_session.widget:show()
        end
    end)
end

--- Switch to a different provider while preserving chat UI and history.
--- If opts.provider is set, switches directly. Otherwise shows a picker.
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

--- Stops the agent's current generation or tool execution
--- The session remains active and ready for the next prompt
--- Safe to call multiple times or when no generation is active
function Agentic.stop_generation()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.is_generating then
            session.agent:stop_generation(session.session_id)
            session.permission_manager:clear()
            session.is_generating = false
            session.status_animation:stop()
        end
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        SessionRestore.show_picker(session)
    end)
end

-- restore a session by it's ID.
-- @param session_id string: the ID of the session to restore.
function Agentic.restore_session_by_id(session_id)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        SessionRestore.restore_by_id(session, session_id)
    end)
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts agentic.PartialUserConfig
function Agentic.setup(opts)
    -- make sure invalid user config doesn't crash setup and leave things half-initialized
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

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
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

    -- Cleanup specific tab instance when tab is closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            SessionRegistry.destroy_session(tab_id)
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    if Config.image_paste.enabled then
        local function get_current_session()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            return SessionRegistry.sessions[tab_page_id]
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

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

return Agentic
