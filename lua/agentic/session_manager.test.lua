--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

--- @return agentic.SessionManager manager
local function new_test_manager()
    local Config = require("agentic.config")
    local AgentInstance = require("agentic.acp.agent_instance")
    local agent = AgentInstance.get_instance(Config.provider)
    return SessionManager:new(agent, Config.provider)
end

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
        local refresh_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            refresh_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            session = {
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    get_mode_name = function(_self, mode_id)
                        local mode = legacy_modes:get_mode(mode_id)
                        return mode and mode.name or nil
                    end,
                },
                widget = {
                    render_header = render_header_spy,
                    schedule_header_refresh = refresh_spy,
                    buf_nrs = { chat = test_bufnr },
                    get_visible_tab_id = function() end,
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

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(1)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Code", render_header_spy.calls[1][3])
            assert.spy(refresh_spy).was.called(1)

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])
        end)

        it("rejects invalid mode and keeps current state", function()
            session:_on_session_update(mode_update("nonexistent"))

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(render_header_spy).was.called(0)
            assert.spy(refresh_spy).was.called(0)

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type TestSpy
        local refresh_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr
        --- @type TestStub
        local keymap_stub

        before_each(function()
            render_header_spy = spy.new(function() end)
            refresh_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new({ chat = test_bufnr }, {
                set_mode = function() end,
                set_model = function() end,
                set_thought_level = function() end,
            })

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    schedule_header_refresh = refresh_spy,
                    buf_nrs = { chat = test_bufnr },
                    get_visible_tab_id = function() end,
                },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            keymap_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("sets config options and updates header on mode", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            }

            session:_on_session_update(update)

            assert.is_not_nil(session.config_options.mode)
            assert.equal("plan", session.config_options.mode.currentValue)
            assert.spy(render_header_spy).was.called(1)
            assert.equal("Mode: Plan", render_header_spy.calls[1][3])
            assert.spy(refresh_spy).was.called(1)
        end)
    end)

    describe("_start_spinner_if_generating", function()
        --- @type TestSpy
        local start_spy
        --- @type agentic.SessionManager
        local session

        before_each(function()
            start_spy = spy.new(function() end)
            session = {
                is_generating = false,
                status_animation = { start = start_spy },
                _start_spinner = SessionManager._start_spinner,
            } --[[@as agentic.SessionManager]]
        end)

        it("skips spinner when no user turn is active (opener case)", function()
            session:_start_spinner("generating")

            assert.spy(start_spy).was.called(0)
        end)

        it("starts spinner when a user turn is active", function()
            session.is_generating = true

            session:_start_spinner("generating")

            assert.spy(start_spy).was.called(1)
            assert.equal("generating", start_spy.calls[1][2])
        end)
    end)

    describe("FileChangedShell autocommand", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("sets fcs_choice to reload when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("reload", child.v.fcs_choice)
        end)
    end)

    describe("can_submit_prompt", function()
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub

        --- @type fun()[]
        local schedule_queue = {}

        local function flush_schedule()
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end
        end

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_queue = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                }
                fake.agent_info = {}
                function fake:when_ready(on_ready, _on_failure)
                    vim.schedule(function()
                        on_ready(fake)
                    end)
                end
                function fake:create_session(_h, cb)
                    cb({
                        sessionId = "test-session",
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end
                function fake:cancel_session() end
                if callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it("returns false when connection error occurred", function()
            local session = new_test_manager()
            flush_schedule()
            session.session_id = "test-session" --[[@as string]]
            session._connection_error = true

            local result = session:can_submit_prompt()

            assert.is_false(result)
            assert.spy(notify_stub).was.called()
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Cc]onnection"))
        end)
    end)

    describe("on_session_ready", function()
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub
        local agent_state
        local invoke_agent_callback
        local create_response
        local create_error

        --- @type fun()[]
        local schedule_queue = {}

        local function flush_schedule()
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end
        end

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_queue = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)
            agent_state = "ready"
            invoke_agent_callback = true
            create_response = {
                sessionId = "test-session",
                configOptions = nil,
                modes = nil,
                models = nil,
            }
            create_error = nil
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = agent_state
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                }
                fake.agent_info = {}
                function fake:when_ready(on_ready, on_failure)
                    vim.schedule(function()
                        if
                            agent_state == "error"
                            or agent_state == "disconnected"
                        then
                            if on_failure then
                                on_failure({
                                    code = -32000,
                                    message = agent_state,
                                })
                            end
                        else
                            on_ready(fake)
                        end
                    end)
                end
                function fake:create_session(_h, cb)
                    cb(create_response, create_error)
                end
                function fake:cancel_session() end
                if callback and invoke_agent_callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it("queues the callback via schedule when session_id exists", function()
            local session = new_test_manager()
            flush_schedule()
            session.session_id = "ready-session" --[[@as string]]

            local callback_called = false
            local received_session = nil
            session:on_session_ready(function(s)
                callback_called = true
                received_session = s
            end)

            -- Queued via vim.schedule, so not called yet
            assert.is_false(callback_called)

            flush_schedule()

            assert.is_true(callback_called)
            assert.equal(session, received_session)
        end)

        it("queues callback when session_id is nil", function()
            local session = new_test_manager()
            -- Never flushed: session_id stays nil, so the callback must queue

            local callback_called = false
            session:on_session_ready(function()
                callback_called = true
            end)

            assert.is_false(callback_called)
            assert.equal(1, #session._session_ready_callbacks)
        end)

        it("fires the failure callback when session creation fails", function()
            create_response = nil
            create_error = { message = "creation failed" }
            local session = new_test_manager()
            local ready_spy = spy.new(function() end)
            local failure_spy = spy.new(function() end)

            session:on_session_ready(ready_spy, failure_spy)
            session:start({ kind = "new" })
            flush_schedule()

            assert.spy(ready_spy).was.called(0)
            assert.spy(failure_spy).was.called_with(session)
            assert.equal(0, #session._session_ready_callbacks)
        end)

        it("ignores a cached-client error callback after destroy", function()
            agent_state = "error"
            local session = new_test_manager()

            session:destroy()

            assert.has_no_errors(function()
                flush_schedule()
            end)
            assert.is_false(session._connection_error)
        end)

        it("ignores a deferred connection error after destroy", function()
            agent_state = "error"
            invoke_agent_callback = false
            local session = new_test_manager()

            session:destroy()

            assert.has_no_errors(function()
                flush_schedule()
            end)
            assert.is_false(session._connection_error)
        end)

        it("ignores an already-ready callback after destroy", function()
            local session = new_test_manager()
            flush_schedule()
            session.session_id = "ready-session" --[[@as string]]
            local ready_spy = spy.new(function() end)
            session:on_session_ready(ready_spy)

            session:destroy()
            flush_schedule()

            assert.spy(ready_spy).was.called(0)
        end)
    end)

    describe("_handle_connection_error", function()
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function() end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                }
                fake.agent_info = {}
                function fake:create_session(_h, cb)
                    cb({
                        sessionId = "test-session",
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end
                function fake:cancel_session() end
                if callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it("clears session_ready_callbacks", function()
            local session = new_test_manager()
            -- Stays uninitialized: schedule is a no-op here
            session:on_session_ready(function() end)
            assert.equal(1, #session._session_ready_callbacks)

            session:_handle_connection_error()

            assert.equal(0, #session._session_ready_callbacks)
            assert.is_true(session._connection_error)
        end)

        it("leaves state and UI unchanged after destroy", function()
            local stop_spy = spy.new(function() end)
            local write_spy = spy.new(function() end)
            local callbacks = { function() end }
            local session = {
                _destroyed = true,
                _connection_error = false,
                _session_ready_callbacks = callbacks,
                is_generating = true,
                status_animation = { stop = stop_spy },
                message_writer = { write_message = write_spy },
                agent = { provider_config = { name = "TestProvider" } },
                _handle_connection_error = SessionManager._handle_connection_error,
            } --[[@as agentic.SessionManager]]

            session:_handle_connection_error()

            assert.is_false(session._connection_error)
            assert.equal(callbacks, session._session_ready_callbacks)
            assert.is_true(session.is_generating)
            assert.spy(stop_spy).was.called(0)
            assert.spy(write_spy).was.called(0)
        end)
    end)

    describe("history_to_send consumption", function()
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub

        --- @type fun()[]
        local schedule_queue = {}

        local function flush_schedule()
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end
        end

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_queue = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                }
                fake.agent_info = {}
                function fake:create_session(_h, cb)
                    cb({
                        sessionId = "test-session",
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end
                function fake:cancel_session() end
                function fake:send_prompt() end
                if callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it("prepends history on first submit and clears it", function()
            local session = new_test_manager()
            flush_schedule()
            session.session_id = "test-session" --[[@as string]]

            local SessionRegistry = require("agentic.session_registry")
            -- Registering by hand, so set the key too: invariant is
            -- `sessions[k].session_key == k`, and teardown destroys by key.
            session.session_key = 1
            SessionRegistry.sessions[1] = session

            --- @type agentic.ui.ChatHistory.Message[]
            local history = {
                {
                    type = "user",
                    text = "old msg",
                    timestamp = os.time(),
                    provider_name = "P",
                },
            }
            session.history_to_send = history

            local submitted_prompt = nil
            session.agent.send_prompt = function(_self, _sid, prompt)
                submitted_prompt = prompt
            end

            session:_handle_input_submit("new question")

            assert.is_nil(session.history_to_send)

            -- Restored history plus the new question
            assert.is_not_nil(submitted_prompt)
            assert.truthy(#submitted_prompt >= 2)
        end)
    end)

    describe("_on_session_update: on_session_update hook", function()
        local Config = require("agentic.config")
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            schedule_stub:revert()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_session_update = nil
        end)

        --- @return agentic.SessionManager
        local function make_session()
            return {
                session_id = "session-1",
                session_key = 3,
                widget = {
                    get_visible_tab_id = function()
                        return 42
                    end,
                },
                _is_restoring_session = false,
                todo_list = { render = function() end },
                message_writer = {
                    write_restoring_message = function() end,
                    write_message_chunk = function() end,
                },
                chat_history = {
                    add_message = function() end,
                    append_agent_text = function() end,
                },
                status_animation = { start = function() end },
                agent = { provider_config = { name = "Test" } },
                is_generating = true,
                _on_session_update = SessionManager._on_session_update,
                _start_spinner = SessionManager._start_spinner,
            } --[[@as agentic.SessionManager]]
        end

        it("fires for regular updates", function()
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_session_update = function(data)
                hook_spy(data)
            end

            local session = make_session()
            session:_on_session_update({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "hello" },
            })

            assert.spy(hook_spy).was.called(1)
            local data = hook_spy.calls[1][1]
            assert.equal("session-1", data.session_id)
            assert.equal(42, data.tab_page_id)
            assert.equal("agent_message_chunk", data.update.sessionUpdate)
        end)

        it("does not fire during session restore replay", function()
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_session_update = function(data)
                hook_spy(data)
            end

            local session = make_session()
            session._starter = {
                is_replaying = function()
                    return true
                end,
            }

            session:_on_session_update({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "replayed" },
            })

            assert.spy(hook_spy).was.called(0)
        end)
    end)

    describe("config-change header refresh wiring", function()
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub
        --- @type TestStub
        local config_options_new_stub
        --- @type agentic.acp.AgentConfigOptions.Callbacks
        local captured_callbacks

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function() end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)

            local real_new = AgentConfigOptions.new
            config_options_new_stub = spy.stub(AgentConfigOptions, "new")
            config_options_new_stub:invokes(function(s, buffers, callbacks)
                captured_callbacks = callbacks
                return real_new(s, buffers, callbacks)
            end)

            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                }
                fake.agent_info = {}
                function fake:create_session(_h, cb)
                    cb({
                        sessionId = "test-session",
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end
                function fake:cancel_session() end
                if callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()
            config_options_new_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it("schedules a refresh from on_config_options_applied", function()
            local session = new_test_manager()
            local refresh_spy = spy.new(function() end)
            session.widget.schedule_header_refresh = refresh_spy

            captured_callbacks.on_config_options_applied()

            assert.spy(refresh_spy).was.called(1)
        end)

        it("schedules a refresh from on_set_mode_success", function()
            local session = new_test_manager()
            local refresh_spy = spy.new(function() end)
            session.widget.schedule_header_refresh = refresh_spy

            captured_callbacks.on_set_mode_success("plan")

            assert.spy(refresh_spy).was.called(1)
        end)
    end)

    describe("_on_session_update: usage_update", function()
        local SessionState = require("agentic.acp.session_state")
        --- @type TestSpy
        local refresh_spy
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session

        before_each(function()
            refresh_spy = spy.new(function() end)
            render_header_spy = spy.new(function() end)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            local config_options = {
                legacy_agent_modes = legacy_modes,
                mode = nil,
                set_options = function(self, config_options_update)
                    self.mode = config_options_update[1]
                end,
                get_model_id = function(_self)
                    return nil
                end,
                get_mode_id = function(self)
                    return self.mode and self.mode.currentValue or nil
                end,
                get_mode_name = function(_self, mode_id)
                    local mode = legacy_modes:get_mode(mode_id)
                    return mode and mode.name or mode_id
                end,
            }

            session = {
                session_id = "session-1",
                session_key = 3,
                _is_restoring_session = false,
                config_options = config_options,
                session_state = SessionState:new(config_options, "Test"),
                widget = {
                    schedule_header_refresh = refresh_spy,
                    render_header = render_header_spy,
                    get_visible_tab_id = function()
                        return 7
                    end,
                },
                agent = { provider_config = { name = "Test" } },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        it("feeds used/size into session_state", function()
            session:_on_session_update({
                sessionUpdate = "usage_update",
                used = 1000,
                size = 200000,
            })

            assert.equal(1000, session.session_state:get_context_used_raw())
            assert.equal(200000, session.session_state:get_context_size_raw())
        end)

        it("schedules a header refresh", function()
            session:_on_session_update({
                sessionUpdate = "usage_update",
                used = 10,
                size = 20,
            })

            assert.spy(refresh_spy).was.called(1)
        end)

        it("schedules a header refresh for config_option_update", function()
            session:_on_session_update({
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            })

            assert.spy(refresh_spy).was.called(1)
        end)

        it("schedules a header refresh for current_mode_update", function()
            session:_on_session_update({
                sessionUpdate = "current_mode_update",
                currentModeId = "code",
            })

            assert.spy(refresh_spy).was.called(1)
        end)
    end)

    describe("_on_session_update: user_message_chunk", function()
        --- @type TestSpy
        local write_message_spy

        --- @type TestSpy
        local write_restoring_message_spy

        --- @type agentic.SessionManager
        local session

        before_each(function()
            write_message_spy = spy.new(function() end)
            write_restoring_message_spy = spy.new(function() end)

            session = {
                _is_restoring_session = false,
                message_writer = {
                    write_message = write_message_spy,
                    write_restoring_message = write_restoring_message_spy,
                },
                agent = { provider_config = { name = "test-provider" } },
                chat_history = { add_message = spy.new(function() end) },
                widget = { get_visible_tab_id = function() end },
                _on_session_update = SessionManager._on_session_update,
            } --[[@as agentic.SessionManager]]
        end)

        it("ignores chunk when _is_restoring_session is false", function()
            session:_on_session_update({
                sessionUpdate = "user_message_chunk",
                content = { type = "text", text = "hello" },
            })

            assert.spy(write_message_spy).was.called(0)
            assert.spy(write_restoring_message_spy).was.called(0)
        end)

        it(
            "renders as formatted message when _is_restoring_session is true",
            function()
                session._starter = {
                    is_replaying = function()
                        return true
                    end,
                }

                session:_on_session_update({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "hello" },
                })

                assert.spy(write_restoring_message_spy).was.called(1)
                assert.spy(write_message_spy).was.called(0)
                local message = write_restoring_message_spy.calls[1][2]
                assert.truthy(message.content.text:match("hello"))

                assert.spy(session.chat_history.add_message).was.called(1)
                local added = session.chat_history.add_message.calls[1][2] --- @diagnostic disable-line: undefined-field
                assert.equal("user", added.type)
                assert.equal("hello", added.text)
            end
        )
    end)

    describe("on_tool_call_update: buffer reload", function()
        local Config = require("agentic.config")
        local DiffPreview = require("agentic.ui.diff_preview")
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local cleanup_suggestion_buffer_stub
        --- @type TestStub|nil
        local debug_stub
        --- @type integer[]
        local created_buffers
        --- @type TestSpy|nil
        local restore_keymaps_spy

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                session_id = "session-1",
                session_key = 3,
                widget = {
                    get_visible_tab_id = function()
                        return 42
                    end,
                },
                message_writer = {
                    update_tool_call_block = function() end,
                    tool_call_blocks = tool_call_blocks,
                },
                permission_manager = {
                    pending = {},
                    has_pending = function()
                        return false
                    end,
                    remove_request_by_tool_call_id = function() end,
                },
                status_animation = { start = function() end },
                is_generating = true,
                _start_spinner = SessionManager._start_spinner,
                diff_coordinator = {
                    clear = function() end,
                    diff_state = {},
                },
                _on_tool_call = function() end,
                chat_history = {
                    update_tool_call = function() end,
                    add_message = function() end,
                },
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            debug_stub = nil
            restore_keymaps_spy = nil
            created_buffers = {}
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            cleanup_suggestion_buffer_stub =
                spy.stub(DiffPreview, "cleanup_suggestion_buffer")
        end)

        after_each(function()
            if debug_stub then
                debug_stub:revert()
            end
            if restore_keymaps_spy then
                restore_keymaps_spy:revert()
                restore_keymaps_spy = nil
            end
            checktime_stub:revert()
            schedule_stub:revert()
            cleanup_suggestion_buffer_stub:revert()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_file_edit = nil
            for _, bufnr in ipairs(created_buffers) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end
        end)

        it("calls checktime for each file-mutating kind", function()
            for _, kind in ipairs({
                "edit",
                "create",
                "write",
                "delete",
                "move",
            }) do
                checktime_stub:reset()
                local tc_id = "tc-" .. kind
                local session = make_session({
                    [tc_id] = { kind = kind, status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = tc_id, status = "completed" }
                )

                assert.spy(checktime_stub).was.called(1)
            end
        end)

        it("cleans up only its coordinator-owned suggestion", function()
            local session = make_session({
                ["tc-1"] = {
                    kind = "edit",
                    status = "in_progress",
                    file_path = "/tmp/owned.lua",
                },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert
                .spy(cleanup_suggestion_buffer_stub).was
                .called_with("/tmp/owned.lua", session.diff_coordinator.diff_state)
        end)

        it("keeps the diff preview for in-progress updates", function()
            local clear_spy = spy.new(function() end)
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })
            session.diff_coordinator.clear = clear_spy

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "in_progress" }
            )

            assert.spy(clear_spy).was.called(0)
        end)

        it(
            "clears a refreshed permission-cleared preview before acceptance",
            function()
                cleanup_suggestion_buffer_stub:revert()

                local DiffCoordinator = require("agentic.ui.diff_coordinator")
                local HunkNavigation = require("agentic.ui.hunk_navigation")
                local file_path = "/tmp/agentic-completed-new-file-"
                    .. tostring(vim.uv.hrtime())
                    .. ".lua"
                local tool_call_id = "tc-new-file"
                local tracker = {
                    tool_call_id = tool_call_id,
                    kind = "edit",
                    status = "in_progress",
                    file_path = file_path,
                    diff = { changed_pairs = {} },
                }
                local session = make_session({ [tool_call_id] = tracker })
                local current_winid = vim.api.nvim_get_current_win()
                local original_bufnr = vim.api.nvim_get_current_buf()
                local suggestion_bufnr
                local permission_callback

                session.diff_coordinator = DiffCoordinator:new(
                    { buf_nrs = {} } --[[@as agentic.ui.ChatWidget]],
                    session.message_writer --[[@as agentic.ui.MessageWriter]]
                )
                session.diff_coordinator.show = function() end
                session.permission_manager.add_request = function(
                    _self,
                    _request,
                    callback
                )
                    permission_callback = callback
                end
                session.status_animation.stop = function() end
                local function show_suggestion()
                    DiffPreview._show_new_file_diff({
                        file_path = file_path,
                        diff = { changed_pairs = {} },
                        state = session.diff_coordinator.diff_state,
                        get_winid = function(bufnr)
                            suggestion_bufnr = bufnr
                            vim.api.nvim_win_set_buf(current_winid, bufnr)
                            return current_winid
                        end,
                    }, { "return true" })
                end

                show_suggestion()
                local handlers = SessionManager._build_handlers(session)
                handlers.on_request_permission({
                    toolCall = { toolCallId = tool_call_id },
                    options = {},
                }, function() end)
                assert.is_not_nil(permission_callback)
                permission_callback("allow_once")
                show_suggestion()
                local real_bufnr = vim.fn.bufadd(file_path)
                vim.fn.bufload(real_bufnr)
                restore_keymaps_spy = spy.on(HunkNavigation, "restore_keymaps")

                SessionManager._on_tool_call_update(session, {
                    tool_call_id = tool_call_id,
                    status = "completed",
                })

                local suggestion_is_valid = suggestion_bufnr ~= nil
                    and vim.api.nvim_buf_is_valid(suggestion_bufnr)
                local displayed_bufnr = vim.api.nvim_win_get_buf(current_winid)
                local displayed_name =
                    vim.api.nvim_buf_get_name(displayed_bufnr)
                local restored_owner = restore_keymaps_spy:called_with(
                    suggestion_bufnr,
                    session.diff_coordinator.diff_state
                )

                pcall(vim.api.nvim_win_set_buf, current_winid, original_bufnr)
                if suggestion_bufnr then
                    pcall(
                        vim.api.nvim_buf_delete,
                        suggestion_bufnr,
                        { force = true }
                    )
                end
                if displayed_bufnr ~= original_bufnr then
                    pcall(
                        vim.api.nvim_buf_delete,
                        displayed_bufnr,
                        { force = true }
                    )
                end

                assert.is_false(suggestion_is_valid)
                assert.is_true(restored_owner)
                assert.is_nil(session.diff_coordinator.diff_state.preview_bufnr)
                assert.is_nil(session.diff_coordinator.diff_state.preview_winid)
                assert.equal(real_bufnr, displayed_bufnr)
                assert.equal(
                    vim.fn.fnamemodify(file_path, ":t"),
                    vim.fn.fnamemodify(displayed_name, ":t")
                )
            end
        )
        it(
            "removes pending permission on failed and completed tool-call updates",
            function()
                for _, status in ipairs({ "failed", "completed" }) do
                    local remove_calls = {}
                    local session = make_session({
                        ["tc-" .. status] = {
                            kind = "edit",
                            status = "in_progress",
                        },
                    })
                    session.permission_manager.remove_request_by_tool_call_id = function(
                        _self,
                        id
                    )
                        table.insert(remove_calls, id)
                    end

                    SessionManager._on_tool_call_update(session, {
                        tool_call_id = "tc-" .. status,
                        status = status,
                    })

                    assert.equal(1, #remove_calls)
                    assert.equal("tc-" .. status, remove_calls[1])
                end
            end
        )

        it(
            "does not remove pending permission on non-terminal updates",
            function()
                local remove_calls = {}
                local session = make_session({
                    ["tc-prog"] = { kind = "edit", status = "pending" },
                })
                session.permission_manager.remove_request_by_tool_call_id = function(
                    _self,
                    id
                )
                    table.insert(remove_calls, id)
                end

                SessionManager._on_tool_call_update(session, {
                    tool_call_id = "tc-prog",
                    status = "in_progress",
                })

                assert.equal(0, #remove_calls)
            end
        )

        it("does not call checktime for failed tool calls", function()
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "failed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime for non-mutating kinds", function()
            local session = make_session({
                ["tc-1"] = { kind = "read", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime when tracker is missing", function()
            debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it(
            "invokes on_file_edit hook for file-mutating tool calls with absolute path and bufnr",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local test_bufnr = vim.api.nvim_create_buf(false, true)
                created_buffers[#created_buffers + 1] = test_bufnr
                local abs_path =
                    vim.fn.fnamemodify("./tests/fixtures/edit_hook.lua", ":p")
                vim.api.nvim_buf_set_name(test_bufnr, abs_path)

                local session = make_session({
                    ["tc-1"] = {
                        kind = "edit",
                        status = "in_progress",
                        file_path = abs_path,
                    },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(1)
                local data = hook_spy.calls[1][1]
                assert.equal(abs_path, data.filepath)
                assert.equal("session-1", data.session_id)
                assert.equal(3, data.session_key)
                assert.equal(42, data.tab_page_id)
                assert.equal(test_bufnr, data.bufnr)
            end
        )

        it(
            "invokes on_file_edit with nil bufnr when file is not loaded",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local unloaded_path = "/tmp/agentic-unloaded-"
                    .. tostring(vim.loop.hrtime())

                local session = make_session({
                    ["tc-1"] = {
                        kind = "edit",
                        status = "in_progress",
                        file_path = unloaded_path,
                    },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(1)
                local data = hook_spy.calls[1][1]
                assert.equal(unloaded_path, data.filepath)
                assert.is_nil(data.bufnr)
            end
        )

        it(
            "does not invoke on_file_edit when tracker has no file_path",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local session = make_session({
                    ["tc-1"] = { kind = "edit", status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(0)
            end
        )

        it(
            "does not invoke on_file_edit during session restore replay",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local session = make_session({
                    ["tc-1"] = {
                        kind = "edit",
                        status = "in_progress",
                        file_path = "/tmp/restore-replay.lua",
                    },
                })
                session._starter = {
                    is_replaying = function()
                        return true
                    end,
                }

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(0)
            end
        )

        it(
            "invokes on_file_edit with nil bufnr when buffer exists but is not loaded",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local abs_path = vim.fn.fnamemodify(
                    "./tests/fixtures/unloaded_hook.lua",
                    ":p"
                )
                local test_bufnr = vim.fn.bufadd(abs_path)
                created_buffers[#created_buffers + 1] = test_bufnr
                assert.is_false(vim.api.nvim_buf_is_loaded(test_bufnr))

                local session = make_session({
                    ["tc-1"] = {
                        kind = "edit",
                        status = "in_progress",
                        file_path = abs_path,
                    },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(1)
                local data = hook_spy.calls[1][1]
                assert.equal(abs_path, data.filepath)
                assert.is_nil(data.bufnr)
            end
        )

        it(
            "does not invoke on_file_edit for non-file-mutating tool calls",
            function()
                local hook_spy = spy.new(function() end)
                Config.hooks = Config.hooks or {}
                Config.hooks.on_file_edit = function(data)
                    hook_spy(data)
                end

                local session = make_session({
                    ["tc-1"] = {
                        kind = "read",
                        status = "in_progress",
                        file_path = "/tmp/foo.lua",
                    },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.spy(hook_spy).was.called(0)
            end
        )
    end)

    describe("_handle_input_submit /new while generating", function()
        it("allows /new even when is_generating is true", function()
            local SessionRegistry = require("agentic.session_registry")
            local replace_stub = spy.stub(SessionRegistry, "replace")
            local close_todos_spy = spy.new(function() end)

            --- @type agentic.SessionManager
            local session = {
                is_generating = true,
                todo_list = { close_if_all_completed = close_todos_spy },
                provider_name = "claude-acp",
                agent = {},
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            local result = session:_handle_input_submit("/new")

            assert.is_true(result)
            assert.spy(replace_stub).was.called(1)
            assert.spy(close_todos_spy).was.called(0)
            replace_stub:revert()
        end)
    end)

    describe("send_prompt callback ignores stale session", function()
        --- @type TestStub
        local schedule_stub
        --- @type fun()[]
        local schedule_queue

        before_each(function()
            schedule_queue = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("does not write finish message if session_id changed", function()
            local write_message_spy = spy.new(function() end)

            --- @type fun(response: table|nil, err: table|nil)|nil
            local captured_callback = nil

            --- @type agentic.SessionManager
            local session = {
                session_id = "original-session",
                session_key = 3,
                widget = {
                    get_visible_tab_id = function()
                        return 1
                    end,
                },
                is_generating = false,
                _connection_error = false,
                _is_restoring_session = false,
                _is_first_message = false,
                history_to_send = nil,
                chat_history = {
                    title = "",
                    add_message = function() end,
                },
                todo_list = { close_if_all_completed = function() end },
                code_selection = {
                    is_empty = function()
                        return true
                    end,
                },
                file_list = {
                    is_empty = function()
                        return true
                    end,
                },
                diagnostics_list = {
                    is_empty = function()
                        return true
                    end,
                },
                message_writer = { write_message = write_message_spy },
                status_animation = {
                    start = function() end,
                    stop = function() end,
                },
                agent = {
                    provider_config = { name = "TestProvider" },
                    send_prompt = function(_self, _sid, _prompt, callback)
                        captured_callback = callback
                    end,
                },
                can_submit_prompt = function()
                    return true
                end,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            session:_handle_input_submit("hello")

            assert.is_not_nil(captured_callback)

            -- Drop the user-message write, so only finish writes are counted
            write_message_spy:reset()

            -- Cancel/restore/new session lands while the prompt is in flight
            session.session_id = "new-session"

            if captured_callback then
                captured_callback(nil, nil)
            end

            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end

            assert.spy(write_message_spy).was.called(0)
        end)
    end)

    describe("initial thought_level wiring", function()
        local AgentConfigOptions = require("agentic.acp.agent_config_options")

        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local health_check_stub
        --- @type TestStub
        local set_initial_thought_level_stub

        --- @type fun()[]
        local schedule_queue = {}

        local function flush_schedule()
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end
        end

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")
            local Config = require("agentic.config")

            notify_stub = spy.stub(Logger, "notify")
            schedule_queue = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)
            set_initial_thought_level_stub =
                spy.stub(AgentConfigOptions, "set_initial_thought_level")
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name, callback)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = {
                    name = provider_name or "Test",
                    initial_model = nil,
                    default_mode = nil,
                    default_thought_level = "max",
                }
                fake.agent_info = {}
                function fake:when_ready(on_ready, _on_failure)
                    vim.schedule(function()
                        on_ready(fake)
                    end)
                end
                function fake:create_session(_h, cb)
                    cb({
                        sessionId = "test-session",
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end
                function fake:cancel_session() end
                if callback then
                    callback(fake)
                end
                return fake
            end)
            Config.provider = "TestProvider"
        end)

        after_each(function()
            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()
            set_initial_thought_level_stub:revert()

            local SessionRegistry = require("agentic.session_registry")
            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end
        end)

        it(
            "applies default_thought_level when no model change is triggered",
            function()
                local session = new_test_manager()
                session:start({ kind = "new" })
                flush_schedule()

                assert.equal(1, set_initial_thought_level_stub.call_count)
                local call = set_initial_thought_level_stub.calls[1]
                -- call[1] self, call[2] target_value; no handler arg
                assert.equal("max", call[2])
                assert.equal(2, call.n)
            end
        )
    end)

    describe("_build_handlers: on_request_permission", function()
        local Config = require("agentic.config")
        --- @type TestStub
        local schedule_stub
        --- @type TestSpy
        local hook_spy
        --- @type agentic.SessionManager
        local session

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_request_permission = nil

            session = {
                session_id = "test-session-123",
                session_key = 3,
                widget = {
                    get_visible_tab_id = function()
                        return 1
                    end,
                },
                message_writer = {
                    write_message = function() end,
                },
                status_animation = {
                    stop = function() end,
                    start = function() end,
                },
                permission_manager = {
                    has_pending = function()
                        return false
                    end,
                    add_request = function() end,
                },
                diff_coordinator = {
                    show = function() end,
                    clear = function() end,
                },
                _on_session_update = function() end,
                _on_tool_call = function() end,
                _on_tool_call_update = function() end,
                _build_handlers = SessionManager._build_handlers,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            schedule_stub:revert()
            Config.hooks.on_request_permission = nil
        end)

        it("invokes on_request_permission hook with correct payload", function()
            Config.hooks.on_request_permission = function(data)
                hook_spy(data)
            end

            local handlers = session:_build_handlers()
            local mock_request = {
                sessionId = "test-session-123",
                toolCall = {
                    toolCallId = "tool-1",
                    kind = "edit",
                    title = "Edit file",
                },
                options = {
                    {
                        optionId = "allow_once",
                        name = "Allow Once",
                        kind = "allow_once",
                    },
                },
            }
            local mock_callback = function() end

            handlers.on_request_permission(mock_request, mock_callback)

            assert.spy(hook_spy).was.called(1)
            local data = hook_spy.calls[1][1]
            assert.equal("test-session-123", data.session_id)
            assert.equal(3, data.session_key)
            assert.equal(1, data.tab_page_id)
            assert.equal(mock_request, data.request)
        end)

        it("answers a request that lands after destroy", function()
            -- The only handler where "return early" is not a no-op: it owes a
            -- JSON-RPC response, and the provider subprocess is shared across every
            -- session (ADR 0004), so an unanswered request outlives its session.
            ---@diagnostic disable-next-line: invisible
            session._destroyed = true

            local handlers = session:_build_handlers()
            local callback_spy = spy.new(function() end)

            handlers.on_request_permission({
                sessionId = "test-session-123",
                toolCall = { toolCallId = "tool-1", kind = "edit" },
                options = {},
            }, callback_spy --[[@as function]])

            assert.spy(callback_spy).was.called(1)
            assert.is_nil(callback_spy.calls[1][1])
        end)

        it("does not fail when hook is not configured", function()
            Config.hooks.on_request_permission = nil

            local handlers = session:_build_handlers()
            local mock_request = {
                sessionId = "test-session-123",
                toolCall = { toolCallId = "tool-1", kind = "edit" },
                options = {},
            }
            local mock_callback = function() end

            -- No assertion: a raise here fails the case
            handlers.on_request_permission(mock_request, mock_callback)
        end)

        it(
            "drops every handler after destroy and answers permission",
            function()
                local write_spy = spy.new(function() end)
                local update_spy = spy.new(function() end)
                local tool_spy = spy.new(function() end)
                local tool_update_spy = spy.new(function() end)
                local permission_spy = spy.new(function() end)
                session._destroyed = true
                session.message_writer.write_message = write_spy
                session._on_session_update = update_spy
                session._on_tool_call = tool_spy
                session._on_tool_call_update = tool_update_spy

                local handlers = session:_build_handlers()
                handlers.on_error({ message = "late" })
                handlers.on_session_update({ sessionUpdate = "late" })
                handlers.on_tool_call({})
                handlers.on_tool_call_update({})
                handlers.on_request_permission({
                    sessionId = "test-session-123",
                    toolCall = { toolCallId = "tool-1", kind = "edit" },
                    options = {},
                }, permission_spy --[[@as function]])

                assert.spy(write_spy).was.called(0)
                assert.spy(update_spy).was.called(0)
                assert.spy(tool_spy).was.called(0)
                assert.spy(tool_update_spy).was.called(0)
                assert.spy(permission_spy).was.called(1)
                assert.is_nil(permission_spy.calls[1][1])
            end
        )
    end)

    describe("destroy", function()
        it("is idempotent and marks destroyed before cancellation", function()
            local session
            local cancel_spy = spy.new(function()
                assert.is_true(session._destroyed)
            end)
            local widget_destroy_spy = spy.new(function() end)
            local writer_destroy_spy = spy.new(function() end)
            session = {
                _destroyed = false,
                _starter = { cancel = cancel_spy },
                is_generating = false,
                widget = { destroy = widget_destroy_spy },
                message_writer = { destroy = writer_destroy_spy },
                destroy = SessionManager.destroy,
            } --[[@as agentic.SessionManager]]

            session:destroy()
            session:destroy()

            assert.spy(cancel_spy).was.called(1)
            assert.spy(widget_destroy_spy).was.called(1)
            assert.spy(writer_destroy_spy).was.called(1)
        end)
    end)

    describe("hook payloads: session identity", function()
        local Config = require("agentic.config")
        local SessionRegistry = require("agentic.session_registry")
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local health_check_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestSpy
        local hook_spy
        --- @type table<integer, boolean>
        local baseline_tabs

        before_each(function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local ACPHealth = require("agentic.acp.acp_health")

            baseline_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                baseline_tabs[tabpage] = true
            end

            notify_stub = spy.stub(Logger, "notify")
            -- Inline, not queued: `Hooks.invoke` defers every payload through
            -- `vim.schedule`. Animation frames use `vim.defer_fn`, so nothing
            -- here re-enters.
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
            health_check_stub:returns(true)

            -- No ready callback: `SessionManager:new` would otherwise drive a real
            -- `session/new`, and this block only needs the widget.
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(provider_name)
                --- @type agentic.acp.ACPClient
                local fake = {}
                fake.state = "ready"
                fake.provider_config = { name = provider_name or "Test" }
                fake.agent_info = {}
                function fake:when_ready(_on_ready, _on_failure) end
                function fake:cancel_session() end
                return fake
            end)

            hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_session_update = function(data)
                hook_spy(data)
            end
        end)

        after_each(function()
            Config.hooks.on_session_update = nil

            for _, session in ipairs(SessionRegistry.list()) do
                SessionRegistry.destroy(session.session_key)
            end

            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                if
                    not baseline_tabs[tabpage]
                    and vim.api.nvim_tabpage_is_valid(tabpage)
                then
                    vim.cmd(
                        "tabclose " .. vim.api.nvim_tabpage_get_number(tabpage)
                    )
                end
            end

            notify_stub:revert()
            schedule_stub:revert()
            health_check_stub:revert()
            get_instance_stub:revert()
        end)

        --- @return agentic.SessionManager
        local function create_session()
            local session = SessionRegistry.create()
            assert.is_not_nil(session)
            return session --[[@as agentic.SessionManager]]
        end

        --- @param session agentic.SessionManager
        --- @return agentic.UserConfig.SessionUpdateData
        local function fire_update(session)
            session:_on_session_update({
                sessionUpdate = "session_info_update",
            })
            return hook_spy.calls[#hook_spy.calls][1]
        end

        it("reports the registry key and the visible tabpage", function()
            local session = create_session()
            SessionRegistry.show_session(session.session_key)

            local data = fire_update(session)

            assert.equal(session.session_key, data.session_key)
            assert.equal(vim.api.nvim_get_current_tabpage(), data.tab_page_id)
        end)

        it(
            "keeps session_key stable across hide, show and tab switches",
            function()
                local session = create_session()
                local key = session.session_key

                local hidden = fire_update(session)
                assert.equal(key, hidden.session_key)
                assert.is_nil(hidden.tab_page_id)

                SessionRegistry.show_session(key)
                local shown = fire_update(session)
                assert.equal(key, shown.session_key)
                assert.equal(
                    vim.api.nvim_get_current_tabpage(),
                    shown.tab_page_id
                )

                -- Direct widget call: `SessionRegistry` exposes only
                -- `show_session`, no hide entry point.
                session.widget:hide()
                local rehidden = fire_update(session)
                assert.equal(key, rehidden.session_key)
                assert.is_nil(rehidden.tab_page_id)

                SessionRegistry.show_session(key)
                local reshown = fire_update(session)
                assert.equal(key, reshown.session_key)
                assert.equal(
                    vim.api.nvim_get_current_tabpage(),
                    reshown.tab_page_id
                )

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()
                SessionRegistry.show_session(key)

                local moved = fire_update(session)
                assert.equal(key, moved.session_key)
                assert.equal(tab2, moved.tab_page_id)
            end
        )

        it("distinguishes two background sessions by key", function()
            local first = create_session()
            local second = create_session()

            local first_data = fire_update(first)
            local second_data = fire_update(second)

            assert.is_not.equal(first_data.session_key, second_data.session_key)
            assert.equal(first.session_key, first_data.session_key)
            assert.equal(second.session_key, second_data.session_key)
            assert.is_nil(first_data.tab_page_id)
            assert.is_nil(second_data.tab_page_id)
        end)
    end)

    describe("_handle_input_submit: placement and title", function()
        local Config = require("agentic.config")
        --- @type TestStub
        local schedule_stub
        --- @type fun()[]
        local schedule_queue
        --- @type fun(response: table|nil, err: table|nil)|nil
        local send_prompt_callback
        --- @type integer|nil
        local widget_tab

        before_each(function()
            schedule_queue = {}
            send_prompt_callback = nil
            widget_tab = 11
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(schedule_queue, fn)
            end)
        end)

        after_each(function()
            schedule_stub:revert()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_prompt_submit = nil
            Config.hooks.on_response_complete = nil
        end)

        local function flush_schedule()
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end
        end

        --- @return agentic.SessionManager
        local function make_session()
            return {
                session_id = "session-1",
                session_key = 7,
                is_generating = false,
                _connection_error = false,
                _is_restoring_session = false,
                _is_first_message = false,
                history_to_send = nil,
                chat_history = {
                    title = "",
                    add_message = function() end,
                },
                todo_list = {
                    close_if_all_completed = function() end,
                    clear = function() end,
                },
                code_selection = {
                    is_empty = function()
                        return true
                    end,
                    clear = function() end,
                },
                file_list = {
                    is_empty = function()
                        return true
                    end,
                    clear = function() end,
                },
                diagnostics_list = {
                    is_empty = function()
                        return true
                    end,
                    clear = function() end,
                },
                message_writer = {
                    write_message = function() end,
                    write_finish_message = function() end,
                    destroy = function() end,
                },
                status_animation = {
                    start = function() end,
                    stop = function() end,
                },
                widget = {
                    get_visible_tab_id = function()
                        return widget_tab
                    end,
                    destroy = function() end,
                },
                agent = {
                    provider_config = { name = "TestProvider" },
                    send_prompt = function(_self, _sid, _prompt, callback)
                        send_prompt_callback = callback
                    end,
                },
                can_submit_prompt = function()
                    return true
                end,
                destroy = SessionManager.destroy,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]
        end

        --- @return agentic.UserConfig.ResponseCompleteData
        local function complete_response()
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_response_complete = function(data)
                hook_spy(data)
            end

            assert.is_not_nil(send_prompt_callback)
            --- @diagnostic disable-next-line: need-check-nil
            send_prompt_callback(nil, nil)
            flush_schedule()

            assert.spy(hook_spy).was.called(1)
            return hook_spy.calls[1][1]
        end

        it("reports where the widget is at submit time", function()
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_prompt_submit = function(data)
                hook_spy(data)
            end

            local session = make_session()
            session:_handle_input_submit("hello")
            flush_schedule()

            assert.spy(hook_spy).was.called(1)
            assert.equal(7, hook_spy.calls[1][1].session_key)
            assert.equal(11, hook_spy.calls[1][1].tab_page_id)
        end)

        -- The completion payload is built inside a `vim.schedule`, so a tabpage
        -- captured at submit time reports a window the user may have hidden
        -- minutes ago.
        it("reports a nil tab when the widget was hidden meanwhile", function()
            local session = make_session()
            session:_handle_input_submit("hello")

            widget_tab = nil

            assert.is_nil(complete_response().tab_page_id)
        end)

        it("reports the tab the widget moved to before completing", function()
            local session = make_session()
            session:_handle_input_submit("hello")

            widget_tab = 22

            local data = complete_response()
            assert.equal(22, data.tab_page_id)
            assert.equal(7, data.session_key)
        end)

        it("drops queued response completion after destroy", function()
            local finish_spy = spy.new(function() end)
            local stop_spy = spy.new(function() end)
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_response_complete = function(data)
                hook_spy(data)
            end

            local session = make_session()
            session.message_writer.write_finish_message = finish_spy
            session.status_animation.stop = stop_spy
            session:_handle_input_submit("hello")

            assert.is_not_nil(send_prompt_callback)
            --- @diagnostic disable-next-line: need-check-nil
            send_prompt_callback(nil, nil)
            session:destroy()
            flush_schedule()

            assert.spy(finish_spy).was.called(0)
            assert.spy(stop_spy).was.called(1)
            assert.spy(hook_spy).was.called(0)
            assert.is_false(session.is_generating)
        end)

        it("titles the session from the first prompt only", function()
            local session = make_session()

            session:_handle_input_submit("add a retry to the http client")
            session:_handle_input_submit("now write the tests")

            assert.equal(
                "add a retry to the http client",
                session.chat_history.title
            )
        end)

        it("truncates a long first prompt to 60 characters", function()
            local session = make_session()

            session:_handle_input_submit(("x"):rep(120))

            local title = session.chat_history.title
            assert.equal(60, vim.fn.strchars(title))
            assert.equal(("x"):rep(59) .. "…", title)
        end)

        -- ASCII alone cannot tell `strcharpart` from `sub`: only multi-byte makes
        -- a byte cut land mid-sequence and produce a broken title.
        it("truncates a multi-byte prompt on a character boundary", function()
            local session = make_session()

            session:_handle_input_submit(("日"):rep(120))

            local title = session.chat_history.title
            assert.equal(60, vim.fn.strchars(title))
            assert.equal(("日"):rep(59) .. "…", title)
        end)

        -- A restored session carries the provider's own title; deriving one from
        -- the first prompt would relabel it in the picker on resume.
        it("keeps a restored title on the first submit", function()
            local session = make_session()
            session.chat_history.title = "Provider side title"
            session.history_to_send = {}

            session:_handle_input_submit("now write the tests")

            assert.equal("Provider side title", session.chat_history.title)
        end)

        it("collapses whitespace in the derived title", function()
            local session = make_session()

            session:_handle_input_submit("  fix  the\n  parser  ")

            assert.equal("fix the parser", session.chat_history.title)
        end)

        it("keeps a title at exactly 60 codepoints", function()
            local session = make_session()
            local prompt = ("x"):rep(60)

            session:_handle_input_submit(prompt)

            assert.equal(prompt, session.chat_history.title)
        end)

        it("keeps a restored title while consuming history", function()
            local session = make_session()
            --- @type agentic.acp.Content[]|nil
            local submitted_prompt
            session.chat_history.title = "restored title"
            session.history_to_send = {
                {
                    type = "user",
                    text = "old msg",
                    timestamp = os.time(),
                    provider_name = "P",
                },
            }
            session.agent.send_prompt = function(
                _self,
                _session_id,
                prompt,
                callback
            )
                submitted_prompt = prompt
                callback(nil, nil)
            end

            session:_handle_input_submit("new question")

            assert.equal("restored title", session.chat_history.title)
            assert.is_nil(session.history_to_send)
            assert.is_not_nil(submitted_prompt)
            --- @type agentic.acp.Content[]
            local prompt = submitted_prompt or {}
            assert.equal("User: old msg", prompt[1].text)
            assert.equal("new question", prompt[2].text)
        end)

        it(
            "derives a normalized title for restored history without one",
            function()
                local session = make_session()
                --- @type agentic.acp.Content[]|nil
                local submitted_prompt
                session.history_to_send = {
                    {
                        type = "user",
                        text = "old msg",
                        timestamp = os.time(),
                        provider_name = "P",
                    },
                }
                session.agent.send_prompt = function(
                    _self,
                    _session_id,
                    prompt,
                    callback
                )
                    submitted_prompt = prompt
                    callback(nil, nil)
                end

                session:_handle_input_submit("  new   question  ")

                assert.equal("new question", session.chat_history.title)
                assert.is_nil(session.history_to_send)
                assert.is_not_nil(submitted_prompt)
                --- @type agentic.acp.Content[]
                local prompt = submitted_prompt or {}
                assert.equal("User: old msg", prompt[1].text)
                assert.equal("  new   question  ", prompt[2].text)
            end
        )
    end)
end)

describe("agentic.SessionManager one-shot lifecycle", function()
    local Config = require("agentic.config")
    local AgentInstance = require("agentic.acp.agent_instance")
    local SessionRegistry = require("agentic.session_registry")
    local get_instance_stub
    local notify_stub
    local managers

    local function new_agent()
        local agent = {
            state = "ready",
            provider_config = { name = "Test Provider" },
            agent_info = { version = "1" },
            create_calls = 0,
            load_calls = 0,
            cancelled = {},
            create_error = nil,
            load_error = nil,
        }

        function agent:when_ready(on_ready, on_failure)
            self.ready_callback = on_ready
            self.failure_callback = on_failure
        end

        function agent:create_session(_handlers, callback)
            self.create_calls = self.create_calls + 1
            if self.create_error then
                callback(nil, self.create_error)
            else
                callback(self.new_response or { sessionId = "new-id" }, nil)
            end
        end

        function agent:load_session(_id, _cwd, _servers, _handlers, callback)
            self.load_calls = self.load_calls + 1
            callback(
                self.load_error and nil or self.load_response or {},
                self.load_error
            )
        end

        function agent:cancel_session(session_id)
            self.cancelled[#self.cancelled + 1] = session_id
        end

        return agent
    end

    local function make_manager(agent)
        get_instance_stub:returns(agent)
        local manager = SessionManager:new(agent, "claude-acp")
        managers[#managers + 1] = manager
        return manager
    end

    local function flush_until(predicate)
        vim.wait(100, predicate, 1)
    end

    before_each(function()
        managers = {}
        get_instance_stub = spy.stub(AgentInstance, "get_instance")
        notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        for _, manager in ipairs(managers) do
            manager:destroy()
        end
        Config.hooks.on_create_session_response = nil
        notify_stub:revert()
        get_instance_stub:revert()
    end)

    it("constructs inertly from the injected client", function()
        local agent = new_agent()
        local manager = make_manager(agent)

        assert.equal(agent, manager.agent)
        assert.spy(get_instance_stub).was.called(0)
        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
        assert.is_nil(manager.session_id)
    end)

    for _, case in ipairs({
        { kind = "new", session_id = "new-id" },
        { kind = "load", session_id = "load-id" },
    }) do
        it("starts one " .. case.kind .. " conversation", function()
            local agent = new_agent()
            local manager = make_manager(agent)
            local callback_manager
            local callback_err

            manager:start({
                kind = case.kind,
                session_id = case.kind == "load" and case.session_id or nil,
            }, function(value, err)
                callback_manager = value
                callback_err = err
            end)

            assert.equal(0, agent.create_calls)
            assert.equal(0, agent.load_calls)
            assert.is_not_nil(agent.ready_callback)
            agent.ready_callback(agent)
            flush_until(function()
                return callback_manager ~= nil or callback_err ~= nil
            end)

            assert.equal(manager, callback_manager)
            assert.is_nil(callback_err)
            assert.equal(case.session_id, manager.session_id)
            assert.equal(case.kind == "new" and 1 or 0, agent.create_calls)
            assert.equal(case.kind == "load" and 1 or 0, agent.load_calls)
        end)
    end

    it("prefers config options over legacy load metadata", function()
        local agent = new_agent()
        agent.load_response = {
            configOptions = {},
            modes = { currentModeId = "legacy-mode", availableModes = {} },
            models = {
                currentModelId = "legacy-model",
                availableModels = {},
            },
        }
        local manager = make_manager(agent)
        local options_stub = spy.stub(manager.config_options, "set_options")
        local modes_stub = spy.stub(manager.config_options, "set_legacy_modes")
        local models_stub =
            spy.stub(manager.config_options, "set_legacy_models")

        manager:start({ kind = "load", session_id = "load-id" })
        assert.is_not_nil(agent.ready_callback)
        agent.ready_callback(agent)
        flush_until(function()
            return manager.session_id ~= nil
        end)

        assert.spy(options_stub).was.called(1)
        assert.spy(modes_stub).was.called(0)
        assert.spy(models_stub).was.called(0)
        options_stub:revert()
        modes_stub:revert()
        models_stub:revert()
    end)

    it("uses independent legacy mode and model load metadata", function()
        local agent = new_agent()
        agent.load_response = {
            modes = { currentModeId = "legacy-mode", availableModes = {} },
            models = {
                currentModelId = "legacy-model",
                availableModels = {},
            },
        }
        local manager = make_manager(agent)
        local modes_stub = spy.stub(manager.config_options, "set_legacy_modes")
        local models_stub =
            spy.stub(manager.config_options, "set_legacy_models")

        manager:start({ kind = "load", session_id = "load-id" })
        assert.is_not_nil(agent.ready_callback)
        agent.ready_callback(agent)
        flush_until(function()
            return manager.session_id ~= nil
        end)

        assert.spy(modes_stub).was.called(1)
        assert.spy(models_stub).was.called(1)
        modes_stub:revert()
        models_stub:revert()
    end)

    it(
        "keeps empty load metadata empty and skips new-session defaults",
        function()
            local agent = new_agent()
            agent.load_response = {}
            local manager = make_manager(agent)
            local options_stub = spy.stub(manager.config_options, "set_options")
            local modes_stub =
                spy.stub(manager.config_options, "set_legacy_modes")
            local models_stub =
                spy.stub(manager.config_options, "set_legacy_models")
            local model_default_stub =
                spy.stub(manager.config_options, "set_initial_model")
            local mode_default_stub =
                spy.stub(manager.config_options, "set_initial_mode")
            local thought_default_stub =
                spy.stub(manager.config_options, "set_initial_thought_level")

            manager:start({ kind = "load", session_id = "load-id" })
            agent.ready_callback(agent)
            flush_until(function()
                return manager.session_id ~= nil
            end)

            assert.spy(options_stub).was.called(0)
            assert.spy(modes_stub).was.called(0)
            assert.spy(models_stub).was.called(0)
            assert.spy(model_default_stub).was.called(0)
            assert.spy(mode_default_stub).was.called(0)
            assert.spy(thought_default_stub).was.called(0)
            options_stub:revert()
            modes_stub:revert()
            models_stub:revert()
            model_default_stub:revert()
            mode_default_stub:revert()
            thought_default_stub:revert()
        end
    )

    it("reports a load request failure before rollback", function()
        local agent = new_agent()
        agent.load_error = { code = -32000, message = "load failed" }
        local manager = make_manager(agent)

        manager:start({ kind = "load", session_id = "load-id" })
        agent.ready_callback(agent)
        flush_until(function()
            return notify_stub.call_count > 0
        end)

        assert.spy(notify_stub).was.called(1)
        assert.equal(
            "Failed to load session: load failed",
            notify_stub.calls[1][1]
        )
    end)

    it("rejects a second start without dropping the adopted session", function()
        local agent = new_agent()
        local manager = make_manager(agent)
        local second_err

        manager:start({ kind = "new" })
        agent.ready_callback(agent)
        flush_until(function()
            return manager.session_id ~= nil
        end)
        manager:start({ kind = "new" }, function(_, err)
            second_err = err
        end)
        flush_until(function()
            return second_err ~= nil
        end)

        assert.equal("new-id", manager.session_id)
        assert.equal(1, agent.create_calls)
        assert.is_not_nil(second_err)
    end)

    it("fires the create response hook when a new session fails", function()
        local agent = new_agent()
        agent.create_error = { code = -32000, message = "create failed" }
        local manager = make_manager(agent)
        local hook_spy = spy.new(function() end)
        Config.hooks.on_create_session_response = function(data)
            hook_spy(data)
        end

        manager:start({ kind = "new" })
        agent.ready_callback(agent)
        flush_until(function()
            return hook_spy.call_count > 0
        end)

        assert.spy(hook_spy).was.called(1)
        local data = hook_spy.calls[1][1]
        assert.is_nil(data.response)
        assert.equal("create failed", data.err.message)
    end)

    it("builds the create hook payload outside a fast event", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()
        child.setup()

        child.lua([[
            local Config = require("agentic.config")
            local SessionManager = require("agentic.session_manager")
            local SessionStarter = require("agentic.session_starter")
            _G.t = {}

            local agent = {
                provider_config = { name = "Test" },
            }
            function agent:when_ready(on_ready)
                on_ready(self)
            end
            function agent:create_session(_handlers, callback)
                local timer = vim.uv.new_timer()
                timer:start(0, 0, function()
                    timer:close()
                    _G.t.dispatch_fast = vim.in_fast_event()
                    _G.t.ok, _G.t.err = pcall(callback, nil, {
                        code = -32000,
                        message = "boom",
                    })
                end)
            end
            function agent:cancel_session() end

            local session = {
                _destroyed = false,
                _start_called = false,
                _session_creation_failed = false,
                _session_ready_callbacks = {},
                session_key = 3,
                session_id = nil,
                agent = agent,
                status_animation = {
                    start = function() end,
                    stop = function()
                        _G.t.stop_fast = vim.in_fast_event()
                    end,
                },
                widget = {
                    get_visible_tab_id = function()
                        _G.t.widget_fast = vim.in_fast_event()
                        vim.api.nvim_win_is_valid(1000)
                    end,
                },
                _build_handlers = function()
                    return {}
                end,
                start = SessionManager.start,
            }
            session._starter = SessionStarter:new(agent)
            Config.hooks.on_create_session_response = function(data)
                _G.t.hook_data = data
            end

            session:start({ kind = "new" })
            vim.wait(2000, function()
                return _G.t.widget_fast ~= nil
            end)
        ]])

        local dispatch_fast = child.lua_get("_G.t.dispatch_fast")
        local callback_ok = child.lua_get("_G.t.ok")
        local stop_fast = child.lua_get("_G.t.stop_fast")
        local widget_fast = child.lua_get("_G.t.widget_fast")
        child.stop()

        assert.is_true(dispatch_fast)
        assert.is_true(callback_ok)
        assert.is_false(stop_fast)
        assert.is_false(widget_fast)
    end)

    it("delegates slash-new to registry replacement", function()
        local agent = new_agent()
        local manager = make_manager(agent)
        local replace_stub = spy.stub(SessionRegistry, "replace")

        assert.is_true(manager:_handle_input_submit("/new"))

        assert
            .spy(replace_stub).was
            .called_with(manager, "claude-acp", { kind = "new" }, { agent = agent })
        replace_stub:revert()
    end)

    it("reports an in-flight load claim", function()
        local agent = new_agent()
        local manager = make_manager(agent)

        manager:start({ kind = "load", session_id = "load-id" })

        assert.is_true(manager:has_acp_session_id("load-id"))
    end)

    it("cancels adopted ownership once before destroying UI", function()
        local agent = new_agent()
        local manager = make_manager(agent)
        manager.session_id = "owned-id"
        assert.is_not_nil(manager._starter)
        local starter_cancel_stub = spy.stub(manager._starter, "cancel")
        local widget_destroy_stub = spy.stub(manager.widget, "destroy")

        manager:destroy()
        manager:destroy()

        assert.spy(starter_cancel_stub).was.called(1)
        assert.same({ "owned-id" }, agent.cancelled)
        assert.spy(widget_destroy_stub).was.called(1)
        starter_cancel_stub:revert()
        widget_destroy_stub:revert()
    end)

    it("cancels pending startup and tears down owners exactly once", function()
        local agent = new_agent()
        local manager = make_manager(agent)
        manager:start({ kind = "new" })
        local starter_cancel_stub = spy.stub(manager._starter, "cancel")
        local status_stop_stub = spy.on(manager.status_animation, "stop")
        local permission_clear_stub =
            spy.on(manager.permission_manager, "clear")
        local file_clear_stub = spy.on(manager.file_list, "clear")
        local selection_clear_stub = spy.on(manager.code_selection, "clear")
        local diagnostics_clear_stub = spy.on(manager.diagnostics_list, "clear")
        local todo_clear_stub = spy.on(manager.todo_list, "clear")
        local options_clear_stub = spy.on(manager.config_options, "clear")
        local state_clear_stub = spy.on(manager.session_state, "clear")
        local widget_destroy_stub = spy.on(manager.widget, "destroy")
        local writer_destroy_stub = spy.on(manager.message_writer, "destroy")
        manager.chat_history.session_id = "pending-id"
        manager.chat_history.title = "pending title"
        manager.chat_history.messages = { { type = "agent", text = "old" } }
        manager.history_to_send = {}
        manager._session_ready_callbacks = { function() end }
        manager.file_list._files = { "old" }
        manager.code_selection._selections = { { lines = { "old" } } }
        manager.diagnostics_list._diagnostics = { { message = "old" } }
        manager.todo_list.total_count = 1
        manager.config_options.options = { { id = "old" } }
        manager.session_state._usage = { used = 1, size = 2 }

        manager:destroy()
        manager:destroy()

        assert.spy(starter_cancel_stub).was.called(1)
        assert.spy(status_stop_stub).was.called(1)
        assert.spy(permission_clear_stub).was.called(1)
        assert.spy(file_clear_stub).was.called(1)
        assert.spy(selection_clear_stub).was.called(1)
        assert.spy(diagnostics_clear_stub).was.called(1)
        assert.spy(todo_clear_stub).was.called(1)
        assert.spy(options_clear_stub).was.called(1)
        assert.spy(state_clear_stub).was.called(1)
        assert.spy(widget_destroy_stub).was.called(1)
        assert.spy(writer_destroy_stub).was.called(1)
        assert.is_nil(manager.chat_history.session_id)
        assert.equal("", manager.chat_history.title)
        assert.equal(0, #manager.chat_history.messages)
        assert.is_nil(manager.history_to_send)
        assert.equal(0, #manager._session_ready_callbacks)
        assert.is_true(manager.file_list:is_empty())
        assert.is_true(manager.code_selection:is_empty())
        assert.is_true(manager.diagnostics_list:is_empty())
        assert.is_true(manager.todo_list:is_empty())
        assert.equal(0, #manager.config_options.options)
        assert.is_nil(manager.session_state:get_context_used())
        starter_cancel_stub:revert()
        status_stop_stub:revert()
        permission_clear_stub:revert()
        file_clear_stub:revert()
        selection_clear_stub:revert()
        diagnostics_clear_stub:revert()
        todo_clear_stub:revert()
        options_clear_stub:revert()
        state_clear_stub:revert()
        widget_destroy_stub:revert()
        writer_destroy_stub:revert()
    end)
end)
