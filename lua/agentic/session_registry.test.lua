---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field, invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry", function()
    --- @type agentic.SessionRegistry
    local SessionRegistry

    --- @type table Mock for SessionManager module
    local session_manager_mock
    --- @type table Mock for ACPHealth module
    local acp_health_mock
    --- @type table Stub for Logger module
    local logger_stub
    --- @type table Mock for Config module
    local config_mock
    --- @type table Mock for DefaultConfig module
    local default_config_mock

    --- @type TestStub|nil
    local ui_select_stub
    --- @type TestStub|nil
    local create_session_stub

    --- Every `hide`/`show` appends here: ordering assertions read one list
    --- instead of comparing per-spy call counts.
    --- @type string[]
    local widget_events = {}

    --- Every `opts` `show` received, in call order. `show_session` is the only
    --- sanctioned cross-tab move (ADR 0008), so its payload is contract:
    --- `focus_prompt` and the add-to-context flags reach the widget verbatim.
    --- @type table[]
    local show_opts = {}

    --- @param visible_tab integer|nil Tab the mock widget reports as visible
    --- @param label string|nil Prefix for this session's `widget_events` entries
    --- @return table mock_session
    local function create_mock_session(visible_tab, label)
        local name = label or "session"

        local session = {
            widget = {
                get_visible_tab_id = function()
                    return visible_tab
                end,
                -- `keep_insert` recorded, not discarded: `show_session` passes
                -- `true` on both hide paths so a show can follow in the same tick
                -- without `stopinsert` latching past it.
                hide = function(_self, keep_insert)
                    widget_events[#widget_events + 1] = name
                        .. (keep_insert and ":hide(keep)" or ":hide")
                end,
                show = function(_self, opts)
                    widget_events[#widget_events + 1] = name .. ":show"
                    show_opts[#show_opts + 1] = { name = name, opts = opts }
                end,
            },
            destroy = function() end,
            is_mock = true,
        }

        function session:has_acp_session_id(acp_session_id)
            return self.session_id == acp_session_id
                or self._restoring_session_id == acp_session_id
        end

        return session
    end

    session_manager_mock = {
        new = function()
            return create_mock_session()
        end,
    }

    acp_health_mock = {
        check_configured_provider = function()
            return true
        end,
        get_default_provider_names = function()
            return {}
        end,
        is_command_available = function()
            return false
        end,
    }

    logger_stub = {
        debug = function() end,
        notify = function() end,
    }

    config_mock = {
        provider = "claude-acp",
        acp_providers = {
            ["claude-acp"] = { command = "claude-code-acp" },
            ["gemini-acp"] = { command = "gemini" },
        },
        provider_switcher = {
            hide_unhealthy_providers = true,
        },
    }

    default_config_mock = {
        provider = "claude-acp",
    }

    local original_loaded = {
        ["agentic.config"] = package.loaded["agentic.config"],
        ["agentic.config_default"] = package.loaded["agentic.config_default"],
        ["agentic.acp.acp_health"] = package.loaded["agentic.acp.acp_health"],
        ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
        ["agentic.session_manager"] = package.loaded["agentic.session_manager"],
        ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
    }

    package.loaded["agentic.config"] = config_mock
    package.loaded["agentic.config_default"] = default_config_mock
    package.loaded["agentic.acp.acp_health"] = acp_health_mock
    package.loaded["agentic.utils.logger"] = logger_stub
    package.loaded["agentic.session_manager"] = session_manager_mock
    package.loaded["agentic.session_registry"] = nil

    SessionRegistry = require("agentic.session_registry")

    for key, value in pairs(original_loaded) do
        package.loaded[key] = value
    end

    before_each(function()
        widget_events = {}
        show_opts = {}
        create_session_stub = nil
        package.loaded["agentic.session_manager"] = session_manager_mock

        acp_health_mock.check_configured_provider = function()
            return true
        end
        acp_health_mock.get_default_provider_names = function()
            return {}
        end
        acp_health_mock.is_command_available = function()
            return false
        end

        config_mock.provider = "claude-acp"
        config_mock.acp_providers = {
            ["claude-acp"] = { command = "claude-code-acp" },
            ["gemini-acp"] = { command = "gemini" },
        }
        config_mock.provider_switcher = {
            hide_unhealthy_providers = true,
        }
        default_config_mock.provider = "claude-acp"

        session_manager_mock.new = function()
            return create_mock_session()
        end

        logger_stub.debug = function() end
        logger_stub.notify = function() end
    end)

    after_each(function()
        if SessionRegistry and SessionRegistry.sessions then
            for k in pairs(SessionRegistry.sessions) do
                SessionRegistry.sessions[k] = nil
            end
            SessionRegistry._next_id = 0
            SessionRegistry._most_recent = nil
            SessionRegistry._previous_most_recent = nil
        end

        package.loaded["agentic.session_manager"] =
            original_loaded["agentic.session_manager"]
        package.loaded["agentic.config"] = original_loaded["agentic.config"]
        package.loaded["agentic.config_default"] =
            original_loaded["agentic.config_default"]
        package.loaded["agentic.acp.acp_health"] =
            original_loaded["agentic.acp.acp_health"]
        package.loaded["agentic.utils.logger"] =
            original_loaded["agentic.utils.logger"]

        if ui_select_stub then
            ui_select_stub:revert()
            ui_select_stub = nil
        end
        if create_session_stub then
            create_session_stub:revert()
            create_session_stub = nil
        end
    end)

    describe("create", function()
        it("assigns incrementing session keys", function()
            local first = SessionRegistry.create()
            local second = SessionRegistry.create()

            assert.equal(1, first.session_key)
            assert.equal(2, second.session_key)
            assert.equal(first, SessionRegistry.sessions[1])
            assert.equal(second, SessionRegistry.sessions[2])
        end)

        it("is additive: both sessions remain listed", function()
            SessionRegistry.create()
            SessionRegistry.create()

            local sessions = SessionRegistry.list()

            assert.equal(2, #sessions)
            assert.same({ 1, 2 }, {
                sessions[1].session_key,
                sessions[2].session_key,
            })
        end)

        it(
            "returns nil and stores nothing when provider not configured",
            function()
                acp_health_mock.check_configured_provider = function()
                    return false
                end

                assert.is_nil(SessionRegistry.create())
                assert.equal(0, #SessionRegistry.list())
            end
        )

        it(
            "returns nil and stores nothing when SessionManager:new returns nil",
            function()
                session_manager_mock.new = function()
                    return nil
                end

                assert.is_nil(SessionRegistry.create())
                assert.equal(0, #SessionRegistry.list())
            end
        )

        -- Restore is provider-local: `SessionManager:new` resolves its agent from
        -- `Config.provider` synchronously, so `create` borrows the global and hands
        -- it straight back. Without the borrow, restoring provider A's session
        -- while B is global sends A's ID through B.
        it("resolves the requested provider without keeping it", function()
            local provider_during_new

            session_manager_mock.new = function()
                provider_during_new = config_mock.provider
                return create_mock_session()
            end

            SessionRegistry.create("gemini-acp")

            assert.equal("gemini-acp", provider_during_new)
            assert.equal("claude-acp", config_mock.provider)
        end)

        it(
            "health-checks the requested provider and restores the current one",
            function()
                local provider_during_check
                acp_health_mock.check_configured_provider = function()
                    provider_during_check = config_mock.provider
                    return false
                end

                local session = SessionRegistry.create("gemini-acp")

                assert.is_nil(session)
                assert.equal("gemini-acp", provider_during_check)
                assert.equal("claude-acp", config_mock.provider)
                assert.equal(0, #SessionRegistry.list())
            end
        )

        it("leaves the global provider alone with no argument", function()
            local provider_during_new

            session_manager_mock.new = function()
                provider_during_new = config_mock.provider
                return create_mock_session()
            end

            SessionRegistry.create()

            assert.equal("claude-acp", provider_during_new)
            assert.equal("claude-acp", config_mock.provider)
        end)

        -- `AgentInstance.get_instance` raises for an unconfigured provider; an
        -- unprotected borrow would abandon the global on the requested provider.
        it("restores the global provider when new raises", function()
            session_manager_mock.new = function()
                error("no provider configuration")
            end

            assert.is_nil(SessionRegistry.create("gemini-acp"))
            assert.equal("claude-acp", config_mock.provider)
        end)

        it("assigns the key only after SessionManager:new returns", function()
            local previous = create_mock_session()
            SessionRegistry.sessions[99] = previous
            SessionRegistry._most_recent = previous

            local key_during_new = "unset"
            local most_recent_during_new = nil

            session_manager_mock.new = function()
                local created = create_mock_session()
                key_during_new = created.session_key
                most_recent_during_new = SessionRegistry._most_recent
                return created
            end

            local session = SessionRegistry.create()

            assert.is_nil(key_during_new)
            assert.equal(previous, most_recent_during_new)
            assert.equal(1, session.session_key)
        end)
    end)

    describe("resolve_or_create", function()
        it(
            "prefers the session visible in the current tab over _most_recent",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local hidden = create_mock_session()
                local visible = create_mock_session(current_tab)
                hidden.session_key = 1
                visible.session_key = 2

                SessionRegistry.sessions[1] = hidden
                SessionRegistry.sessions[2] = visible
                SessionRegistry._most_recent = hidden

                assert.equal(visible, SessionRegistry.resolve_or_create())

                -- The cursor moves too, not just the return value. `current()`
                -- reads it when no session is visible here, so a cursor left on
                -- `hidden` would answer the next prompt after a tab switch.
                assert.equal(visible, SessionRegistry._most_recent)
                assert.equal(hidden, SessionRegistry._previous_most_recent)
            end
        )

        it(
            "returns _most_recent when no session is visible in the current tab",
            function()
                local first = create_mock_session()
                local second = create_mock_session()
                first.session_key = 1
                second.session_key = 2

                SessionRegistry.sessions[1] = first
                SessionRegistry.sessions[2] = second
                SessionRegistry._most_recent = second

                assert.equal(second, SessionRegistry.resolve_or_create())
            end
        )

        it("creates a session when the registry is empty", function()
            local session = SessionRegistry.resolve_or_create()

            assert.is_not_nil(session)
            assert.equal(1, session.session_key)
            assert.equal(session, SessionRegistry.sessions[1])
        end)

        it("reuses the session it created on the next resolve", function()
            local first = SessionRegistry.resolve_or_create()
            local second = SessionRegistry.resolve_or_create()

            assert.equal(first, second)
            assert.equal(1, #SessionRegistry.list())
        end)

        it(
            "creates a session when _most_recent is no longer registered",
            function()
                local stale = create_mock_session()
                stale.session_key = 7
                SessionRegistry._most_recent = stale

                local session = SessionRegistry.resolve_or_create()

                assert.are_not.equal(stale, session)
                assert.equal(1, session.session_key)
            end
        )

        it(
            "never creates when a session is visible in the current tab",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local visible = create_mock_session(current_tab)
                visible.session_key = 7
                SessionRegistry.sessions[7] = visible

                local new_spy = spy.new(function() end)
                session_manager_mock.new = new_spy

                assert.equal(visible, SessionRegistry.resolve_or_create())
                assert.spy(new_spy).was.called(0)
            end
        )

        it("invokes the callback with the resolved session", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local visible = create_mock_session(current_tab)
            SessionRegistry.sessions[1] = visible

            local received = nil
            SessionRegistry.resolve_or_create(function(session)
                received = session
            end)

            assert.equal(visible, received)
        end)

        it("reports callback errors through Logger.notify", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            SessionRegistry.sessions[1] = create_mock_session(current_tab)

            local notify_spy = spy.new(function() end)
            logger_stub.notify = notify_spy

            assert.has_no_errors(function()
                SessionRegistry.resolve_or_create(function()
                    error("callback boom")
                end)
            end)

            assert.spy(notify_spy).was.called(1)
        end)
    end)

    -- Restoring an already-live ACP session ID must show that session, not build
    -- a second manager: `ACPClient.subscribers` is keyed by ACP session ID, so
    -- the second manager steals the first one's updates.
    describe("find_by_acp_session_id", function()
        it("finds the live session holding the ACP id", function()
            local other = create_mock_session()
            local match = create_mock_session()
            other.session_key = 1
            other.session_id = "acp-other"
            match.session_key = 2
            match.session_id = "acp-match"
            SessionRegistry.sessions[1] = other
            SessionRegistry.sessions[2] = match

            assert.equal(
                match,
                SessionRegistry.find_by_acp_session_id("acp-match")
            )
        end)

        it("returns nil for an id no live session holds", function()
            local session = create_mock_session()
            session.session_key = 1
            session.session_id = "acp-1"
            SessionRegistry.sessions[1] = session

            assert.is_nil(SessionRegistry.find_by_acp_session_id("acp-2"))
        end)

        it("ignores sessions with no ACP id yet", function()
            local session = create_mock_session()
            session.session_key = 1
            SessionRegistry.sessions[1] = session

            assert.is_nil(SessionRegistry.find_by_acp_session_id("acp-1"))
        end)

        it("finds a session loading the ACP id", function()
            local session = create_mock_session()
            session.session_key = 1
            session._restoring_session_id = "acp-1"
            SessionRegistry.sessions[1] = session

            assert.equal(
                session,
                SessionRegistry.find_by_acp_session_id("acp-1")
            )
        end)
    end)

    describe("create_with_current_session_guard", function()
        before_each(function()
            ui_select_stub = spy.stub(vim.ui, "select")
        end)

        --- @return TestStub stub
        local function get_select_stub()
            return ui_select_stub --[[@as TestStub]]
        end

        it("creates directly when no current session exists", function()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(function() end)

            assert.spy(select_stub).was.called(0)
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
        end)

        it("offers to keep or destroy the current session", function()
            local current = SessionRegistry.resolve_or_create()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(function() end)

            assert.spy(select_stub).was.called(1)
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))

            local items = select_stub.calls[1][1]
            assert.same({
                "Keep current session in the background",
                "Destroy current session",
            }, items)

            local on_choice = select_stub.calls[1][3]
            on_choice(nil)

            assert.equal(current, SessionRegistry.current())
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
        end)

        it("keeps the current session when creating another", function()
            local current = SessionRegistry.resolve_or_create()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(function() end)

            assert.spy(select_stub).was.called(1)
            local items = select_stub.calls[1][1]
            local on_choice = select_stub.calls[1][3]
            on_choice(items[1])

            assert.equal(current, SessionRegistry.sessions[current.session_key])
            assert.equal(2, vim.tbl_count(SessionRegistry.sessions))
        end)

        it("destroys the current session when creating another", function()
            local current = SessionRegistry.resolve_or_create()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(function() end)

            assert.spy(select_stub).was.called(1)
            local items = select_stub.calls[1][1]
            local on_choice = select_stub.calls[1][3]
            on_choice(items[2])

            assert.is_nil(SessionRegistry.sessions[current.session_key])
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
        end)

        -- Committing before the prompt left the provider switched with no session
        -- created, so the NEXT `new_session` silently used the wrong one.
        it(
            "does not commit the provider when the prompt is cancelled",
            function()
                SessionRegistry.resolve_or_create()
                local select_stub = get_select_stub()

                SessionRegistry.create_with_current_session_guard(
                    function() end,
                    "gemini-acp"
                )

                local on_choice = select_stub.calls[1][3]
                on_choice(nil)

                assert.equal("claude-acp", config_mock.provider)
                assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            end
        )

        it("commits the provider once creation proceeds", function()
            SessionRegistry.resolve_or_create()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(
                function() end,
                "gemini-acp"
            )

            assert.equal("claude-acp", config_mock.provider)

            local items = select_stub.calls[1][1]
            local on_choice = select_stub.calls[1][3]
            on_choice(items[1])

            assert.equal("gemini-acp", config_mock.provider)
            assert.equal(2, vim.tbl_count(SessionRegistry.sessions))
        end)

        it("commits the provider when there is nothing to guard", function()
            SessionRegistry.create_with_current_session_guard(
                function() end,
                "gemini-acp"
            )

            assert.equal("gemini-acp", config_mock.provider)
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
        end)

        -- `current` is captured BEFORE the async `vim.ui.select`, so switching
        -- sessions while the prompt is open leaves the closure holding a key the
        -- user is no longer looking at. "Destroy current" destroys THAT one.
        it("destroys the key captured before the prompt opened", function()
            local captured = SessionRegistry.resolve_or_create()
            local select_stub = get_select_stub()

            SessionRegistry.create_with_current_session_guard(function() end)

            local switched_to = SessionRegistry.create()
            SessionRegistry.set_most_recent(switched_to.session_key)
            assert.equal(switched_to, SessionRegistry.current())

            local items = select_stub.calls[1][1]
            local on_choice = select_stub.calls[1][3]
            on_choice(items[2])

            assert.is_nil(SessionRegistry.sessions[captured.session_key])
            assert.equal(
                switched_to,
                SessionRegistry.sessions[switched_to.session_key]
            )
        end)

        it(
            "keeps the current session when replacement creation fails",
            function()
                local current = SessionRegistry.resolve_or_create()
                create_session_stub = spy.stub(SessionRegistry, "create")
                create_session_stub:returns(nil)
                local select_stub = get_select_stub()

                SessionRegistry.create_with_current_session_guard(
                    function() end
                )

                local items = select_stub.calls[1][1]
                local on_choice = select_stub.calls[1][3]
                on_choice(items[2])

                assert.equal(
                    current,
                    SessionRegistry.sessions[current.session_key]
                )
                assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            end
        )

        it(
            "does not commit the requested provider when creation fails",
            function()
                SessionRegistry.resolve_or_create()
                create_session_stub = spy.stub(SessionRegistry, "create")
                create_session_stub:returns(nil)
                local select_stub = get_select_stub()

                SessionRegistry.create_with_current_session_guard(
                    function() end,
                    "gemini-acp"
                )

                local items = select_stub.calls[1][1]
                local on_choice = select_stub.calls[1][3]
                on_choice(items[1])

                assert.spy(create_session_stub).was.called_with("gemini-acp")
                assert.equal("claude-acp", config_mock.provider)
                assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            end
        )
    end)

    describe("destroy", function()
        it("removes the key and destroys the session once", function()
            local session = create_mock_session()
            local destroy_spy = spy.new(function() end)
            session.destroy = destroy_spy
            SessionRegistry.sessions[3] = session

            SessionRegistry.destroy(3)

            assert.is_nil(SessionRegistry.sessions[3])
            assert.spy(destroy_spy).was.called(1)
        end)

        it("repoints _most_recent at the lowest remaining key", function()
            local gone = create_mock_session()
            local kept = create_mock_session()
            gone.session_key = 1
            kept.session_key = 2
            SessionRegistry.sessions[1] = gone
            SessionRegistry.sessions[2] = kept
            SessionRegistry._most_recent = gone

            SessionRegistry.destroy(1)

            assert.equal(kept, SessionRegistry._most_recent)
        end)

        -- `_previous_most_recent` is PREFERRED over the ascending-key fallback:
        -- `list()` pushes it second, and the destroyed `_most_recent` no longer
        -- answers `registered`, so the displaced session becomes `list()[1]`.
        -- The test above cannot reach this branch — it assigns `_most_recent`
        -- directly, leaving `_previous_most_recent` nil.
        it("prefers _previous_most_recent over the lowest key", function()
            local lowest = create_mock_session()
            local displaced = create_mock_session()
            local gone = create_mock_session()
            lowest.session_key = 1
            displaced.session_key = 2
            gone.session_key = 3
            SessionRegistry.sessions[1] = lowest
            SessionRegistry.sessions[2] = displaced
            SessionRegistry.sessions[3] = gone

            -- `gone` pushes `displaced` out of `_most_recent`
            SessionRegistry.set_most_recent(2)
            SessionRegistry.set_most_recent(3)
            assert.equal(displaced, SessionRegistry._previous_most_recent)

            SessionRegistry.destroy(3)

            assert.equal(displaced, SessionRegistry._most_recent)
            assert.equal(lowest, SessionRegistry.sessions[1])
        end)

        it("clears _most_recent when the last session is destroyed", function()
            local only = create_mock_session()
            only.session_key = 1
            SessionRegistry.sessions[1] = only
            SessionRegistry._most_recent = only

            SessionRegistry.destroy(1)

            assert.is_nil(SessionRegistry._most_recent)
        end)

        it(
            "clears _previous_most_recent when the last session is destroyed",
            function()
                local only = create_mock_session()
                only.session_key = 1
                SessionRegistry.sessions[1] = only
                SessionRegistry.set_most_recent(1)

                SessionRegistry.destroy(1)

                -- The repoint plants the corpse: it writes the outgoing
                -- `_most_recent` — just destroyed — into `_previous_most_recent`,
                -- pinning its whole object graph.
                assert.is_nil(SessionRegistry._most_recent)
                assert.is_nil(SessionRegistry._previous_most_recent)
            end
        )

        it(
            "clears _previous_most_recent when that session is destroyed",
            function()
                local displaced = create_mock_session()
                local current = create_mock_session()
                displaced.session_key = 1
                current.session_key = 2
                SessionRegistry.sessions[1] = displaced
                SessionRegistry.sessions[2] = current
                SessionRegistry.set_most_recent(1)
                SessionRegistry.set_most_recent(2)

                SessionRegistry.destroy(1)

                assert.equal(current, SessionRegistry._most_recent)
                assert.is_nil(SessionRegistry._previous_most_recent)
            end
        )

        it("leaves _most_recent alone when another key is destroyed", function()
            local kept = create_mock_session()
            local other = create_mock_session()
            kept.session_key = 1
            other.session_key = 2
            SessionRegistry.sessions[1] = kept
            SessionRegistry.sessions[2] = other
            SessionRegistry._most_recent = kept

            SessionRegistry.destroy(2)

            assert.equal(kept, SessionRegistry._most_recent)
        end)

        it("is a no-op for an unknown key and does not raise", function()
            assert.has_no_errors(function()
                SessionRegistry.destroy(42)
            end)
        end)

        -- `WindowDecoration.refresh_buffer_names` re-derives surviving widgets'
        -- buffer names from the LIVE session count. Destroy is the only funnel
        -- every route reaches (`destroy_current`, `Agentic.destroy_session`, the
        -- new-session guard, session restore), so the call belongs here, not in
        -- `ChatWidget:destroy`.
        it("refreshes buffer names after the session is removed", function()
            --- @type integer|nil
            local observed_session_count = nil

            local window_decoration_stub = {
                refresh_buffer_names = function()
                    -- Read INSIDE the callback: that is what makes the ordering
                    -- load-bearing. A call before the `sessions` removal would
                    -- observe 2 here, not 1.
                    observed_session_count =
                        vim.tbl_count(SessionRegistry.sessions)
                end,
            }
            local previous = package.loaded["agentic.ui.window_decoration"]
            package.loaded["agentic.ui.window_decoration"] =
                window_decoration_stub

            local gone = create_mock_session()
            local kept = create_mock_session()
            gone.session_key = 1
            kept.session_key = 2
            SessionRegistry.sessions[1] = gone
            SessionRegistry.sessions[2] = kept

            SessionRegistry.destroy(1)

            package.loaded["agentic.ui.window_decoration"] = previous

            assert.equal(1, observed_session_count)
        end)

        it("removes the key even when session:destroy raises", function()
            local session = create_mock_session()
            session.destroy = function()
                error("destroy failed")
            end
            SessionRegistry.sessions[5] = session

            assert.has_no_errors(function()
                SessionRegistry.destroy(5)
            end)
            assert.is_nil(SessionRegistry.sessions[5])
        end)

        it("destroys the session visible in the current tab", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local hidden = create_mock_session()
            local visible = create_mock_session(current_tab)
            hidden.session_key = 1
            visible.session_key = 2
            SessionRegistry.sessions[1] = hidden
            SessionRegistry.sessions[2] = visible
            SessionRegistry._most_recent = hidden

            SessionRegistry.destroy_current()

            assert.equal(hidden, SessionRegistry.sessions[1])
            assert.is_nil(SessionRegistry.sessions[2])
        end)

        it("destroys the most recent session when none is visible", function()
            local first = create_mock_session()
            local second = create_mock_session()
            first.session_key = 1
            second.session_key = 2
            SessionRegistry.sessions[1] = first
            SessionRegistry.sessions[2] = second
            SessionRegistry._most_recent = second

            SessionRegistry.destroy_current()

            assert.equal(first, SessionRegistry.sessions[1])
            assert.is_nil(SessionRegistry.sessions[2])
        end)

        it("destroys nothing when current cannot resolve", function()
            local first = create_mock_session()
            local second = create_mock_session()
            first.session_key = 1
            second.session_key = 2
            SessionRegistry.sessions[1] = first
            SessionRegistry.sessions[2] = second
            local stale = create_mock_session()
            stale.session_key = 99
            SessionRegistry._most_recent = stale

            SessionRegistry.destroy_current()

            assert.equal(first, SessionRegistry.sessions[1])
            assert.equal(second, SessionRegistry.sessions[2])
        end)
    end)

    describe("list", function()
        it("puts _most_recent first, then ascending keys", function()
            local first = create_mock_session()
            local second = create_mock_session()
            local third = create_mock_session()
            first.session_key = 1
            second.session_key = 2
            third.session_key = 3
            SessionRegistry.sessions[1] = first
            SessionRegistry.sessions[2] = second
            SessionRegistry.sessions[3] = third
            SessionRegistry._most_recent = second

            local sessions = SessionRegistry.list()

            assert.equal(3, #sessions)
            assert.equal(second, sessions[1])
            assert.equal(first, sessions[2])
            assert.equal(third, sessions[3])
        end)

        it("puts the session _most_recent displaced second", function()
            -- Recency, not ascending key. Every path that shows a session
            -- repoints `_most_recent` BEFORE its widget's first `show`, so
            -- `ChatWidget:_inherited_size` finds itself at `list[1]` with no size
            -- and takes the donor from `list[2]`.
            local first = create_mock_session()
            local second = create_mock_session()
            local third = create_mock_session()
            first.session_key = 1
            second.session_key = 2
            third.session_key = 3
            SessionRegistry.sessions[1] = first
            SessionRegistry.sessions[2] = second
            SessionRegistry.sessions[3] = third
            SessionRegistry.set_most_recent(2)
            SessionRegistry.set_most_recent(3)

            local sessions = SessionRegistry.list()

            assert.equal(3, #sessions)
            assert.equal(third, sessions[1])
            assert.equal(second, sessions[2])
            assert.equal(first, sessions[3])
        end)

        it("orders by ascending key when _most_recent is nil", function()
            local first = create_mock_session()
            local second = create_mock_session()
            SessionRegistry.sessions[2] = second
            SessionRegistry.sessions[1] = first

            local sessions = SessionRegistry.list()

            assert.equal(first, sessions[1])
            assert.equal(second, sessions[2])
        end)

        it(
            "omits a stale _most_recent alongside registered sessions",
            function()
                local kept = create_mock_session()
                local stale = create_mock_session()
                kept.session_key = 1
                stale.session_key = 9
                SessionRegistry.sessions[1] = kept
                SessionRegistry._most_recent = stale

                local sessions = SessionRegistry.list()

                assert.equal(1, #sessions)
                assert.equal(kept, sessions[1])
            end
        )

        it("returns an empty list for an empty registry", function()
            assert.equal(0, #SessionRegistry.list())
        end)
    end)

    describe("show_session", function()
        it("hides the outgoing session before showing the target", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local outgoing = create_mock_session(current_tab, "outgoing")
            local target = create_mock_session(nil, "target")
            outgoing.session_key = 1
            target.session_key = 2
            SessionRegistry.sessions[1] = outgoing
            SessionRegistry.sessions[2] = target

            SessionRegistry.show_session(2)

            -- Order is the contract: `ChatWidget:hide` captures the outgoing size,
            -- which the incoming widget's first `show` reads back.
            assert.same({ "outgoing:hide(keep)", "target:show" }, widget_events)
            assert.equal(target, SessionRegistry._most_recent)
        end)

        it(
            "does not hide a target already visible in the current tab",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local target = create_mock_session(current_tab, "target")
                target.session_key = 1
                SessionRegistry.sessions[1] = target

                SessionRegistry.show_session(1)

                assert.same({ "target:show" }, widget_events)
            end
        )

        it("hides a target visible in another tab before showing it", function()
            local other_tab = vim.api.nvim_get_current_tabpage() + 1
            local target = create_mock_session(other_tab, "target")
            target.session_key = 1
            SessionRegistry.sessions[1] = target

            SessionRegistry.show_session(1)

            -- At most one tab per session: the widget moves, it is not cloned.
            assert.same({ "target:hide(keep)", "target:show" }, widget_events)
        end)

        it("forwards opts to the target widget verbatim", function()
            local target = create_mock_session(nil, "target")
            target.session_key = 1
            SessionRegistry.sessions[1] = target

            -- `apply_provider_switch` relies on `focus_prompt = false` surviving
            -- the hop: the focus hop inside `show_layout` would otherwise drag
            -- the cursor into the anchor window's tabpage.
            local opts = { focus_prompt = false, auto_add_to_context = false }
            SessionRegistry.show_session(1, opts)

            assert.equal(1, #show_opts)
            assert.equal("target", show_opts[1].name)
            assert.equal(opts, show_opts[1].opts)
        end)

        it("passes nil opts through when the caller gave none", function()
            local target = create_mock_session(nil, "target")
            target.session_key = 1
            SessionRegistry.sessions[1] = target

            SessionRegistry.show_session(1)

            assert.equal(1, #show_opts)
            assert.is_nil(show_opts[1].opts)
        end)

        it("is a no-op for an unknown key", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local visible = create_mock_session(current_tab, "visible")
            visible.session_key = 1
            SessionRegistry.sessions[1] = visible

            assert.has_no_errors(function()
                SessionRegistry.show_session(42)
            end)

            -- The early return precedes the eviction sweep, so a bad key cannot
            -- hide the session the user is looking at.
            assert.same({}, widget_events)
            assert.is_nil(SessionRegistry._most_recent)
        end)
    end)

    describe("set_most_recent", function()
        it("points _most_recent at the session without showing it", function()
            local session = create_mock_session()
            session.session_key = 1
            SessionRegistry.sessions[1] = session

            SessionRegistry.set_most_recent(1)

            assert.equal(session, SessionRegistry._most_recent)
            assert.same({}, widget_events)
        end)

        it("leaves _most_recent alone for an unknown key", function()
            local session = create_mock_session()
            session.session_key = 1
            SessionRegistry.sessions[1] = session
            SessionRegistry._most_recent = session

            SessionRegistry.set_most_recent(42)

            assert.equal(session, SessionRegistry._most_recent)
        end)
    end)

    describe("select_provider", function()
        --- @type table[]|nil
        local captured_items
        --- @type table|nil
        local captured_opts
        --- @type function|nil
        local captured_on_choice

        before_each(function()
            captured_items = nil
            captured_opts = nil
            captured_on_choice = nil

            ui_select_stub = spy.stub(vim.ui, "select")
            ui_select_stub:invokes(function(items, opts, on_choice)
                captured_items = items
                captured_opts = opts
                captured_on_choice = on_choice
            end)
        end)

        it("sorts healthy providers first then alphabetically", function()
            config_mock.provider_switcher = {
                hide_unhealthy_providers = false,
            }
            config_mock.acp_providers = {
                ["zeta-acp"] = { command = "zeta" },
                ["alpha-missing-acp"] = { command = "alpha-missing" },
                ["beta-acp"] = { command = "beta" },
                ["aardvark-missing-acp"] = {
                    command = "aardvark-missing",
                },
            }
            acp_health_mock.get_default_provider_names = function()
                return {
                    "zeta-acp",
                    "alpha-missing-acp",
                    "beta-acp",
                    "aardvark-missing-acp",
                }
            end
            acp_health_mock.is_command_available = function(cmd)
                return cmd == "zeta" or cmd == "beta"
            end

            SessionRegistry.select_provider(function() end)

            assert.is_not_nil(captured_items)
            assert.equal(4, #captured_items)
            assert.equal("beta-acp", captured_items[1].name)
            assert.is_true(captured_items[1].installed)
            assert.equal("zeta-acp", captured_items[2].name)
            assert.is_true(captured_items[2].installed)
            assert.equal("aardvark-missing-acp", captured_items[3].name)
            assert.is_false(captured_items[3].installed)
            assert.equal("alpha-missing-acp", captured_items[4].name)
            assert.is_false(captured_items[4].installed)
        end)

        it("marks provider without config as not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "unknown-acp" }
            end

            SessionRegistry.select_provider(function() end)

            assert.equal(1, #captured_items)
            assert.equal("unknown-acp", captured_items[1].name)
            assert.is_false(captured_items[1].installed)
        end)

        it("calls on_selected with provider name on selection", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-acp" }
            end

            local result = nil
            SessionRegistry.select_provider(function(name)
                result = name
            end)

            captured_on_choice({ name = "claude-acp", installed = true })

            assert.equal("claude-acp", result)
        end)

        it("calls on_selected with nil on cancellation", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-acp" }
            end

            local called = false
            local result = nil
            SessionRegistry.select_provider(function(name)
                called = true
                result = name
            end)

            captured_on_choice(nil)

            assert.is_true(called)
            assert.is_nil(result)
        end)

        describe("hide_unhealthy_providers", function()
            before_each(function()
                acp_health_mock.get_default_provider_names = function()
                    return { "claude-acp", "gemini-acp" }
                end
                acp_health_mock.is_command_available = function(cmd)
                    return cmd == "claude-code-acp"
                end
            end)

            it(
                "excludes not-installed providers when hide_unhealthy_providers is true",
                function()
                    config_mock.provider_switcher =
                        { hide_unhealthy_providers = true }

                    SessionRegistry.select_provider(function() end)

                    assert.equal(1, #captured_items)
                    assert.equal("claude-acp", captured_items[1].name)
                    assert.is_true(captured_items[1].installed)
                end
            )

            it(
                "includes not-installed providers when hide_unhealthy_providers is false",
                function()
                    config_mock.provider_switcher =
                        { hide_unhealthy_providers = false }

                    SessionRegistry.select_provider(function() end)

                    assert.equal(2, #captured_items)
                    assert.equal("claude-acp", captured_items[1].name)
                    assert.is_true(captured_items[1].installed)
                    assert.equal("gemini-acp", captured_items[2].name)
                    assert.is_false(captured_items[2].installed)
                end
            )
        end)

        it(
            "passes Snacks sort override for health and fuzzy ranking",
            function()
                acp_health_mock.get_default_provider_names = function()
                    return { "claude-acp" }
                end

                SessionRegistry.select_provider(function() end)

                assert.same({
                    sort = {
                        fields = { "installed", "score:desc", "idx" },
                    },
                }, captured_opts.snacks)
            end
        )

        describe("format_item labels", function()
            before_each(function()
                acp_health_mock.get_default_provider_names = function()
                    return { "claude-acp", "gemini-acp" }
                end
                acp_health_mock.is_command_available = function(cmd)
                    return cmd == "claude-code-acp"
                end
            end)

            it("appends '(current)' for Config.provider", function()
                config_mock.provider = "claude-acp"
                default_config_mock.provider = "gemini-acp"

                SessionRegistry.select_provider(function() end)

                local label = captured_opts.format_item({
                    name = "claude-acp",
                    installed = true,
                })
                assert.equal("claude-acp (current) ✓ available", label)
            end)

            it(
                "appends '(default)' for DefaultConfig.provider when not current",
                function()
                    config_mock.provider = "gemini-acp"
                    default_config_mock.provider = "claude-acp"

                    SessionRegistry.select_provider(function() end)

                    local label = captured_opts.format_item({
                        name = "claude-acp",
                        installed = true,
                    })
                    assert.equal("claude-acp (default) ✓ available", label)
                end
            )

            it("appends availability suffix based on installed flag", function()
                config_mock.provider = "none"
                default_config_mock.provider = "none"

                SessionRegistry.select_provider(function() end)

                local installed_label = captured_opts.format_item({
                    name = "claude-acp",
                    installed = true,
                })
                local missing_label = captured_opts.format_item({
                    name = "gemini-acp",
                    installed = false,
                })

                assert.equal("claude-acp ✓ available", installed_label)
                assert.equal("gemini-acp ✗ not installed", missing_label)
            end)

            it(
                "prefers '(current)' over '(default)' when both match",
                function()
                    config_mock.provider = "claude-acp"
                    default_config_mock.provider = "claude-acp"

                    SessionRegistry.select_provider(function() end)

                    local label = captured_opts.format_item({
                        name = "claude-acp",
                        installed = true,
                    })
                    assert.equal("claude-acp (current) ✓ available", label)
                end
            )
        end)
    end)
end)
