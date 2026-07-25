local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- The prompt the user is halfway through typing counts as staged work too, and
--- unlike a file or a selection it cannot be re-added with one keystroke. Blank
--- lines do not count: the input buffer always holds at least one.
--- @param bufnr integer|nil
--- @return boolean is_blank
local function input_is_blank(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return true
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    return vim.trim(table.concat(lines, "")) == ""
end

--- Empty means no conversation AND no staged context. Messages alone are not
--- enough: files, code selections, diagnostics and unsent input are work the user
--- staged by hand, and only explicit intent may discard it.
--- @param session agentic.SessionManager
--- @return boolean is_empty
local function is_empty(session)
    return #session.chat_history.messages == 0
        and session.file_list:is_empty()
        and session.code_selection:is_empty()
        and session.diagnostics_list:is_empty()
        and input_is_blank(session.widget.buf_nrs.input)
end

--- Restores into a BRAND NEW session, never into the resolved one. The old
--- "clear current session and restore" prompt only existed because one session
--- per tab left nowhere else to restore into.
--- The resolved session is destroyed when it holds nothing: every public restore
--- entry point goes through `SessionRegistry.resolve_or_create`, which creates a
--- session purely to reach `.agent` — `ACPClient:list_sessions` needs a connected
--- client, not an ACP session — and that session would otherwise be stranded empty
--- and unused.
--- Destroyed LAST, after the restored session is on screen, not first:
--- `SessionRegistry.create` can answer nil, and a destroy already done by then
--- leaves the user with no session at all; and `ChatWidget:_inherited_size` reads
--- its donor at `show` time from `SessionRegistry.list`, while `ChatWidget:destroy`
--- captures no size. The donor is whichever session `list` reaches first carrying
--- this layout's axis — `show_session` has already pointed `_most_recent` at the
--- new session, which has no size, so the scan falls through to ascending key
--- order. With one session open that donor IS the resolved one, and destroying it
--- earlier hands a resized sidebar back its configured default. Measured: 32
--- columns after a resize to 50.
--- The capability check comes before `create`, not from `load_acp_session`: a
--- provider without `loadSession` would otherwise get a session created, shown and
--- another destroyed for an operation that could never run.
--- `show_session` and not `widget:show()`: `show_picker` shows after an async
--- `when_ready` -> `list_sessions` -> `vim.ui.select` chain, so a user who opens
--- another session in this tab meanwhile would end up with two widgets in it.
--- Regressions: session_restore.test.lua::"keeps the resolved session when create
--- fails" and test_multi_session.lua::"inherits the resized width of the session it
--- restores over".
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
    local caps = current_session.agent.agent_capabilities

    if not caps or not caps.loadSession then
        Logger.notify(
            "Agent does not support loading sessions",
            vim.log.levels.WARN
        )
        return
    end

    local session = SessionRegistry.create()
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

    if current_session.session_key and is_empty(current_session) then
        SessionRegistry.destroy(current_session.session_key)
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
                vim.ui.select(items, {
                    prompt = "Select session to restore:",
                    format_item = function(item)
                        return item.display
                    end,
                }, function(choice)
                    if not choice then
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

--- Restore session by ID
--- @param current_session agentic.SessionManager
--- @param session_id string
function SessionRestore.restore_by_id(current_session, session_id)
    current_session.agent:when_ready(function()
        vim.schedule(function()
            restore_into_new_session(current_session, session_id, nil, nil)
        end)
    end)
end

return SessionRestore
