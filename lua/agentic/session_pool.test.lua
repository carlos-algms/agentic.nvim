-- Tests for session pool (detach/attach) functionality
---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry pool", function()
    local SessionRegistry
    local session_manager_mock
    local logger_stub

    local function create_mock_session(tab_page_id, session_id)
        return {
            tab_page_id = tab_page_id,
            session_id = session_id,
            is_generating = false,
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
        }
    end

    before_each(function()
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

        session_manager_mock = {
            new = function(_, tab_page_id)
                return create_mock_session(tab_page_id, "new_" .. tab_page_id)
            end,
        }

        package.loaded["agentic.config"] = {
            provider = "test-provider",
            acp_providers = { ["test-provider"] = { command = "test-cmd" } },
            provider_switcher = { hide_unhealthy_providers = true },
        }
        package.loaded["agentic.config_default"] =
            { provider = "test-provider" }
        package.loaded["agentic.acp.acp_health"] = {
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
        package.loaded["agentic.utils.logger"] = logger_stub
        package.loaded["agentic.session_manager"] = session_manager_mock

        SessionRegistry = require("agentic.session_registry")
    end)

    after_each(function()
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

            assert.equal(detached, session)
            assert.equal(SessionRegistry.sessions[tab_id], nil)
            assert.equal(SessionRegistry.pool["session_1"], session)
            assert.spy(session.detach).was.called()
        end)

        it("should not add to pool when session has no session_id", function()
            local tab_id = 1
            local session = create_mock_session(tab_id, nil)
            SessionRegistry.sessions[tab_id] = session

            local detached = SessionRegistry.detach_session(tab_id)

            assert.equal(detached, session)
            assert.equal(SessionRegistry.sessions[tab_id], nil)
            -- Session without an ACP session_id is hidden but not pooled
            assert.equal(next(SessionRegistry.pool), nil)
        end)

        it("should return nil if no session exists for tab", function()
            local detached = SessionRegistry.detach_session(999)
            assert.equal(detached, nil)
        end)
    end)

    describe("attach_session", function()
        it("should attach a pooled session to a tab", function()
            local tab_id = 1
            local session = create_mock_session(nil, "session_1")
            SessionRegistry.pool["session_1"] = session

            local attached = SessionRegistry.attach_session("session_1", tab_id)

            assert.is_true(attached)
            assert.equal(SessionRegistry.pool["session_1"], nil)
            assert.equal(SessionRegistry.sessions[tab_id], session)
            assert.spy(session.attach).was.called()
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

            local attached =
                SessionRegistry.attach_session("new_session", tab_id)

            assert.is_true(attached)
            assert.equal(SessionRegistry.sessions[tab_id], new_session)
            -- Old session detached into pool (has a session_id)
            assert.equal(SessionRegistry.pool["old_session"], old_session)
            assert.spy(old_session.detach).was.called()
        end)
    end)

    describe("new_session", function()
        it("should destroy old session and create a fresh one", function()
            local tab_id = 1
            local old_session = create_mock_session(tab_id, "old_session")
            SessionRegistry.sessions[tab_id] = old_session

            local result = SessionRegistry.new_session(tab_id)

            assert.equal(result.tab_page_id, tab_id)
            assert.equal(SessionRegistry.sessions[tab_id], result)
            -- Old session must be destroyed (not merely detached)
            assert.spy(old_session.destroy).was.called()
            assert.equal(SessionRegistry.pool["old_session"], nil)
        end)
    end)

    describe("destroy_closed_sessions", function()
        it("should destroy sessions for closed tabs", function()
            local session1 = create_mock_session(1, "session_1")
            local session2 = create_mock_session(2, "session_2")

            SessionRegistry.sessions[1] = session1
            SessionRegistry.sessions[2] = session2

            vim.api.nvim_list_tabpages = function()
                return { 2 }
            end

            SessionRegistry.destroy_closed_sessions()

            assert.equal(SessionRegistry.sessions[1], nil)
            assert.equal(SessionRegistry.sessions[2], session2)
            assert.spy(session1.destroy).was.called()
            -- Closed-tab sessions must not leak into pool
            assert.equal(SessionRegistry.pool["session_1"], nil)
        end)
    end)

    describe("get_pool", function()
        it("should return the pool table", function()
            local pool = SessionRegistry.get_pool()
            assert.equal(type(pool), "table")
        end)

        it("should contain detached sessions", function()
            local session = create_mock_session(1, "session_1")
            SessionRegistry.pool["session_1"] = session

            local pool = SessionRegistry.get_pool()
            assert.equal(pool["session_1"], session)
        end)
    end)
end)
