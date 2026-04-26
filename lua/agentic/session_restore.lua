local Logger = require("agentic.utils.logger")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Checks if the current session has messages or we can safely restore into it if it's empty
--- @param current_session agentic.SessionManager|nil
--- @return boolean has_conflict
local function check_conflict(current_session)
    return current_session ~= nil
        and current_session.session_id ~= nil
        and current_session.chat_history ~= nil
        and #current_session.chat_history.messages > 0
end

--- @param current_session agentic.SessionManager
--- @param on_restore fun()
local function with_conflict_check(current_session, on_restore)
    if check_conflict(current_session) then
        vim.ui.select({
            "Cancel",
            "Clear current session and restore",
        }, {
            prompt = "Current session has messages. What would you like to do?",
        }, function(choice)
            if choice == "Clear current session and restore" then
                on_restore()
            end
        end)
    else
        on_restore()
    end
end

--- Format a session's updatedAt and title for display
--- @param session agentic.acp.SessionInfo
--- @return string date, string title
local function format_session(session)
    local date = session.updatedAt
            and session.updatedAt:sub(1, 16):gsub("T", " ")
        or "unknown date"
    local title = session.title or "(no title)"
    return date, title
end

--- List sessions for the current cwd and pass them to the callback.
--- Handles error and empty-list paths with notifications.
--- @param current_session agentic.SessionManager
--- @param on_sessions fun(sessions: agentic.acp.SessionInfo[])
local function with_sessions(current_session, on_sessions)
    local cwd = vim.fn.getcwd()
    current_session.agent:when_ready(function()
        current_session.agent:list_sessions(cwd, function(result, err)
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

            on_sessions(sessions)
        end)
    end)
end

--- Show ACP session picker
--- @param sessions agentic.acp.SessionInfo[]
--- @param current_session agentic.SessionManager
local function show_acp_picker(sessions, current_session)
    local items = {}
    for _, s in ipairs(sessions) do
        local date, title = format_session(s)
        table.insert(items, {
            display = string.format("%s - %s", date, title),
            session_id = s.sessionId,
            title = s.title,
            updated_at = date,
        })
    end

    vim.schedule(function()
        vim.ui.select(items, {
            prompt = "Select session to restore:",
            format_item = function(item)
                return item.display
            end,
        }, function(choice)
            if not choice then
                return
            end

            with_conflict_check(current_session, function()
                current_session:load_acp_session(
                    choice.session_id,
                    choice.title,
                    choice.updated_at
                )
                current_session.widget:show()
            end)
        end)
    end)
end

--- Show session picker and restore selected session
--- @param current_session agentic.SessionManager
function SessionRestore.show_picker(current_session)
    with_sessions(current_session, function(sessions)
        show_acp_picker(sessions, current_session)
    end)
end

--- Restore session by ID
--- @param current_session agentic.SessionManager
--- @param session_id string
function SessionRestore.restore_by_id(current_session, session_id)
    current_session.agent:when_ready(function()
        vim.schedule(function()
            with_conflict_check(current_session, function()
                current_session:load_acp_session(session_id, nil, nil)
                current_session.widget:show()
            end)
        end)
    end)
end

return SessionRestore
