local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Map: session_key -> SessionManager instance
--- @field _next_id integer Last assigned session key
--- @field _most_recent? agentic.SessionManager Most recently visible session
local SessionRegistry = {
    sessions = {},
    _next_id = 0,
    _most_recent = nil,
}

--- Returns `_most_recent` only while it is still registered. A destroyed session
--- leaves the field pointing at a session that no longer exists.
--- @return agentic.SessionManager|nil
local function registered_most_recent()
    local session = SessionRegistry._most_recent
    local session_key = session and session.session_key

    if session_key and SessionRegistry.sessions[session_key] == session then
        return session
    end

    return nil
end

--- Creates a new session and registers it under a fresh session key
--- @return agentic.SessionManager|nil
function SessionRegistry.create()
    if not ACPHealth.check_configured_provider() then
        Logger.debug("Session creation aborted: No configured ACP provider")
        return nil
    end

    local SessionManager = require("agentic.session_manager")

    -- The key is assigned only after `new` returns: the widget's first `show`
    -- reads the previous session's stored size, so `_most_recent` and the
    -- registry must still describe the old world while `new` runs.
    local session = SessionManager:new() --[[@as agentic.SessionManager|nil]]

    if not session then
        return nil
    end

    SessionRegistry._next_id = SessionRegistry._next_id + 1
    session.session_key = SessionRegistry._next_id
    SessionRegistry.sessions[session.session_key] = session
    -- Published onto the widget so buffer-scoped code reaches the key through
    -- `WidgetRegistry.get(bufnr)`, without inverting the dependency direction.
    session.widget.session_key = session.session_key

    return session
end

--- The session whose widget is visible in the current tab, if any.
--- @return agentic.SessionManager|nil
function SessionRegistry.visible_here()
    local current_tab = vim.api.nvim_get_current_tabpage()

    for _, session in pairs(SessionRegistry.sessions) do
        if session.widget:visible_tab() == current_tab then
            return session
        end
    end

    return nil
end

--- The session the user is acting on WITHOUT creating one: the session visible in
--- the current tab, else the most recently visible one while it is still
--- registered. Callers that only navigate between existing sessions must use this
--- instead of `resolve_or_create`: that one answers a miss by creating a session,
--- so cycling with a stale `_most_recent` would spawn a provider subprocess just
--- to pick a starting point.
--- Regression: agentic.test.lua::"cycles nowhere, and creates nothing, without a
--- start point" and ::"destroys nothing, and creates nothing, without a start
--- point".
--- @return agentic.SessionManager|nil
function SessionRegistry.current()
    return SessionRegistry.visible_here() or registered_most_recent()
end

--- Resolves the session the user is acting on: the one visible in the current
--- tab, else the most recently visible one, else a brand new session.
--- Named for the side effect: a miss CREATES a session, and with it a provider
--- subprocess. Callers that only navigate must use `current` instead.
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.resolve_or_create(callback)
    local instance = SessionRegistry.current() or SessionRegistry.create()

    -- Resolve-only entry points (`stop_generation`, `restore_session`,
    -- `restore_session_by_id`) never reach `show_session`, so nothing else would
    -- publish the resolved session. Without this write `_most_recent` stays nil
    -- and every call creates another session — and another ACP subprocess.
    -- Measured: three `stop_generation` calls, three sessions.
    -- Written HERE and not in `create`: `create` must leave `_most_recent`
    -- pointing at the PREVIOUS session while the new widget is built, which is
    -- what seeds its size.
    -- Regression: session_registry.test.lua::"reuses the session it created on
    -- the next resolve".
    if instance then
        SessionRegistry._most_recent = instance
    end

    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- Destroys the session stored under the given key, if any
--- @param session_key integer
function SessionRegistry.destroy(session_key)
    local session = SessionRegistry.sessions[session_key]

    if not session then
        return
    end

    SessionRegistry.sessions[session_key] = nil

    if SessionRegistry._most_recent == session then
        -- The key is already gone, so `list` skips the destroyed session and
        -- orders the rest by ascending key.
        SessionRegistry._most_recent = SessionRegistry.list()[1]
    end

    local ok, err = pcall(function()
        session:destroy()
    end)
    if not ok then
        Logger.debug("Session destroy error:", err)
    end
end

--- Lists every registered session: `_most_recent` first when it is still
--- registered, then the rest by ascending session key.
--- @return agentic.SessionManager[] sessions
function SessionRegistry.list()
    --- @type integer[]
    local keys = {}

    for key in pairs(SessionRegistry.sessions) do
        keys[#keys + 1] = key
    end

    table.sort(keys)

    local most_recent = registered_most_recent()

    --- @type agentic.SessionManager[]
    local sessions = {}

    if most_recent then
        sessions[1] = most_recent
    end

    for _, key in ipairs(keys) do
        local session = SessionRegistry.sessions[key]

        if session and session ~= most_recent then
            sessions[#sessions + 1] = session
        end
    end

    return sessions
end

--- Shows the session stored under `session_key`, evicting whatever else stands in
--- the way. The single choke point for every switching path: at most one visible
--- widget per tab, and at most one tab per session.
--- Hiding always runs before showing, and every caller inherits that ordering:
--- `ChatWidget:hide` is where the outgoing widget's size is captured, which is
--- what the incoming widget's first `show` reads.
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
            and session.widget:visible_tab() == current_tab
        then
            -- `keep_insert`: a show follows in this same tick, and `stopinsert`
            -- latches past it
            session.widget:hide(true)
        end
    end

    local target_tab = target.widget:visible_tab()

    if target_tab and target_tab ~= current_tab then
        target.widget:hide(true)
    end

    SessionRegistry._most_recent = target
    target.widget:show(opts)
end

--- Points `_most_recent` at a registered session WITHOUT showing it.
--- `show_session` is the choke point for everything visible; this is the one path
--- that has nothing to show: the provider switch replaces a session whose widget
--- was already closed, and leaving `_most_recent` nil makes the next
--- `resolve_or_create` create yet another session instead of returning the
--- replacement.
--- Regression: agentic.test.lua::"reuses the switched session on the next open".
--- @param session_key integer
function SessionRegistry.set_most_recent(session_key)
    local session = SessionRegistry.sessions[session_key]

    if session then
        SessionRegistry._most_recent = session
    end
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
