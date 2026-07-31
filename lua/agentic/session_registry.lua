local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

local KEEP_CURRENT_SESSION = "Keep current session in the background"
local DESTROY_CURRENT_SESSION = "Destroy current session"

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Keyed by session key
--- @field _next_id integer Last assigned session key
--- @field _most_recent? agentic.SessionManager
--- @field _previous_most_recent? agentic.SessionManager The one `_most_recent` displaced
local SessionRegistry = {
    sessions = {},
    _next_id = 0,
    _most_recent = nil,
    _previous_most_recent = nil,
}

--- The recency cursors can outlive a destroyed session.
--- @param session agentic.SessionManager|nil
--- @return agentic.SessionManager|nil
local function registered(session)
    local session_key = session and session.session_key

    if session_key and SessionRegistry.sessions[session_key] == session then
        return session
    end

    return nil
end

--- @param session agentic.SessionManager|nil
local function remember_most_recent(session)
    if session == SessionRegistry._most_recent then
        return
    end

    SessionRegistry._previous_most_recent = SessionRegistry._most_recent
    SessionRegistry._most_recent = session
end

--- @param provider_name agentic.UserConfig.ProviderName|nil Defaults to `Config.provider`
--- @return agentic.SessionManager|nil
function SessionRegistry.create(provider_name)
    -- `SessionManager:new` resolves its agent from `Config.provider` synchronously, so a
    -- caller needing a specific provider borrows the global for that call only. The wrong
    -- provider sends a restored ACP session ID to an agent that never issued it.
    local previous_provider = Config.provider

    if provider_name then
        Config.provider = provider_name
    end

    local provider_available = false
    local ok, session = pcall(function()
        provider_available = ACPHealth.check_configured_provider()
        if not provider_available then
            return nil
        end

        local SessionManager = require("agentic.session_manager")
        return SessionManager:new() --[[@as agentic.SessionManager|nil]]
    end)

    Config.provider = previous_provider

    if not ok then
        Logger.debug("Session creation failed:", session)
        return nil
    end

    if not provider_available then
        Logger.debug("Session creation aborted: No configured ACP provider")
        return nil
    end

    if not session then
        return nil
    end

    -- Key assigned only after `new` returns: the widget's first `show` reads the
    -- previous session's stored size from the registry.
    SessionRegistry._next_id = SessionRegistry._next_id + 1
    session.session_key = SessionRegistry._next_id
    SessionRegistry.sessions[session.session_key] = session
    session.widget.session_key = session.session_key

    return session
end

--- @return agentic.SessionManager|nil
function SessionRegistry.visible_here()
    local current_tab = vim.api.nvim_get_current_tabpage()

    for _, session in pairs(SessionRegistry.sessions) do
        if session.widget:get_visible_tab_id() == current_tab then
            return session
        end
    end

    return nil
end

--- The live session already holding an ACP session ID on this provider, if any.
--- @param acp_session_id string
--- @param agent agentic.acp.ACPClient
--- @return agentic.SessionManager|nil
function SessionRegistry.find_by_acp_session_id(acp_session_id, agent)
    for _, session in pairs(SessionRegistry.sessions) do
        if
            session.agent == agent
            and session:has_acp_session_id(acp_session_id)
        then
            return session
        end
    end

    return nil
end

--- Visible here, else most recently visible. Never creates.
--- @return agentic.SessionManager|nil
function SessionRegistry.current()
    return SessionRegistry.visible_here()
        or registered(SessionRegistry._most_recent)
end

--- `current`, else a NEW session plus a provider subprocess.
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.resolve_or_create(callback)
    local instance = SessionRegistry.current() or SessionRegistry.create()

    -- Not done in `create`, which must leave `_most_recent` on the previous
    -- session while the new widget reads its size.
    if instance then
        remember_most_recent(instance)
    end

    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- Creates an additional session after resolving the current one's lifecycle.
--- @param on_created fun(session: agentic.SessionManager)
--- @param provider_name agentic.UserConfig.ProviderName|nil Becomes the global provider only if creation proceeds
function SessionRegistry.create_with_current_session_guard(
    on_created,
    provider_name
)
    local current = SessionRegistry.current()

    --- @param choice string|nil
    local function create(choice)
        local session = SessionRegistry.create(provider_name)

        if not session then
            return
        end

        -- Committed only after creation succeeds: cancellation or a failed health check
        -- must leave the provider used by the current session unchanged.
        if provider_name then
            Config.provider = provider_name
        end

        on_created(session)

        local current_key = current and current.session_key
        if choice == DESTROY_CURRENT_SESSION and current_key then
            SessionRegistry.destroy(current_key)
        end
    end

    if not current then
        create(nil)
        return
    end

    vim.ui.select({
        KEEP_CURRENT_SESSION,
        DESTROY_CURRENT_SESSION,
    }, {
        prompt = "New session:",
    }, function(choice)
        if
            choice == KEEP_CURRENT_SESSION
            or choice == DESTROY_CURRENT_SESSION
        then
            create(choice)
        end
    end)
end

--- @param session_key integer
function SessionRegistry.destroy(session_key)
    local session = SessionRegistry.sessions[session_key]

    if not session then
        return
    end

    SessionRegistry.sessions[session_key] = nil

    if SessionRegistry._most_recent == session then
        remember_most_recent(SessionRegistry.list()[1])
    end

    -- AFTER the repoint above, which can demote `session` into this cursor.
    if SessionRegistry._previous_most_recent == session then
        SessionRegistry._previous_most_recent = nil
    end

    local ok, err = pcall(session.destroy, session)
    if not ok then
        Logger.debug("Session destroy error:", err)
    end

    -- AFTER the registry removal above and `session.destroy` (which unregisters the
    -- widget): the refresh reads the LIVE session count and widget registry, so running
    -- it earlier sees the dying session.
    -- Required lazily: `ui.window_decoration` requires this module back.
    require("agentic.ui.window_decoration").refresh_buffer_names()
end

--- Destroys the visible session in this tab, else the most recently visible one.
function SessionRegistry.destroy_current()
    local session = SessionRegistry.current()
    local session_key = session and session.session_key

    if session_key then
        SessionRegistry.destroy(session_key)
    end
end

--- Recency order: `_most_recent`, the one it displaced, then ascending key.
--- @return agentic.SessionManager[] sessions
function SessionRegistry.list()
    --- @type integer[]
    local keys = {}

    for key in pairs(SessionRegistry.sessions) do
        keys[#keys + 1] = key
    end

    table.sort(keys)

    --- @type agentic.SessionManager[]
    local sessions = {}
    --- @type table<agentic.SessionManager, boolean>
    local seen = {}

    --- @param session agentic.SessionManager|nil
    local function push(session)
        if session and not seen[session] then
            seen[session] = true
            sessions[#sessions + 1] = session
        end
    end

    push(registered(SessionRegistry._most_recent))
    push(registered(SessionRegistry._previous_most_recent))

    for _, key in ipairs(keys) do
        push(SessionRegistry.sessions[key])
    end

    return sessions
end

--- The only path that switches a session between tabpages (ADR 0008): at most one
--- visible widget per tab, at most one tab per session.
--- Hide runs before show: `hide` captures the outgoing size that `show` reads.
--- @param session_key integer
--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function SessionRegistry.show_session(session_key, opts)
    local target = SessionRegistry.sessions[session_key]

    if not target then
        return
    end

    local current_tab = vim.api.nvim_get_current_tabpage()

    for _, session in pairs(SessionRegistry.sessions) do
        if
            session ~= target
            and session.widget:get_visible_tab_id() == current_tab
        then
            -- keep_insert: a show follows this tick and `stopinsert` latches past it
            session.widget:hide(true)
        end
    end

    local target_tab = target.widget:get_visible_tab_id()

    if target_tab and target_tab ~= current_tab then
        target.widget:hide(true)
    end

    remember_most_recent(target)
    target.widget:show(opts)
end

--- Points `_most_recent` at a session WITHOUT showing it.
--- @param session_key integer
function SessionRegistry.set_most_recent(session_key)
    local session = SessionRegistry.sessions[session_key]

    if session then
        remember_most_recent(session)
    end
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) nil when cancelled
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
