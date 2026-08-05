local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- @param session agentic.SessionManager
--- @return boolean destroyed
local function is_destroyed(session)
    --- @diagnostic disable-next-line: invisible
    return session._destroyed
end

--- The `Config.acp_providers` key the session's agent was built from.
--- Restore is provider-local: an ACP session ID only means anything to the agent that
--- issued it, and `SessionRegistry.create` otherwise picks up the global `Config.provider`.
--- Matched on config-table identity: `provider_config` carries a display `name`, not the
--- key `Config.acp_providers` is indexed by.
--- @param session agentic.SessionManager
--- @return agentic.UserConfig.ProviderName|nil provider_name
local function provider_of(session)
    local provider_config = session.agent and session.agent.provider_config

    if not provider_config then
        return nil
    end

    for provider_name, candidate in pairs(Config.acp_providers) do
        if candidate == provider_config then
            return provider_name
        end
    end

    return nil
end

--- @param bufnr integer|nil
--- @return boolean is_blank
local function input_is_blank(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return true
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    return vim.trim(table.concat(lines, "")) == ""
end

--- No conversation AND no staged context: files, selections, diagnostics, input.
--- @param session agentic.SessionManager
--- @return boolean is_empty
local function is_empty(session)
    return #session.chat_history.messages == 0
        and session.file_list:is_empty()
        and session.code_selection:is_empty()
        and session.diagnostics_list:is_empty()
        and input_is_blank(session.widget.buf_nrs.input)
end

--- Restores into a new session, destroying the resolved one only when it is empty.
--- @param current_session agentic.SessionManager
--- @param session_id string
--- @param title string|nil
--- @param timestamp string|nil
local function restore_into_new_session(
    current_session,
    session_id,
    title,
    timestamp
)
    if is_destroyed(current_session) then
        return
    end

    local caps = current_session.agent.agent_capabilities

    if not caps or not caps.loadSession then
        Logger.notify(
            "Agent does not support loading sessions",
            vim.log.levels.WARN
        )
        return
    end

    -- Already loaded locally: show it. Two managers on one ACP session ID collide in the
    -- client's subscriber map, and the newer one wins every update and permission prompt.
    local live = SessionRegistry.find_by_acp_session_id(
        session_id,
        current_session.agent
    )
    local live_key = live and live.session_key

    if live and live_key then
        SessionRegistry.show_session(live_key)
        if
            live ~= current_session
            and current_session.session_key
            and is_empty(current_session)
        then
            SessionRegistry.destroy(current_session.session_key)
        end
        return
    end

    local session = SessionRegistry.create(provider_of(current_session))
    local session_key = session and session.session_key

    if not session or not session_key then
        Logger.notify(
            "Could not create a session to restore into",
            vim.log.levels.ERROR
        )
        return
    end

    session:load_acp_session(session_id, title, timestamp)
    SessionRegistry.show_session(session_key)

    -- Destroyed LAST: the new widget's `show` inherits its size from this one.
    if current_session.session_key and is_empty(current_session) then
        SessionRegistry.destroy(current_session.session_key)
    end
end

--- @param current_session agentic.SessionManager
function SessionRestore.show_picker(current_session)
    if is_destroyed(current_session) then
        return
    end

    local cwd = vim.fn.getcwd()
    current_session.agent:when_ready(function()
        if is_destroyed(current_session) then
            return
        end

        current_session.agent:list_sessions(cwd, function(result, err)
            if is_destroyed(current_session) then
                return
            end

            if err or not result then
                Logger.notify(
                    "Failed to list sessions: "
                        .. (err and err.message or "unknown error"),
                    vim.log.levels.WARN
                )
                return
            end

            local sessions = result.sessions
            if not sessions or #sessions == 0 then
                Logger.notify("No saved sessions found", vim.log.levels.INFO)
                return
            end

            local items = {}
            for _, s in ipairs(sessions) do
                local date = s.updatedAt
                        and s.updatedAt:sub(1, 16):gsub("T", " ")
                    or "unknown date"
                local title = s.title or "(no title)"
                table.insert(items, {
                    display = string.format("%s - %s", date, title),
                    session_id = s.sessionId,
                    title = s.title,
                    updated_at = date,
                })
            end

            vim.schedule(function()
                if is_destroyed(current_session) then
                    return
                end

                vim.ui.select(items, {
                    prompt = "Select session to restore:",
                    format_item = function(item)
                        return item.display
                    end,
                }, function(choice)
                    if is_destroyed(current_session) or not choice then
                        return
                    end

                    restore_into_new_session(
                        current_session,
                        choice.session_id,
                        choice.title,
                        choice.updated_at
                    )
                end)
            end)
        end)
    end)
end

--- @param current_session agentic.SessionManager
--- @param session_id string
function SessionRestore.restore_by_id(current_session, session_id)
    if is_destroyed(current_session) then
        return
    end

    current_session.agent:when_ready(function()
        if is_destroyed(current_session) then
            return
        end

        vim.schedule(function()
            if is_destroyed(current_session) then
                return
            end

            restore_into_new_session(current_session, session_id, nil, nil)
        end)
    end)
end

return SessionRestore
