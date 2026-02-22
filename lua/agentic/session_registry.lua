local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Weak map: tab_page_id -> SessionManager instance
local SessionRegistry = {
    sessions = setmetatable({}, { __mode = "v" }),
}

--- @param tab_page_id integer|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session valid session instance or nil on failure
function SessionRegistry.get_session_for_tab_page(tab_page_id, callback)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local instance = SessionRegistry.sessions[tab_page_id]

    if not instance then
        local ACPHealth = require("agentic.acp.acp_health")
        if not ACPHealth.check_configured_provider() then
            Logger.debug("Session creation aborted: No configured ACP provider")
            return nil
        end

        local SessionManager = require("agentic.session_manager")

        instance = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager|nil]]
        if instance ~= nil then
            SessionRegistry.sessions[tab_page_id] = instance
        end
    end

    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- Destroys any existing session for the given tab page and creates a new one
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.new_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()

    SessionRegistry.destroy_session(tab_page_id)

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
        SessionRegistry.sessions[tab_page_id] = nil

        local ok, err = pcall(function()
            session:destroy()
        end)
        if not ok then
            Logger.debug("Session destroy error:", err)
        end
    end
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) Callback that will be called with the selected provider name, if any
function SessionRegistry.select_provider(on_selected)
    --- @type string[]
    local available_providers = {}

    for key, _ in pairs(Config.acp_providers) do
        table.insert(available_providers, key)
    end

    vim.ui.select(available_providers, {
        prompt = "Select an ACP provider:",
        --- @param item agentic.UserConfig.ProviderName
        format_item = function(item)
            local prefix = item == Config.provider and "● " or "  "
            return string.format("%s%s", prefix, item)
        end,
    }, function(selected_mode)
        on_selected(selected_mode)
    end)
end

return SessionRegistry
