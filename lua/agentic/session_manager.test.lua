--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

describe("agentic.SessionManager", function()
    describe("_on_session_update: current_mode_update", function()
        --- @type TestStub
        local notify_stub
        --- @type TestSpy
        local render_header_spy
        --- @type TestSpy
        local set_mode_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local agent_modes = AgentModes:new(
                { chat = test_bufnr },
                function() end
            )
            agent_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            set_mode_spy = spy.new(function() end)

            session = {
                agent_modes = agent_modes,
                agent = { set_mode = set_mode_spy },
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("updates state, re-renders header, notifies user", function()
            session:_on_session_update(mode_update("code"))

            assert.equal("code", session.agent_modes.current_mode_id)

            assert.spy(render_header_spy).was.called(1)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Code", render_header_spy.calls[1][3])

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])

            assert.spy(set_mode_spy).was.called(0)
        end)

        it("rejects invalid mode and keeps current state", function()
            session:_on_session_update(mode_update("nonexistent"))

            assert.equal("plan", session.agent_modes.current_mode_id)
            assert.spy(render_header_spy).was.called(0)

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_generate_welcome_header", function()
        it(
            "returns header with provider name, session id, and timestamp",
            function()
                local header = SessionManager._generate_welcome_header(
                    "Claude ACP",
                    "abc123"
                )

                assert.truthy(
                    header:match("^# Agentic %- Claude ACP %- abc123\n")
                )
                assert.truthy(header:match("\n%- %d%d%d%d%-%d%d%-%d%d"))
                assert.truthy(header:match("\n%-%-%- %-%-$"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP %- unknown\n"))
            assert.truthy(header:match("\n%-%-%- %-%-$"))
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        local original_provider

        before_each(function()
            original_provider = Config.provider
            notify_stub = spy.stub(Logger, "notify")
            -- Make vim.schedule synchronous so on_ready callbacks fire immediately
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.provider = original_provider
            schedule_stub:revert()
            notify_stub:revert()
            if get_instance_stub then
                get_instance_stub:revert()
                get_instance_stub = nil
            end
        end)

        it("blocks when is_generating is true", function()
            local session = {
                is_generating = true,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local perm_clear_spy = spy.new(function() end)
                local todo_clear_spy = spy.new(function() end)
                local widget_clear_spy = spy.new(function() end)
                local file_list_clear_spy = spy.new(function() end)
                local code_selection_clear_spy = spy.new(function() end)

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local new_session_spy = spy.new(function() end)

                local original_messages = { { type = "user", text = "hello" } }
                local mock_chat_history = {
                    messages = original_messages,
                    session_id = "old-session",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = { clear = perm_clear_spy },
                    todo_list = { clear = todo_clear_spy },
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    chat_history = mock_chat_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                -- Soft cancel: cancel_session called, session_id nil, perms+todos cleared
                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(perm_clear_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                -- Widget, file_list, code_selection NOT cleared
                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                -- Agent updated to new instance
                assert.equal(mock_new_agent, session.agent)

                -- new_session called with restore_mode
                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.is_true(opts.restore_mode)
                assert.equal("function", type(opts.on_created))
            end
        )

        it(
            "schedules history resend and sets _is_first_message in on_created",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local original_messages = { { type = "user", text = "hello" } }
                local saved_history = {
                    messages = original_messages,
                    session_id = "old",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                -- on_created captured from new_session call
                assert.is_not_nil(captured_on_created)

                -- Simulate new_session calling on_created
                -- new_session creates a fresh ChatHistory, so simulate that
                local new_timestamp = os.time()
                session.chat_history = {
                    messages = {},
                    session_id = "new",
                    timestamp = new_timestamp,
                }
                captured_on_created()

                -- After on_created: messages restored, but session metadata is from new session
                assert.same(original_messages, session.chat_history.messages)
                assert.equal("new", session.chat_history.session_id)
                assert.equal(new_timestamp, session.chat_history.timestamp)
                assert.same(original_messages, session._history_to_send)
                assert.is_true(session._is_first_message)
            end
        )

        it("no-ops soft cancel when session_id is nil", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local mock_agent = {
                provider_config = { name = "Provider" },
                cancel_session = spy.new(function() end),
                create_session = spy.new(function() end),
            }
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                on_ready(mock_agent)
                return mock_agent
            end)

            Config.provider = "some-provider"

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = { clear = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            -- cancel_session NOT called (no session to cancel)
            assert.spy(mock_agent.cancel_session).was.called(0)
            -- But permissions and todos still cleared
            assert.spy(session.permission_manager.clear).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            -- new_session still called
            assert.spy(session.new_session).was.called(1)
        end)
    end)
end)
