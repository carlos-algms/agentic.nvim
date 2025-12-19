local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Weak map: tab_page_id -> SessionManager instance
local SessionRegistry = {
    sessions = setmetatable({}, { __mode = "v" }),
}

--- @param tab_page_id integer|nil
function SessionRegistry.get_session_for_tab_page(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local instance = SessionRegistry.sessions[tab_page_id]

    if not instance then
        instance = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager|nil]]
        if instance ~= nil then
            SessionRegistry.sessions[tab_page_id] = instance
        end
    end

    return instance --[[@as agentic.SessionManager]]
end

--- Destroys any existing session for the given tab page and creates a new one
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager
function SessionRegistry.new_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab_page_id]

    if session then
        local ok, err = pcall(function()
            session:destroy()
        end)
        if not ok then
            Logger.debug("Session destroy error:", err)
        end
        SessionRegistry.sessions[tab_page_id] = nil
    end

    local new_session = SessionRegistry.get_session_for_tab_page(tab_page_id)
    return new_session
end

--- Destroys the session for the given tab page, if it exists and removes it from the registry
--- @param tab_page_id integer|nil
function SessionRegistry.destroy_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab_page_id]

    if session then
        pcall(function()
            session:destroy()
        end)
        SessionRegistry.sessions[tab_page_id] = nil
    end
end

return SessionRegistry
