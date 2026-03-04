---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
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

    --- @param tab_page_id integer
    --- @return table mock_session
    local function create_mock_session(tab_page_id)
        return {
            tab_page_id = tab_page_id,
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
        default_config_mock.provider = "claude-acp"

        session_manager_mock.new = function(_, tab_page_id)
            return create_mock_session(tab_page_id)
        end
    end)

    after_each(function()
        if SessionRegistry and SessionRegistry.sessions then
            for k in pairs(SessionRegistry.sessions) do
                SessionRegistry.sessions[k] = nil
            end
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

    describe("get_session_for_tab_page", function()
        it("creates new session when none exists for tabpage", function()
            local tab_id = 1
            local session = SessionRegistry.get_session_for_tab_page(tab_id)

            assert.is_not_nil(session)
            assert.is_true(session.is_mock)
            assert.equal(tab_id, session.tab_page_id)
        end)

        it("returns existing session for tabpage", function()
            local tab_id = 1
            local session1 = SessionRegistry.get_session_for_tab_page(tab_id)
            local session2 = SessionRegistry.get_session_for_tab_page(tab_id)

            assert.equal(session1, session2)
        end)

        it("creates separate sessions for different tabpages", function()
            local tab1_id = 1
            local tab2_id = 2

            local session1 = SessionRegistry.get_session_for_tab_page(tab1_id)
            local session2 = SessionRegistry.get_session_for_tab_page(tab2_id)

            assert.is_not_nil(session1)
            assert.is_not_nil(session2)
            assert.are_not.equal(session1, session2)
            assert.equal(tab1_id, session1.tab_page_id)
            assert.equal(tab2_id, session2.tab_page_id)
        end)

        it("uses current tabpage when tab_page_id is nil", function()
            local current_tab_id = vim.api.nvim_get_current_tabpage()
            local session = SessionRegistry.get_session_for_tab_page(nil)

            assert.is_not_nil(session)
            assert.equal(current_tab_id, session.tab_page_id)
        end)

        it("calls callback with session when provided", function()
            local tab_id = 1
            local callback_called = false
            --- @type table|nil
            local callback_session = nil

            SessionRegistry.get_session_for_tab_page(tab_id, function(session)
                callback_called = true
                callback_session = session
            end)

            assert.is_true(callback_called)
            assert.is_not_nil(callback_session)
            if callback_session then
                assert.equal(tab_id, callback_session.tab_page_id)
            end
        end)

        it(
            "calls callback with existing session when already exists",
            function()
                local tab_id = 1
                local existing_session =
                    SessionRegistry.get_session_for_tab_page(tab_id)

                local callback_called = false
                local callback_session = nil

                SessionRegistry.get_session_for_tab_page(
                    tab_id,
                    function(session)
                        callback_called = true
                        callback_session = session
                    end
                )

                assert.is_true(callback_called)
                assert.equal(existing_session, callback_session)
            end
        )

        it(
            "returns nil and does not call callback when provider not configured",
            function()
                acp_health_mock.check_configured_provider = function()
                    return false
                end

                local callback_called = false

                local session = SessionRegistry.get_session_for_tab_page(
                    1,
                    function()
                        callback_called = true
                    end
                )

                assert.is_nil(session)
                assert.is_false(callback_called)
            end
        )

        it(
            "returns nil and skips registry when SessionManager:new returns nil",
            function()
                session_manager_mock.new = function()
                    return nil
                end

                local session = SessionRegistry.get_session_for_tab_page(1)

                assert.is_nil(session)
                assert.is_nil(SessionRegistry.sessions[1])
            end
        )
    end)

    describe("new_session", function()
        it("creates new session when none exists", function()
            local tab_id = 1
            local session = SessionRegistry.new_session(tab_id)

            assert.is_not_nil(session)
            assert.equal(tab_id, session.tab_page_id)
        end)

        it("destroys existing session before creating new one", function()
            local tab_id = 1

            local first_session = create_mock_session(tab_id)
            local destroy_spy = spy.new(function() end)
            first_session.destroy = destroy_spy
            SessionRegistry.sessions[tab_id] = first_session

            local new_session = SessionRegistry.new_session(tab_id)

            assert.spy(destroy_spy).was.called(1)

            assert.are_not.equal(first_session, new_session)
            assert.equal(tab_id, new_session.tab_page_id)
        end)

        it("handles destroy errors gracefully", function()
            local tab_id = 1

            -- Create session with destroy that throws error
            local error_session = create_mock_session(tab_id)
            error_session.destroy = function()
                error("destroy failed")
            end
            SessionRegistry.sessions[tab_id] = error_session

            local new_session = SessionRegistry.new_session(tab_id)

            assert.is_not_nil(new_session)
            assert.equal(tab_id, new_session.tab_page_id)
        end)

        it("uses current tabpage when tab_page_id is nil", function()
            local current_tab_id = vim.api.nvim_get_current_tabpage()
            local session = SessionRegistry.new_session(nil)

            assert.is_not_nil(session)
            assert.equal(current_tab_id, session.tab_page_id)
        end)

        it("replaces session in registry", function()
            local tab_id = 1

            local first_session =
                SessionRegistry.get_session_for_tab_page(tab_id)

            local new_session = SessionRegistry.new_session(tab_id)

            assert.equal(new_session, SessionRegistry.sessions[tab_id])
            assert.are_not.equal(first_session, new_session)
        end)

        it("recreates session only for specified tabpage", function()
            local tab1_id = 1
            local tab2_id = 2

            local session1_v1 =
                SessionRegistry.get_session_for_tab_page(tab1_id)
            local session2_v1 =
                SessionRegistry.get_session_for_tab_page(tab2_id)

            local session1_v2 = SessionRegistry.new_session(tab1_id)

            assert.are_not.equal(session1_v1, session1_v2)
            assert.equal(session2_v1, SessionRegistry.sessions[tab2_id])
        end)
    end)

    describe("destroy_session", function()
        it("destroys existing session and removes from registry", function()
            local tab_id = 1

            local session = create_mock_session(tab_id)
            local destroy_spy = spy.new(function() end)
            session.destroy = destroy_spy
            SessionRegistry.sessions[tab_id] = session

            SessionRegistry.destroy_session(tab_id)

            assert.spy(destroy_spy).was.called(1)
            assert.is_nil(SessionRegistry.sessions[tab_id])
        end)

        it("does nothing when no session exists for tabpage", function()
            local tab_id = 1

            SessionRegistry.destroy_session(tab_id)

            assert.is_nil(SessionRegistry.sessions[tab_id])
        end)

        it("uses current tabpage when tab_page_id is nil", function()
            local current_tab_id = vim.api.nvim_get_current_tabpage()

            local session = create_mock_session(current_tab_id)
            local destroy_spy = spy.new(function() end)
            session.destroy = destroy_spy
            SessionRegistry.sessions[current_tab_id] = session

            SessionRegistry.destroy_session(nil)

            assert.spy(destroy_spy).was.called(1)
            assert.is_nil(SessionRegistry.sessions[current_tab_id])
        end)

        it("handles destroy errors gracefully", function()
            local tab_id = 1

            local error_session = create_mock_session(tab_id)
            error_session.destroy = function()
                error("destroy failed")
            end
            SessionRegistry.sessions[tab_id] = error_session

            SessionRegistry.destroy_session(tab_id)

            assert.is_nil(SessionRegistry.sessions[tab_id])
        end)

        it("only affects specified tabpage", function()
            local tab1_id = 1
            local tab2_id = 2

            SessionRegistry.sessions[tab1_id] = create_mock_session(tab1_id)
            SessionRegistry.sessions[tab2_id] = create_mock_session(tab2_id)

            SessionRegistry.destroy_session(tab1_id)

            assert.is_nil(SessionRegistry.sessions[tab1_id])
            assert.is_not_nil(SessionRegistry.sessions[tab2_id])
        end)
    end)

    describe("sessions weak table", function()
        it("uses weak value metatable", function()
            local metatable = getmetatable(SessionRegistry.sessions)

            assert.is_not_nil(metatable)
            assert.equal("v", metatable.__mode)
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

        it("sorts installed providers before not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-acp", "gemini-acp" }
            end
            acp_health_mock.is_command_available = function(cmd)
                return cmd == "gemini"
            end

            SessionRegistry.select_provider(function() end)

            assert.is_not_nil(captured_items)
            assert.equal(2, #captured_items)
            assert.equal("gemini-acp", captured_items[1].name)
            assert.is_true(captured_items[1].installed)
            assert.equal("claude-acp", captured_items[2].name)
            assert.is_false(captured_items[2].installed)
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
