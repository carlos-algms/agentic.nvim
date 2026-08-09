local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    local SessionRestore
    local SessionRegistry
    local AgentInstance
    local Logger
    local replace_stub
    local find_stub
    local commit_stub
    local notify_stub
    local select_stub
    local schedule_stub
    local current_stub
    local get_instance_stub
    local extra_stubs

    local function new_agent()
        local agent = {
            agent_capabilities = {
                loadSession = true,
                sessionCapabilities = { list = true },
            },
            list_calls = 0,
        }

        function agent:when_ready(on_ready, on_failure)
            self.ready_callback = on_ready
            self.failure_callback = on_failure
        end

        function agent:list_sessions(_cwd, callback)
            self.list_calls = self.list_calls + 1
            callback(self.list_result or { sessions = {} }, self.list_error)
        end

        return agent
    end

    local function use_context(agent, source)
        current_stub:returns(source)
        get_instance_stub:returns(agent)
        if source then
            source.agent = agent
            source.provider_name = "claude-acp"
        end
    end

    before_each(function()
        extra_stubs = {}
        SessionRegistry = require("agentic.session_registry")
        AgentInstance = require("agentic.acp.agent_instance")
        Logger = require("agentic.utils.logger")
        replace_stub = spy.stub(SessionRegistry, "replace")
        find_stub = spy.stub(SessionRegistry, "find_by_acp_session_id")
        commit_stub = spy.stub(SessionRegistry, "commit_replacement")
        notify_stub = spy.stub(Logger, "notify")
        select_stub = spy.stub(vim.ui, "select")
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            callback()
        end)
        current_stub = spy.stub(SessionRegistry, "current")
        get_instance_stub = spy.stub(AgentInstance, "get_instance")

        package.loaded["agentic.session_restore"] = nil
        SessionRestore = require("agentic.session_restore")
    end)

    after_each(function()
        for _, stub in ipairs(extra_stubs) do
            stub:revert()
        end
        replace_stub:revert()
        find_stub:revert()
        commit_stub:revert()
        notify_stub:revert()
        select_stub:revert()
        schedule_stub:revert()
        current_stub:revert()
        get_instance_stub:revert()
        package.loaded["agentic.session_restore"] = nil
    end)

    it("lists through context without creating a manager", function()
        local agent = new_agent()
        agent.list_result = {
            sessions = {
                { sessionId = "one", cwd = "/tmp", title = "One" },
            },
        }

        use_context(agent, nil)
        SessionRestore.show_picker()
        assert.equal(0, agent.list_calls)
        agent.ready_callback(agent)

        assert.equal(1, agent.list_calls)
        assert.spy(replace_stub).was.called(0)
        assert.spy(select_stub).was.called(1)
    end)

    it("creates one load target only after selection", function()
        local agent = new_agent()
        agent.list_result = {
            sessions = {
                { sessionId = "one", cwd = "/tmp", title = "One" },
            },
        }
        local on_choice
        select_stub:invokes(function(_items, _opts, callback)
            on_choice = callback
        end)

        use_context(agent, nil)
        SessionRestore.show_picker()
        agent.ready_callback(agent)
        assert.spy(replace_stub).was.called(0)
        on_choice({
            session_id = "one",
            title = "One",
            updated_at = "2026-01-01",
        })

        assert.spy(replace_stub).was.called(1)
        local spec = replace_stub.calls[1][3]
        assert.equal("load", spec.kind)
        assert.equal("one", spec.session_id)
    end)

    it("creates nothing when a nil-source picker is cancelled", function()
        local agent = new_agent()
        agent.list_result = {
            sessions = { { sessionId = "one", cwd = "/tmp" } },
        }
        local on_choice
        select_stub:invokes(function(_items, _opts, callback)
            on_choice = callback
        end)

        use_context(agent, nil)
        SessionRestore.show_picker()
        agent.ready_callback(agent)
        on_choice(nil)

        assert.spy(replace_stub).was.called(0)
    end)

    it("waits for readiness and lists exactly once", function()
        local agent = new_agent()

        use_context(agent, nil)
        SessionRestore.show_picker()
        assert.equal(0, agent.list_calls)
        agent.ready_callback(agent)
        assert.equal(1, agent.list_calls)
    end)

    it("creates nothing when readiness fails", function()
        local agent = new_agent()

        use_context(agent, nil)
        SessionRestore.show_picker()
        agent.failure_callback({ code = -32000, message = "offline" })

        assert.equal(0, agent.list_calls)
        assert.spy(replace_stub).was.called(0)
        assert
            .spy(notify_stub).was
            .called_with("Failed to list sessions: offline", vim.log.levels.WARN)
    end)

    it("creates no placeholder when provider resolution fails", function()
        current_stub:returns(nil)
        get_instance_stub:returns(nil)

        SessionRestore.show_picker()

        assert.spy(get_instance_stub).was.called(1)
        assert.spy(replace_stub).was.called(0)
        assert.spy(select_stub).was.called(0)
    end)

    it("passes nil source with no prepare callback", function()
        local agent = new_agent()

        use_context(agent, nil)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.spy(replace_stub).was.called(1)
        assert.is_nil(replace_stub.calls[1][1])
        local opts = replace_stub.calls[1][4]
        assert.equal(agent, opts.agent)
        assert.is_nil(opts.prepare)
    end)

    it("removes the only nil-source target when loading fails", function()
        local agent = new_agent()
        local target = { session_key = 22 }
        function target:on_session_ready(_on_ready, on_failure)
            self.failure_callback = on_failure
        end

        replace_stub:revert()
        local create_stub = spy.stub(SessionRegistry, "create")
        create_stub:returns(target)
        extra_stubs[#extra_stubs + 1] = create_stub
        local destroy_stub = spy.stub(SessionRegistry, "destroy")
        extra_stubs[#extra_stubs + 1] = destroy_stub
        SessionRegistry.sessions[22] = target

        use_context(agent, nil)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)
        target.failure_callback(target)

        assert.spy(destroy_stub).was.called_with(22)
        SessionRegistry.sessions[22] = nil
    end)

    it("shows a successful target before destroying its source", function()
        local agent = new_agent()
        local current_tab = vim.api.nvim_get_current_tabpage()
        local current_win = vim.api.nvim_get_current_win()
        local source = {
            session_key = 21,
            widget = {
                get_visible_tab_id = function()
                    return current_tab
                end,
                find_first_non_widget_window = function()
                    return current_win
                end,
            },
        }
        local target = { session_key = 22 }
        function target:on_session_ready(on_ready, on_failure)
            self.ready_callback = on_ready
            self.failure_callback = on_failure
        end

        replace_stub:revert()
        commit_stub:revert()
        local create_stub = spy.stub(SessionRegistry, "create")
        create_stub:returns(target)
        extra_stubs[#extra_stubs + 1] = create_stub
        local events = {}
        local show_stub = spy.stub(SessionRegistry, "show_session")
        show_stub:invokes(function()
            events[#events + 1] = "show"
        end)
        extra_stubs[#extra_stubs + 1] = show_stub
        local destroy_stub = spy.stub(SessionRegistry, "destroy")
        destroy_stub:invokes(function()
            events[#events + 1] = "destroy"
        end)
        extra_stubs[#extra_stubs + 1] = destroy_stub
        SessionRegistry.sessions[21] = source
        SessionRegistry.sessions[22] = target

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)
        target.ready_callback(target)

        assert.same({ "show", "destroy" }, events)
        assert.spy(destroy_stub).was.called_with(21)
        SessionRegistry.sessions[21] = nil
        SessionRegistry.sessions[22] = nil
    end)

    it("leaves the source intact when its load target fails", function()
        local agent = new_agent()
        local source = { session_key = 21 }
        local target = { session_key = 22 }
        function target:on_session_ready(on_ready, on_failure)
            self.ready_callback = on_ready
            self.failure_callback = on_failure
        end

        replace_stub:revert()
        local create_stub = spy.stub(SessionRegistry, "create")
        create_stub:returns(target)
        extra_stubs[#extra_stubs + 1] = create_stub
        local destroy_stub = spy.stub(SessionRegistry, "destroy")
        extra_stubs[#extra_stubs + 1] = destroy_stub
        SessionRegistry.sessions[21] = source
        SessionRegistry.sessions[22] = target

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)
        target.failure_callback(target)

        assert.spy(destroy_stub).was.called_with(22)
        assert.equal(source, SessionRegistry.sessions[21])
        SessionRegistry.sessions[21] = nil
        SessionRegistry.sessions[22] = nil
    end)

    it(
        "delegates destructive success and rollback to registry replacement",
        function()
            local agent = new_agent()
            local source = { session_key = 1 }

            use_context(agent, source)
            SessionRestore.restore_by_id("one")
            agent.ready_callback(agent)

            assert.spy(replace_stub).was.called_with(
                source,
                "claude-acp",
                { kind = "load", session_id = "one" },
                { agent = agent }
            )
        end
    )

    it("delegates an existing target to registry replacement", function()
        local agent = new_agent()
        local source = { session_key = 1 }
        find_stub:returns({ session_key = 2 })

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.spy(replace_stub).was.called_with(
            source,
            "claude-acp",
            { kind = "load", session_id = "one" },
            { agent = agent }
        )
        assert.spy(commit_stub).was.called(0)
    end)

    it("delegates the same-manager target to the registry no-op", function()
        local agent = new_agent()
        local source = { session_key = 1 }
        find_stub:returns(source)

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.spy(commit_stub).was.called(0)
        assert.spy(replace_stub).was.called(1)
    end)

    it("reuses an existing target without load capability", function()
        local agent = new_agent()
        agent.agent_capabilities.loadSession = false
        local source = { session_key = 1 }
        find_stub:returns({ session_key = 2 })

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.spy(replace_stub).was.called(1)
        assert.spy(notify_stub).was.called(0)
    end)

    it("deduplicates repeated restore while the target is pending", function()
        local agent = new_agent()
        local source = { session_key = 1 }
        local target = { ready_callback_count = 0 }
        function target:owns_ready_acp_session()
            return false
        end
        function target:on_session_ready(callback)
            self.ready_callback_count = self.ready_callback_count + 1
            self.ready_callback = callback
        end
        find_stub:returns(target)
        replace_stub:revert()

        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)
        use_context(agent, source)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.equal(1, target.ready_callback_count)
    end)

    it("rejects unsupported load without creating a target", function()
        local agent = new_agent()
        agent.agent_capabilities.loadSession = false

        use_context(agent, nil)
        SessionRestore.restore_by_id("one")
        agent.ready_callback(agent)

        assert.spy(replace_stub).was.called(0)
        assert.spy(notify_stub).was.called(1)
    end)

    it("passes optional list metadata only in the local start spec", function()
        local agent = new_agent()
        local source = {
            session_key = 1,
            widget = "source widget",
            chat_history = { title = "source title" },
        }
        agent.list_result = {
            sessions = {
                {
                    sessionId = "one",
                    cwd = "/tmp",
                    title = "Local title",
                    updatedAt = "2026-08-09T12:00:00Z",
                },
            },
        }
        local items
        local on_choice
        select_stub:invokes(function(values, _opts, callback)
            items = values
            on_choice = callback
        end)

        use_context(agent, source)
        SessionRestore.show_picker()
        agent.ready_callback(agent)
        on_choice(items[1])

        local spec = replace_stub.calls[1][3]
        assert.equal("Local title", spec.title)
        assert.equal("2026-08-09T12:00:00Z", spec.timestamp)
        assert.equal(source, replace_stub.calls[1][1])
        assert.same({ agent = agent }, replace_stub.calls[1][4])
        assert.equal("source widget", source.widget)
        assert.equal("source title", source.chat_history.title)
    end)
end)
