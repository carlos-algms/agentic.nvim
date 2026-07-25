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

    --- Every `hide`/`show` appends to this, so ordering assertions read one list
    --- instead of comparing per-spy call counts.
    --- @type string[]
    local widget_events = {}

    --- @param tab_page_id integer|nil
    --- @param visible_tab integer|nil Tab the mock widget reports as visible
    --- @param label string|nil Prefix for this session's `widget_events` entries
    --- @return table mock_session
    local function create_mock_session(tab_page_id, visible_tab, label)
        local name = label or "session"

        return {
            tab_page_id = tab_page_id,
            widget = {
                visible_tab = function()
                    return visible_tab
                end,
                hide = function()
                    widget_events[#widget_events + 1] = name .. ":hide"
                end,
                show = function()
                    widget_events[#widget_events + 1] = name .. ":show"
                end,
            },
            destroy = function() end,
            is_mock = true,
        }
    end

    session_manager_mock = {
        new = function(_, tab_page_id)
            return create_mock_session(tab_page_id)
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

        session_manager_mock.new = function(_, tab_page_id)
            return create_mock_session(tab_page_id)
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

        it("assigns the key only after SessionManager:new returns", function()
            local previous = create_mock_session(nil)
            SessionRegistry.sessions[99] = previous
            SessionRegistry._most_recent = previous

            local key_during_new = "unset"
            local most_recent_during_new = nil

            session_manager_mock.new = function()
                local created = create_mock_session(nil)
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

    describe("resolve", function()
        it(
            "prefers the session visible in the current tab over _most_recent",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local hidden = create_mock_session(nil)
                local visible = create_mock_session(nil, current_tab)
                hidden.session_key = 1
                visible.session_key = 2

                SessionRegistry.sessions[1] = hidden
                SessionRegistry.sessions[2] = visible
                SessionRegistry._most_recent = hidden

                assert.equal(visible, SessionRegistry.resolve())
            end
        )

        it(
            "returns _most_recent when no session is visible in the current tab",
            function()
                local first = create_mock_session(nil)
                local second = create_mock_session(nil)
                first.session_key = 1
                second.session_key = 2

                SessionRegistry.sessions[1] = first
                SessionRegistry.sessions[2] = second
                SessionRegistry._most_recent = second

                assert.equal(second, SessionRegistry.resolve())
            end
        )

        it("creates a session when the registry is empty", function()
            local session = SessionRegistry.resolve()

            assert.is_not_nil(session)
            assert.equal(1, session.session_key)
            assert.equal(session, SessionRegistry.sessions[1])
        end)

        it("reuses the session it created on the next resolve", function()
            local first = SessionRegistry.resolve()
            local second = SessionRegistry.resolve()

            assert.equal(first, second)
            assert.equal(1, #SessionRegistry.list())
        end)

        it(
            "creates a session when _most_recent is no longer registered",
            function()
                local stale = create_mock_session(nil)
                stale.session_key = 7
                SessionRegistry._most_recent = stale

                local session = SessionRegistry.resolve()

                assert.are_not.equal(stale, session)
                assert.equal(1, session.session_key)
            end
        )

        it(
            "never creates when a session is visible in the current tab",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local visible = create_mock_session(nil, current_tab)
                visible.session_key = 7
                SessionRegistry.sessions[7] = visible

                local new_spy = spy.new(function() end)
                session_manager_mock.new = new_spy

                assert.equal(visible, SessionRegistry.resolve())
                assert.spy(new_spy).was.called(0)
            end
        )

        it("invokes the callback with the resolved session", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local visible = create_mock_session(nil, current_tab)
            SessionRegistry.sessions[1] = visible

            local received = nil
            SessionRegistry.resolve(function(session)
                received = session
            end)

            assert.equal(visible, received)
        end)

        it("reports callback errors through Logger.notify", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            SessionRegistry.sessions[1] = create_mock_session(nil, current_tab)

            local notify_spy = spy.new(function() end)
            logger_stub.notify = notify_spy

            assert.has_no_errors(function()
                SessionRegistry.resolve(function()
                    error("callback boom")
                end)
            end)

            assert.spy(notify_spy).was.called(1)
        end)
    end)

    describe("destroy", function()
        it("removes the key and destroys the session once", function()
            local session = create_mock_session(nil)
            local destroy_spy = spy.new(function() end)
            session.destroy = destroy_spy
            SessionRegistry.sessions[3] = session

            SessionRegistry.destroy(3)

            assert.is_nil(SessionRegistry.sessions[3])
            assert.spy(destroy_spy).was.called(1)
        end)

        it("repoints _most_recent at the lowest remaining key", function()
            local gone = create_mock_session(nil)
            local kept = create_mock_session(nil)
            gone.session_key = 1
            kept.session_key = 2
            SessionRegistry.sessions[1] = gone
            SessionRegistry.sessions[2] = kept
            SessionRegistry._most_recent = gone

            SessionRegistry.destroy(1)

            assert.equal(kept, SessionRegistry._most_recent)
        end)

        it("clears _most_recent when the last session is destroyed", function()
            local only = create_mock_session(nil)
            only.session_key = 1
            SessionRegistry.sessions[1] = only
            SessionRegistry._most_recent = only

            SessionRegistry.destroy(1)

            assert.is_nil(SessionRegistry._most_recent)
        end)

        it("leaves _most_recent alone when another key is destroyed", function()
            local kept = create_mock_session(nil)
            local other = create_mock_session(nil)
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

        it("removes the key even when session:destroy raises", function()
            local session = create_mock_session(nil)
            session.destroy = function()
                error("destroy failed")
            end
            SessionRegistry.sessions[5] = session

            assert.has_no_errors(function()
                SessionRegistry.destroy(5)
            end)
            assert.is_nil(SessionRegistry.sessions[5])
        end)
    end)

    describe("list", function()
        it("puts _most_recent first, then ascending keys", function()
            local first = create_mock_session(nil)
            local second = create_mock_session(nil)
            local third = create_mock_session(nil)
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

        it("orders by ascending key when _most_recent is nil", function()
            local first = create_mock_session(nil)
            local second = create_mock_session(nil)
            SessionRegistry.sessions[2] = second
            SessionRegistry.sessions[1] = first

            local sessions = SessionRegistry.list()

            assert.equal(first, sessions[1])
            assert.equal(second, sessions[2])
        end)

        it(
            "omits a stale _most_recent alongside registered sessions",
            function()
                local kept = create_mock_session(nil)
                local stale = create_mock_session(nil)
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
            local outgoing = create_mock_session(nil, current_tab, "outgoing")
            local target = create_mock_session(nil, nil, "target")
            outgoing.session_key = 1
            target.session_key = 2
            SessionRegistry.sessions[1] = outgoing
            SessionRegistry.sessions[2] = target

            SessionRegistry.show_session(2)

            -- The order is the contract: `ChatWidget:hide` captures the outgoing
            -- size, which the incoming widget's first `show` reads back.
            assert.same({ "outgoing:hide", "target:show" }, widget_events)
            assert.equal(target, SessionRegistry._most_recent)
        end)

        it(
            "does not hide a target already visible in the current tab",
            function()
                local current_tab = vim.api.nvim_get_current_tabpage()
                local target = create_mock_session(nil, current_tab, "target")
                target.session_key = 1
                SessionRegistry.sessions[1] = target

                SessionRegistry.show_session(1)

                assert.same({ "target:show" }, widget_events)
            end
        )

        it("hides a target visible in another tab before showing it", function()
            local other_tab = vim.api.nvim_get_current_tabpage() + 1
            local target = create_mock_session(nil, other_tab, "target")
            target.session_key = 1
            SessionRegistry.sessions[1] = target

            SessionRegistry.show_session(1)

            -- At most one tab per session: the widget moves, it is not cloned.
            assert.same({ "target:hide", "target:show" }, widget_events)
        end)

        it("is a no-op for an unknown key", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            local visible = create_mock_session(nil, current_tab, "visible")
            visible.session_key = 1
            SessionRegistry.sessions[1] = visible

            assert.has_no_errors(function()
                SessionRegistry.show_session(42)
            end)

            -- The early return happens BEFORE the eviction sweep, so a bad key
            -- cannot hide the session the user is looking at.
            assert.same({}, widget_events)
            assert.is_nil(SessionRegistry._most_recent)
        end)
    end)

    describe("set_most_recent", function()
        it("points _most_recent at the session without showing it", function()
            local session = create_mock_session(nil, nil, "session")
            session.session_key = 1
            SessionRegistry.sessions[1] = session

            SessionRegistry.set_most_recent(1)

            assert.equal(session, SessionRegistry._most_recent)
            assert.same({}, widget_events)
        end)

        it("leaves _most_recent alone for an unknown key", function()
            local session = create_mock_session(nil, nil, "session")
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
