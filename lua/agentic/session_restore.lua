local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

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
                table.insert(items, {
                    display = string.format("%s - %s", date, title),
                    session_id = s.sessionId,
                    title = s.title,
                    updated_at = date,
                })
            end

            vim.schedule(function()
                local pool = SessionRegistry.get_pool()
                vim.ui.select(items, {
                    prompt = "Select session to restore:",
                    format_item = function(item)
                        local label = item.display
                        if pool[item.session_id] then
                            label = label .. " [live]"
                        end
                        return label
                    end,
                }, function(choice)
                    if not choice then
                        return
                    end

                    local tab_id = vim.api.nvim_get_current_tabpage()

                    -- If selected session is already live in the pool, detach current
                    -- and attach the pooled one without reloading from the ACP provider.
                    if pool[choice.session_id] then
                        SessionRegistry.detach_session(tab_id)
                        SessionRegistry.attach_session(
                            choice.session_id,
                            tab_id
                        )
                        return
                    end

                    with_conflict_check(current_session, function()
                        -- Detach (not destroy) current session so it stays in pool
                        SessionRegistry.detach_session(tab_id)
                        local new_session =
                            SessionRegistry.get_session_for_tab_page(tab_id)
                        if new_session then
                            new_session:load_acp_session(
                                choice.session_id,
                                choice.title,
                                choice.updated_at
                            )
                            new_session.widget:show()
                        end
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
