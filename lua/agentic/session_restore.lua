local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
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

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
local function do_restore(session_id, tab_page_id, has_conflict)
    ChatHistory.load(session_id, function(history, err)
        if err or not history then
            Logger.notify(
                "Failed to load session: " .. (err or "unknown error"),
                vim.log.levels.WARN
            )
            return
        end

        SessionRegistry.get_session_for_tab_page(tab_page_id, function(session)
            if has_conflict then
                if session.session_id then
                    session.agent:cancel_session(session.session_id)
                    session.widget:clear()
                end
            end

            session:restore_from_history(
                history,
                { reuse_session = not has_conflict }
            )

            session.widget:show()
        end)
    end)
end

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
local function restore_with_conflict_check(
    session_id,
    tab_page_id,
    has_conflict
)
    if has_conflict then
        vim.ui.select({
            "Cancel",
            "Clear current session and restore",
        }, {
            prompt = "Current session has messages. What would you like to do?",
        }, function(choice)
            if choice == "Clear current session and restore" then
                do_restore(session_id, tab_page_id, has_conflict)
            end
        end)
    else
        do_restore(session_id, tab_page_id, has_conflict)
    end
end

--- Show session picker and restore selected session
--- @param tab_page_id integer
--- @param current_session agentic.SessionManager|nil
function SessionRestore.show_picker(tab_page_id, current_session)
    ChatHistory.list_sessions(function(sessions)
        if #sessions == 0 then
            Logger.notify("No saved sessions found", vim.log.levels.INFO)
            return
        end

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
                restore_with_conflict_check(
                    choice.session_id,
                    tab_page_id,
                    check_conflict(current_session)
                )
            end
        end)
    end)
end

--- Replay stored messages to the UI
--- @param writer agentic.ui.MessageWriter
--- @param messages agentic.ui.ChatHistory.Message[]
function SessionRestore.replay_messages(writer, messages)
    for _, msg in ipairs(messages) do
        if msg.type == "user" then
            -- Format user message for display with original timestamp
            local timestamp_str = msg.timestamp
                    and os.date("%Y-%m-%d %H:%M:%S", msg.timestamp)
                or os.date("%Y-%m-%d %H:%M:%S")
            local message_lines = {
                string.format("##  User - %s", timestamp_str),
                "",
                msg.text,
                "\n\n### 󱚠 Agent - "
                    .. (msg.provider_name or "Unknown provider"),
            }
            local user_message =
                ACPPayloads.generate_user_message(message_lines)
            writer:write_message(user_message)
        elseif msg.type == "agent" then
            local agent_message = ACPPayloads.generate_agent_message(msg.text)
            writer:write_message(agent_message)
        elseif msg.type == "thought" then
            --- @type agentic.acp.AgentThoughtChunk
            local thought_chunk = {
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = msg.text },
            }
            writer:write_message_chunk(thought_chunk)
        elseif msg.type == "tool_call" then
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local tool_block = {
                tool_call_id = msg.tool_call_id,
                kind = msg.kind,
                argument = msg.argument or "",
                status = msg.status,
                body = msg.body,
                diff = msg.diff,
            }
            writer:write_tool_call_block(tool_block)
        end
    end
end

return SessionRestore
