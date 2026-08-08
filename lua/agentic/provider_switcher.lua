local Config = require("agentic.config")
local SessionRegistry = require("agentic.session_registry")
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

local ProviderSwitcher = {}

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Logger.debug(
        "apply_provider_switch: starting for provider " .. provider_name
    )

    if not SessionRegistry.current() then
        require("agentic").new_session({ provider = provider_name })
        return
    end

    SessionRegistry.resolve_or_create(function(session)
        local source_session_id = session.session_id

        if not source_session_id then
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

        local session_key = session.session_key

        Logger.debug("apply_provider_switch: creating new session")
        local new_session = SessionRegistry.create(provider_name)
        if not new_session then
            Logger.notify(
                "Failed to create session for provider '"
                    .. provider_name
                    .. "'.",
                vim.log.levels.ERROR
            )
            return
        end

        local new_key = new_session.session_key

        if not new_key then
            return
        end

        -- The old session stays registered until the replacement ACP session is
        -- ready. A subprocess-level failure must not discard the user's transcript.
        new_session:on_session_ready(function(ready_session)
            if
                not session_key
                or SessionRegistry.sessions[session_key] ~= session
            then
                SessionRegistry.destroy(new_key)
                return
            end

            if not session:owns_ready_acp_session(source_session_id) then
                SessionRegistry.destroy(new_key)
                Logger.notify(
                    "Cannot switch provider: the source session changed. Try again.",
                    vim.log.levels.WARN
                )
                return
            end

            if session.is_generating then
                SessionRegistry.destroy(new_key)
                Logger.notify(
                    "Cannot switch provider while generating. Stop generation first.",
                    vim.log.levels.WARN
                )
                return
            end

            local saved_messages = session.chat_history.messages
            local saved_title = session.chat_history.title
            local saved_files = session.file_list:get_files()
            local saved_selections = session.code_selection:get_selections()
            local widget_was_open = session.widget:is_open()
            local widget_tab = widget_was_open
                    and session.widget:get_visible_tab_id()
                or nil

            Logger.debug(
                "apply_provider_switch: saving "
                    .. tostring(#saved_messages)
                    .. " messages"
            )
            Logger.debug("apply_provider_switch: destroying old session")
            SessionRegistry.destroy(session_key)
            Config.provider = provider_name

            for _, file_path in ipairs(saved_files) do
                ready_session.file_list:add(file_path)
            end
            for _, selection in ipairs(saved_selections) do
                ready_session.code_selection:add(selection)
            end

            Logger.debug(
                "Replaying "
                    .. tostring(#saved_messages)
                    .. " messages after provider switch"
            )

            ready_session.chat_history.messages = saved_messages
            ready_session.chat_history.title = saved_title
            ready_session.history_to_send = saved_messages

            ready_session.message_writer:replay_history_messages(saved_messages)

            if not widget_was_open then
                SessionRegistry.set_most_recent(new_key)
                return
            end

            -- Only the tab identity crosses the async create and teardown boundary.
            -- Resolve a live editor window again before rebuilding the widget.
            if
                not widget_tab or not vim.api.nvim_tabpage_is_valid(widget_tab)
            then
                SessionRegistry.set_most_recent(new_key)
                return
            end

            local live_anchor =
                session.widget:find_first_non_widget_window(widget_tab)

            if not live_anchor or not BufHelpers.is_win_usable(live_anchor) then
                SessionRegistry.set_most_recent(new_key)
                return
            end

            -- `focus_prompt = false`: the focus hop is scheduled inside `show_layout`
            -- and would drag the cursor into the anchor's tabpage.
            vim.api.nvim_win_call(live_anchor, function()
                SessionRegistry.show_session(new_key, { focus_prompt = false })
            end)
        end, function()
            if SessionRegistry.sessions[new_key] == new_session then
                SessionRegistry.destroy(new_key)
            end

            Logger.notify(
                "Failed to create session for provider '"
                    .. provider_name
                    .. "'.",
                vim.log.levels.ERROR
            )
        end)
    end)
end

--- Switch provider while preserving chat UI and history. No `opts.provider` shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function ProviderSwitcher.switch(opts)
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

return ProviderSwitcher
