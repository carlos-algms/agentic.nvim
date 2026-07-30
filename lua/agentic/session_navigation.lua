local SessionRegistry = require("agentic.session_registry")

--- @param step 1|-1
local function cycle(step)
    local sessions = SessionRegistry.list()

    if #sessions < 2 then
        return
    end

    table.sort(sessions, function(left, right)
        local left_key = left.session_key --[[@as integer]]
        local right_key = right.session_key --[[@as integer]]

        return left_key < right_key
    end)

    local current = SessionRegistry.current()
    local current_key = current and current.session_key

    if not current_key then
        return
    end

    for index, session in ipairs(sessions) do
        if session.session_key == current_key then
            local target = sessions[(index - 1 + step) % #sessions + 1]
            local target_key = target.session_key

            if target_key then
                SessionRegistry.show_session(target_key)
            end

            return
        end
    end
end

local SessionNavigation = {}

--- Shows a picker over every live session and opens the chosen one.
function SessionNavigation.select()
    local sessions = SessionRegistry.list()
    local current_tab = vim.api.nvim_get_current_tabpage()

    vim.ui.select(sessions, {
        prompt = "Select a Chat session:",
        --- @param item agentic.SessionManager
        format_item = function(item)
            local title = item.chat_history.title
            local provider = item.agent
                and item.agent.provider_config
                and item.agent.provider_config.name
            local label = title ~= "" and title or "Untitled"

            if provider then
                label = string.format("%s [%s]", label, provider)
            end

            -- APPENDED, not a fallback: `or` short-circuits on the truthy provider name,
            -- so a key used as last fallback is unreachable and untitled sessions on one
            -- provider all render the same row.
            label = string.format("%s (%d)", label, item.session_key)

            local prefix = item.widget:get_visible_tab_id() == current_tab
                    and "● "
                or "  "
            return prefix .. label
        end,
    }, function(selected)
        local session_key = selected and selected.session_key

        if session_key then
            SessionRegistry.show_session(session_key)
        end
    end)
end

--- Opens the session with the next higher key, wrapping at the end.
function SessionNavigation.next()
    cycle(1)
end

--- Opens the session with the next lower key, wrapping at the start.
function SessionNavigation.previous()
    cycle(-1)
end

return SessionNavigation
