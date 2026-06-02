-- Tests for session pool (detach/attach) functionality
---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry pool", function()
    local SessionRegistry
    local session_manager_mock
    local config_mock
    local logger_stub

    local function create_mock_session(tab_page_id, session_id)
        return {
            tab_page_id = tab_page_id,
            session_id = session_id,
            is_generating = false,
            last_activity = os.time(),
            chat_history = { title = "Test Session " .. (session_id or "") },
            destroy = spy.new(function() end),
            detach = spy.new(function() end),
            attach = spy.new(function(self, new_tab_id)
                self.tab_page_id = new_tab_id
            end),
            widget = {
                hide = spy.new(function() end),
                show = spy.new(function() end),
            },
            is_mock = true,
        }
    end

    before_each(function()
        -- Reset package.loaded to force fresh require
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.session_manager"] = nil
        package.loaded["agentic.config"] = nil
        package.loaded["agentic.config_default"] = nil
        package.loaded["agentic.acp.acp_health"] = nil
        package.loaded["agentic.utils.logger"] = nil

        logger_stub = {
            debug = spy.new(function() end),
            notify = spy.new(function() end),
        }

        config_mock = {
            provider = "test-provider",
            acp_providers = {
                ["test-provider"] = { command = "test-cmd" },
            },
            settings = {
                pool_ttl = 0, -- Keep sessions until exit by default
            },
            provider_switcher = {
                hide_unhealthy_providers = true,
            },
        }

        session_manager_mock = {
            new = function(_, tab_page_id)
                return create_mock_session(tab_page_id, "new_" .. tab_page_id)
            end,
        }

        local acp_health_mock = {
            check_configured_provider = function()
                return true
            end,
            get_default_provider_names = function()
                return {}
            end,
            is_command_available = function()
                return true
            end,
        }

        local default_config_mock = {
            provider = "test-provider",
        }

        package.loaded["agentic.config"] = config_mock
        package.loaded["agentic.config_default"] = default_config_mock
        package.loaded["agentic.acp.acp_health"] = acp_health_mock
        package.loaded["agentic.utils.logger"] = logger_stub
        package.loaded["agentic.session_manager"] = session_manager_mock

        SessionRegistry = require("agentic.session_registry")
    end)

    after_each(function()
        -- Clean up
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.session_manager"] = nil
        package.loaded["agentic.config"] = nil
        package.loaded["agentic.config_default"] = nil
        package.loaded["agentic.acp.acp_health"] = nil
        package.loaded["agentic.utils.logger"] = nil
    end)

    describe("detach_session", function()
        it("should detach a session from tab and add to pool", function()
            local tab_id = 1
            local session = create_mock_session(tab_id, "session_1")
            SessionRegistry.sessions[tab_id] = session

            local detached = SessionRegistry.detach_session(tab_id)

            assert.equals(detached, session)
            assert.equals(SessionRegistry.sessions[tab_id], nil)
            assert.equals(SessionRegistry.pool["session_1"], session)
            assert.spy(session.detach).was_called()
            assert.spy(session.widget.hide).was_called()
        end)

        it("should generate ephemeral ID for session without session_id", function()
            local tab_id = 1
            local session = create_mock_session(tab_id, nil)
            SessionRegistry.sessions[tab_id] = session

            local detached = SessionRegistry.detach_session(tab_id)

            assert.equals(detached, session)
            assert.equals(SessionRegistry.sessions[tab_id], nil)
            assert.match(session.session_id, "^ephemeral_%d+_%d+")
            assert.equals(SessionRegistry.pool[session.session_id], session)
        end)

        it("should return nil if no session exists for tab", function()
            local detached = SessionRegistry.detach_session(999)
            assert.equals(detached, nil)
        end)
    end)

    describe("attach_session", function()
        it("should attach a pooled session to a tab", function()
            local tab_id = 1
            local session = create_mock_session(nil, "session_1")
            SessionRegistry.pool["session_1"] = session

            local attached = SessionRegistry.attach_session("session_1", tab_id)

            assert.is_true(attached)
            assert.equals(SessionRegistry.pool["session_1"], nil)
            assert.equals(SessionRegistry.sessions[tab_id], session)
            assert.spy(session.attach).was_called_with(tab_id)
            assert.spy(session.widget.show).was_called()
        end)

        it("should return false if session not in pool", function()
            local attached = SessionRegistry.attach_session("nonexistent", 1)
            assert.is_false(attached)
        end)

        it("should detach existing session on tab before attaching", function()
            local tab_id = 1
            local old_session = create_mock_session(tab_id, "old_session")
            local new_session = create_mock_session(nil, "new_session")

            SessionRegistry.sessions[tab_id] = old_session
            SessionRegistry.pool["new_session"] = new_session

            local attached = SessionRegistry.attach_session("new_session", tab_id)

            assert.is_true(attached)
            assert.equals(SessionRegistry.sessions[tab_id], new_session)
            assert.equals(SessionRegistry.pool["old_session"], old_session)
            assert.spy(old_session.detach).was_called()
        end)
    end)

    describe("new_session", function()
        it("should detach old session instead of destroying it", function()
            local tab_id = 1
            local old_session = create_mock_session(tab_id, "old_session")
            SessionRegistry.sessions[tab_id] = old_session

            spy.on(session_manager_mock, "new", function(_, tpid)
                return create_mock_session(tpid, "new_session")
            end)

            local new_session = SessionRegistry.new_session(tab_id)

            assert.equals(new_session.tab_page_id, tab_id)
            assert.equals(SessionRegistry.sessions[tab_id], new_session)
            -- Old session should be in pool, not destroyed
            assert.equals(SessionRegistry.pool["old_session"], old_session)
            assert.spy(old_session.destroy).was_not_called()
            assert.spy(old_session.detach).was_called()
        end)
    end)

    describe("destroy_closed_sessions", function()
        it("should detach sessions for closed tabs", function()
            local session1 = create_mock_session(1, "session_1")
            local session2 = create_mock_session(2, "session_2")

            SessionRegistry.sessions[1] = session1
            SessionRegistry.sessions[2] = session2

            -- Simulate tab 1 being closed
            vim.api.nvim_list_tabpages = function()
                return { 2 } -- Only tab 2 is open
            end

            SessionRegistry.destroy_closed_sessions()

            -- Session 1 should be detached (moved to pool)
            assert.equals(SessionRegistry.sessions[1], nil)
            assert.equals(SessionRegistry.pool["session_1"], session1)
            -- Session 2 should still be active
            assert.equals(SessionRegistry.sessions[2], session2)
            assert.spy(session1.detach).was_called()
        end)
    end)

    describe("prune_idle_sessions", function()
        it("should not prune when pool_ttl is 0", function()
            config_mock.settings.pool_ttl = 0

            local session = create_mock_session(nil, "session_1")
            session.last_activity = os.time() - 10000 -- Very old
            SessionRegistry.pool["session_1"] = session

            SessionRegistry.prune_idle_sessions()

            assert.equals(SessionRegistry.pool["session_1"], session)
            assert.spy(session.destroy).was_not_called()
        end)

        it("should not prune generating sessions", function()
            config_mock.settings.pool_ttl = 60

            local session = create_mock_session(nil, "session_1")
            session.is_generating = true
            session.last_activity = os.time() - 10000 -- Very old but generating
            SessionRegistry.pool["session_1"] = session

            SessionRegistry.prune_idle_sessions()

            assert.equals(SessionRegistry.pool["session_1"], session)
            assert.spy(session.destroy).was_not_called()
        end)

        it("should prune idle sessions beyond TTL", function()
            config_mock.settings.pool_ttl = 60

            local session = create_mock_session(nil, "session_1")
            session.last_activity = os.time() - 120 -- 2 minutes old
            SessionRegistry.pool["session_1"] = session

            SessionRegistry.prune_idle_sessions()

            assert.equals(SessionRegistry.pool["session_1"], nil)
            assert.spy(session.destroy).was_called()
        end)

        it("should keep sessions within TTL", function()
            config_mock.settings.pool_ttl = 120

            local session = create_mock_session(nil, "session_1")
            session.last_activity = os.time() - 60 -- 1 minute old
            SessionRegistry.pool["session_1"] = session

            SessionRegistry.prune_idle_sessions()

            assert.equals(SessionRegistry.pool["session_1"], session)
            assert.spy(session.destroy).was_not_called()
        end)
    end)

    describe("get_pool", function()
        it("should return the pool table", function()
            local pool = SessionRegistry.get_pool()
            assert.equals(type(pool), "table")
        end)

        it("should contain detached sessions", function()
            local session = create_mock_session(1, "session_1")
            SessionRegistry.pool["session_1"] = session

            local pool = SessionRegistry.get_pool()
            assert.equals(pool["session_1"], session)
        end)
    end)
end)
