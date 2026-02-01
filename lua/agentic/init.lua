local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
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

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        session.widget:show(opts)
    end)
end

--- Destroys the current Chat session and starts a new one
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.new_session(opts)
    local session = SessionRegistry.new_session()
    if session then
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts)
    end
end

--- Stops the agent's current generation or tool execution
--- The session remains active and ready for the next prompt
--- Safe to call multiple times or when no generation is active
function Agentic.stop_generation()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.is_generating then
            session.agent:stop_generation(session.session_id)
            session.permission_manager:clear()
        end
    end)
end

--- @class agentic.RestoreSessionOpts
--- @field focus_prompt? boolean Focus the input prompt after restore (default: true)

function Agentic.restore_session()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local current_session = SessionRegistry.sessions[tab_page_id]

    -- Check for conflict: existing session with messages
    local has_conflict = current_session
        and current_session.session_id
        and current_session.chat_history
        and #current_session.chat_history.messages > 0

    local function do_restore(sid)
        ChatHistory.load(sid, function(history, err)
            if err or not history then
                Logger.notify(
                    "Failed to load session: " .. (err or "unknown error"),
                    vim.log.levels.WARN
                )
                return
            end

            SessionRegistry.get_session_for_tab_page(
                tab_page_id,
                function(session)
                    if not has_conflict then
                        -- Reuse current session, just replay messages
                        session:restore_from_history(
                            history,
                            { reuse_session = true }
                        )
                    else
                        -- Cancel existing session and create new one
                        if session.session_id then
                            session.agent:cancel_session(session.session_id)
                            session.widget:clear()
                        end
                        session:restore_from_history(history)
                    end

                    session.widget:show()
                end
            )
        end)
    end

    local function restore_with_conflict_check(sid)
        if has_conflict then
            vim.ui.select({
                "Cancel",
                "Clear current session and restore",
            }, {
                prompt = "Current session has messages. What would you like to do?",
            }, function(choice)
                if choice == "Clear current session and restore" then
                    do_restore(sid)
                end
            end)
        else
            do_restore(sid)
        end
    end

    ChatHistory.list_sessions(function(sessions)
        if #sessions == 0 then
            Logger.notify("No saved sessions found", vim.log.levels.INFO)
            return
        end

        table.sort(sessions, function(a, b)
            return (a.timestamp or 0) > (b.timestamp or 0)
        end)

        local items = {}
        for _, s in ipairs(sessions) do
            local date = os.date("%Y-%m-%d %H:%M", s.timestamp or 0)
            local title = s.title or "(no title)"

            table.insert(items, {
                display = string.format("%s - %s", date, title),
                session_id = s.session_id,
            })
        end

        vim.ui.select(items, {
            prompt = "Select session to restore:",
            format_item = function(item)
                return item.display
            end,
        }, function(choice)
            if choice then
                restore_with_conflict_check(choice.session_id)
            end
        end)
    end)
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts agentic.UserConfig
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
        require("agentic.ui.clipboard").setup({
            is_widget_open = function()
                local tab_page_id = vim.api.nvim_get_current_tabpage()
                local session = SessionRegistry.sessions[tab_page_id]
                if session then
                    return session.widget:is_open()
                end
                return false
            end,
            on_paste = function(file_path)
                local tab_page_id = vim.api.nvim_get_current_tabpage()
                local session = SessionRegistry.sessions[tab_page_id]

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
