local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")
local AgentInstance = require("agentic.acp.agent_instance")
local BufHelpers = require("agentic.utils.buf_helpers")
local SessionManager = require("agentic.session_manager")

local KEEP_CURRENT_SESSION = "Keep current session in the background"
local DESTROY_CURRENT_SESSION = "Destroy current session"
local NIL_REPLACEMENT_SOURCE = {}

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

--- @type fun(source: agentic.SessionManager|nil, target: agentic.SessionManager, opts: agentic.SessionReplacementOpts, destroy_target_on_rollback: boolean): boolean
local commit_replacement

--- @param provider_name agentic.UserConfig.ProviderName|nil Defaults to `Config.provider`
--- @param start_spec agentic.SessionStartSpec|nil Defaults to a new session
--- @param agent agentic.acp.ACPClient|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.create(provider_name, start_spec, agent)
    provider_name = provider_name or Config.provider
    agent = agent or AgentInstance.get_instance(provider_name)
    if not agent then
        Logger.debug("Session creation aborted: No configured ACP provider")
        return nil
    end

    local ok, session = pcall(function()
        return SessionManager:new(agent, provider_name)
    end)

    if not ok then
        Logger.debug("Session creation failed:", session)
        return nil
    end

    if not session then
        return nil
    end

    SessionRegistry._next_id = SessionRegistry._next_id + 1
    session.session_key = SessionRegistry._next_id
    SessionRegistry.sessions[session.session_key] = session
    session.widget.session_key = session.session_key

    local session_key = session.session_key --[[@as integer]]
    session:on_session_ready(function() end, function()
        if SessionRegistry.sessions[session_key] == session then
            SessionRegistry.destroy(session_key)
        end
    end)
    session:start(start_spec or { kind = "new" })

    return session
end

--- Register one commit callback per source/target pair while startup is pending.
--- @param source agentic.SessionManager|nil
--- @param target agentic.SessionManager
--- @param opts agentic.SessionReplacementOpts
--- @param destroy_target_on_rollback boolean
local function await_replacement(
    source,
    target,
    opts,
    destroy_target_on_rollback
)
    local source_token = source or NIL_REPLACEMENT_SOURCE
    --- @diagnostic disable-next-line: invisible
    local pending = target._pending_replacement_sources or {}
    if pending[source_token] then
        return
    end

    pending[source_token] = true
    --- @diagnostic disable-next-line: invisible
    target._pending_replacement_sources = pending

    local function clear_pending()
        pending[source_token] = nil
        if next(pending) == nil then
            --- @diagnostic disable-next-line: invisible
            target._pending_replacement_sources = nil
        end
    end

    target:on_session_ready(function()
        clear_pending()
        commit_replacement(source, target, opts, destroy_target_on_rollback)
    end, function()
        clear_pending()
        local target_key = target.session_key
        if
            destroy_target_on_rollback
            and target_key
            and SessionRegistry.sessions[target_key] == target
        then
            SessionRegistry.destroy(target_key)
        end
    end)
end

--- @param source agentic.SessionManager|nil
--- @param target agentic.SessionManager
--- @return boolean
local function replacement_is_pending(source, target)
    local source_token = source or NIL_REPLACEMENT_SOURCE
    --- @diagnostic disable-next-line: invisible
    local pending = target._pending_replacement_sources
    return pending ~= nil and pending[source_token] == true
end

--- @class agentic.SessionReplacementOpts
--- @field agent? agentic.acp.ACPClient
--- @field prepare? fun(source: agentic.SessionManager, target: agentic.SessionManager)
--- @field on_commit? fun(target: agentic.SessionManager, source: agentic.SessionManager|nil)
--- @field show_opts? agentic.ui.ChatWidget.ShowOpts

--- @param source agentic.SessionManager|nil
--- @param provider_name agentic.UserConfig.ProviderName
--- @param start_spec agentic.SessionStartSpec
--- @param opts agentic.SessionReplacementOpts|nil
--- @return agentic.SessionManager|nil target
function SessionRegistry.replace(source, provider_name, start_spec, opts)
    opts = opts or {}
    local agent = opts.agent or AgentInstance.get_instance(provider_name)
    if not agent then
        return nil
    end

    if start_spec.kind == "load" then
        local existing =
            SessionRegistry.find_by_acp_session_id(start_spec.session_id, agent)
        if existing then
            if existing == source then
                return existing
            end

            if replacement_is_pending(source, existing) then
                return existing
            elseif existing:owns_ready_acp_session(start_spec.session_id) then
                commit_replacement(source, existing, opts, false)
            else
                await_replacement(source, existing, opts, false)
            end
            return existing
        end
    end

    local target = SessionRegistry.create(provider_name, start_spec, agent)
    if not target then
        return nil
    end

    await_replacement(source, target, opts, true)

    return target
end

--- @param source agentic.SessionManager|nil
--- @param target agentic.SessionManager
--- @param opts agentic.SessionReplacementOpts
--- @param destroy_target_on_rollback boolean
--- @return boolean committed
commit_replacement = function(source, target, opts, destroy_target_on_rollback)
    local target_key = target.session_key
    if not target_key or SessionRegistry.sessions[target_key] ~= target then
        return false
    end

    local function rollback_target()
        if destroy_target_on_rollback then
            SessionRegistry.destroy(target_key)
        end
    end

    if source == target then
        return true
    end

    if not source then
        -- A source-less start has no continuity donor, even if unrelated hidden
        -- sessions remain registered.
        --- @diagnostic disable-next-line: invisible
        target.widget._size = target.widget._size or {}
        SessionRegistry.show_session(target_key, opts.show_opts)
        if opts.on_commit then
            opts.on_commit(target, nil)
        end
        return true
    end

    local source_key = source.session_key
    if not source_key or SessionRegistry.sessions[source_key] ~= source then
        rollback_target()
        return false
    end

    if opts.prepare then
        local ok, err = pcall(opts.prepare, source, target)
        if not ok then
            Logger.notify(
                "Session replacement prepare error: " .. vim.inspect(err)
            )
            rollback_target()
            return false
        end
    end

    local source_tab = source.widget:get_visible_tab_id()
    local anchor = source_tab
            and source.widget:find_first_non_widget_window(source_tab)
        or nil

    if source_tab and not (anchor and BufHelpers.is_win_usable(anchor)) then
        rollback_target()
        return false
    elseif anchor and BufHelpers.is_win_usable(anchor) then
        -- `ChatWidget:show` inherits from registry recency after `show_session`
        -- captures the source's live size. Make this source the exact donor.
        SessionRegistry.set_most_recent(source_key)
        local show_opts = vim.tbl_deep_extend(
            "force",
            opts.show_opts or {},
            { focus_prompt = false }
        )
        vim.api.nvim_win_call(anchor, function()
            SessionRegistry.show_session(target_key, show_opts)
        end)
    else
        SessionRegistry.set_most_recent(target_key)
    end

    if SessionRegistry.sessions[source_key] == source then
        SessionRegistry.destroy(source_key)
    end

    if opts.on_commit then
        opts.on_commit(target, source)
    end
    return true
end

--- @param source agentic.SessionManager|nil
--- @param target agentic.SessionManager
--- @param opts agentic.SessionReplacementOpts|nil
--- @return boolean committed
function SessionRegistry.commit_replacement(source, target, opts)
    return commit_replacement(source, target, opts or {}, false)
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

--- @param session_key integer
--- @return agentic.SessionManager|nil
function SessionRegistry.get(session_key)
    return SessionRegistry.sessions[session_key]
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
    local instance = SessionRegistry.current()
        or SessionRegistry.create(nil, { kind = "new" })

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
        local session = SessionRegistry.create(provider_name, { kind = "new" })

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
