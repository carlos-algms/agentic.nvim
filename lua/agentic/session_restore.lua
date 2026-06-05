local Logger = require("agentic.utils.logger")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Truncate a string to at most `max_bytes` bytes without splitting a UTF-8 character.
--- @param s string
--- @param max_bytes number
--- @return string
local function utf8_truncate(s, max_bytes)
    if #s <= max_bytes then
        return s
    end
    local i = max_bytes
    while i > 0 do
        local start_off = vim.str_utf_start(s, i)
        if start_off == 0 then
            -- i is at a char boundary; check the full char fits
            local end_off = vim.str_utf_end(s, i)
            if i + end_off <= max_bytes then
                return s:sub(1, i + end_off)
            end
            i = i - 1
        else
            -- i is inside a multi-byte char; jump to its start then back up
            i = i + start_off - 1
        end
    end
    return ""
end

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

--- Show session picker and restore selected session
--- @param current_session agentic.SessionManager
function SessionRestore.show_picker(current_session)
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

            local items = {}
            for _, s in ipairs(sessions) do
                local date = s.updatedAt
                        and s.updatedAt:sub(1, 16):gsub("T", " ")
                    or "unknown date"
                local title = s.title or "(no title)"
                title = utf8_truncate(
                    title:gsub("\r\n", " "):gsub("\r", " "):gsub("\n", " "),
                    80
                )
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
        end)
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
