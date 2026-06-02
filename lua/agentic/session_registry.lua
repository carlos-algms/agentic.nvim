local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Weak map: tab_page_id -> SessionManager instance
--- @field pool table<string, agentic.SessionManager> Strong map: session_id -> detached SessionManager
local SessionRegistry = {
    sessions = setmetatable({}, { __mode = "v" }),
    pool = {},
}

--- @param tab_page_id integer|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session valid session instance or nil on failure
function SessionRegistry.get_session_for_tab_page(tab_page_id, callback)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local instance = SessionRegistry.sessions[tab_page_id]

    if not instance then
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
--- Note: Actually detaches (not destroys) to keep session alive in pool
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.new_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()

    SessionRegistry.detach_session(tab_page_id)

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
        if session.session_id then
            SessionRegistry.pool[session.session_id] = nil
        end

        local ok, err = pcall(function()
            session:destroy()
        end)
        if not ok then
            Logger.debug("Session destroy error:", err)
        end
    end
end

--- Detaches the session from its tab page, keeping the ACP process alive in the pool.
--- The session can be reattached later via attach_session().
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil session the detached session, or nil if none existed
function SessionRegistry.detach_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab_page_id]

    if not session then
        return nil
    end

    SessionRegistry.sessions[tab_page_id] = nil
    session:detach()

    -- If session doesn't have a session_id yet (ephemeral), generate one
    if not session.session_id then
        session.session_id = SessionRegistry._generate_ephemeral_id()
    end

    SessionRegistry.pool[session.session_id] = session

    return session
end

--- Attaches a pooled session to a tab page, replacing any existing session there.
--- @param session_id string
--- @param tab_page_id integer|nil
--- @return boolean attached true if the session was found in the pool and attached
function SessionRegistry.attach_session(session_id, tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()

    local session = SessionRegistry.pool[session_id]
    if not session then
        return false
    end

    -- Detach any existing session on this tab page first
    SessionRegistry.detach_session(tab_page_id)

    SessionRegistry.pool[session_id] = nil
    SessionRegistry.sessions[tab_page_id] = session
    session:attach(tab_page_id)
    return true
end

--- Returns all live sessions from the pool (keyed by session_id).
--- @return table<string, agentic.SessionManager>
function SessionRegistry.get_pool()
    return SessionRegistry.pool
end

--- Destroys sessions whose tabpage is no longer in nvim_list_tabpages()
function SessionRegistry.destroy_closed_sessions()
    local valid = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        valid[tab] = true
    end

    for tab_page_id in pairs(SessionRegistry.sessions) do
        if not valid[tab_page_id] then
            SessionRegistry.detach_session(tab_page_id)
        end
    end
end

--- Prunes idle sessions from the pool based on pool_ttl config
function SessionRegistry.prune_idle_sessions()
    local Config = require("agentic.config")
    local ttl = Config.settings.pool_ttl

    -- If TTL is 0, keep all sessions until Neovim exits
    if ttl <= 0 then
        return
    end

    local now = os.time()
    local idle_threshold = now - ttl

    for session_id, session in pairs(SessionRegistry.pool) do
        -- Keep sessions that are currently generating
        if not session.is_generating then
            -- Check if session has been idle beyond TTL
            if session.last_activity and session.last_activity < idle_threshold then
                SessionRegistry.pool[session_id] = nil
                local ok, err = pcall(function()
                    session:destroy()
                end)
                if not ok then
                    Logger.debug("Session destroy error during prune:", err)
                end
            end
        end
    end
end

--- Generates a unique session ID for ephemeral (unsaved) sessions
--- @return string
function SessionRegistry._generate_ephemeral_id()
    return "ephemeral_" .. os.time() .. "_" .. math.random(1000, 9999)
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) Callback that will be called with the selected provider name, if any
function SessionRegistry.select_provider(on_selected)
    local available_providers = ACPHealth.get_default_provider_names()

    --- @class _ProviderStatus
    --- @field name string
    --- @field installed boolean

    --- @type _ProviderStatus[]
    local healthy_providers = {}

    --- @type _ProviderStatus[]
    local unhealthy_providers = {}

    for _, provider_name in ipairs(available_providers) do
        local provider_config = Config.acp_providers[provider_name]
        if
            provider_config
            and ACPHealth.is_command_available(provider_config.command)
        then
            healthy_providers[#healthy_providers + 1] = {
                name = provider_name,
                installed = true,
            }
        else
            unhealthy_providers[#unhealthy_providers + 1] = {
                name = provider_name,
                installed = false,
            }
        end
    end

    local function sort_by_name(left, right)
        return left.name < right.name
    end

    table.sort(healthy_providers, sort_by_name)
    table.sort(unhealthy_providers, sort_by_name)

    local providers = healthy_providers
    if not Config.provider_switcher.hide_unhealthy_providers then
        vim.list_extend(providers, unhealthy_providers)
    elseif #providers == 0 then
        Logger.notify(
            "No healthy providers found. Showing unavailable providers."
        )
        providers = unhealthy_providers
    end

    vim.ui.select(providers, {
        prompt = "Select an ACP provider for the new session:",
        snacks = {
            sort = {
                fields = { "installed", "score:desc", "idx" },
            },
        },
        --- @param item _ProviderStatus
        format_item = function(item)
            local label = item.name

            if label == Config.provider then
                label = label .. " (current)"
            elseif label == DefaultConfig.provider then
                label = label .. " (default)"
            end

            label = label
                .. (item.installed and " ✓ available" or " ✗ not installed")

            return label
        end,
    }, function(selected_provider)
        on_selected(selected_provider and selected_provider.name)
    end)
end

return SessionRegistry
