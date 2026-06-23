--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
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

        before_each(function()
            render_header_spy = spy.new(function() end)
            refresh_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new({ chat = test_bufnr }, {
                set_mode = function() end,
                set_model = function() end,
                set_thought_level = function() end,
            })

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    schedule_header_refresh = refresh_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _set_mode_to_chat_header = SessionManager._set_mode_to_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it("returns false when connection error occurred", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it("fires immediately via schedule when session_id exists", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
            flush_schedule()
            session.session_id = "ready-session" --[[@as string]]

            local callback_called = false
            local received_session = nil
            session:on_session_ready(function(s)
                callback_called = true
                received_session = s
            end)

            -- Not called yet (queued via vim.schedule)
            assert.is_false(callback_called)

            flush_schedule()

            assert.is_true(callback_called)
            assert.equal(session, received_session)
        end)

        it("queues callback when session_id is nil", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
            -- Don't flush — session_id stays nil

            local callback_called = false
            session:on_session_ready(function()
                callback_called = true
            end)

            -- Don't flush — callback should be queued, not fired
            assert.is_false(callback_called)
            assert.equal(1, #session._session_ready_callbacks)
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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it("clears session_ready_callbacks", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
            -- Session stays uninitialized (schedule is no-op), queue a callback
            session:on_session_ready(function() end)
            assert.equal(1, #session._session_ready_callbacks)

            session:_handle_connection_error()

            assert.equal(0, #session._session_ready_callbacks)
            assert.is_true(session._connection_error)
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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it("prepends history on first submit and clears it", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
            flush_schedule()
            session.session_id = "test-session" --[[@as string]]

            local SessionRegistry = require("agentic.session_registry")
            SessionRegistry.sessions[tab_page_id] = session

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

            -- Stub agent's send_prompt to capture the prompt
            local submitted_prompt = nil
            session.agent.send_prompt = function(_self, _sid, prompt)
                submitted_prompt = prompt
            end

            -- Submit via the internal method
            session:_handle_input_submit("new question")

            -- history_to_send should be consumed (nil)
            assert.is_nil(session.history_to_send)

            -- Prompt should contain the restored history
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
                tab_page_id = 42,
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
            session._is_restoring_session = true

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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it("schedules a refresh from on_config_options_applied", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
            local refresh_spy = spy.new(function() end)
            session.widget.schedule_header_refresh = refresh_spy

            captured_callbacks.on_config_options_applied()

            assert.spy(refresh_spy).was.called(1)
        end)

        it("schedules a refresh from on_set_mode_success", function()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
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
                tab_page_id = 7,
                _is_restoring_session = false,
                config_options = config_options,
                session_state = SessionState:new(config_options, "Test"),
                widget = {
                    schedule_header_refresh = refresh_spy,
                    render_header = render_header_spy,
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

    describe("_cancel_session: session_state clear", function()
        local SessionState = require("agentic.acp.session_state")
        --- @type TestStub
        local slash_commands_stub

        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            slash_commands_stub = spy.stub(SlashCommands, "setCommands")
        end)

        after_each(function()
            slash_commands_stub:revert()
        end)

        --- @param session_id string|nil
        --- @return agentic.SessionManager
        local function make_session(session_id)
            local ChatHistory = require("agentic.ui.chat_history")
            local config_options = {
                get_model_id = function() end,
                get_mode_id = function() end,
                clear = function() end,
            }
            local session_state = SessionState:new(config_options, "Test")
            session_state:set_usage({ used = 500, size = 1000 })

            return {
                is_generating = true,
                _is_restoring_session = true,
                session_id = session_id,
                config_options = config_options,
                session_state = session_state,
                permission_manager = { clear = function() end },
                agent = { cancel_session = function() end },
                widget = {
                    clear = function() end,
                    buf_nrs = { input = 1 },
                },
                todo_list = { clear = function() end },
                file_list = { clear = function() end },
                code_selection = { clear = function() end },
                diagnostics_list = { clear = function() end },
                status_animation = { stop = function() end },
                chat_history = ChatHistory:new(),
                history_to_send = {},
                message_writer = {
                    reset_sender_tracking = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
            } --[[@as agentic.SessionManager]]
        end

        it("clears usage when a session_id is set", function()
            local session = make_session("session-1")

            session:_cancel_session()

            assert.is_nil(session.session_state:get_context_used())
            assert.is_nil(session.session_state:get_context_size())
        end)
    end)

    describe("load_acp_session: usage not restored", function()
        local SessionState = require("agentic.acp.session_state")
        --- @type TestStub
        local slash_commands_stub

        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            slash_commands_stub = spy.stub(SlashCommands, "setCommands")
        end)

        after_each(function()
            slash_commands_stub:revert()
        end)

        it("leaves usage nil after snapshot/cancel/restore", function()
            local ChatHistory = require("agentic.ui.chat_history")
            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local test_bufnr = vim.api.nvim_create_buf(false, true)

            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")
            local config_options = AgentConfigOptions:new(
                { chat = test_bufnr },
                {
                    set_mode = function() end,
                    set_model = function() end,
                    set_thought_level = function() end,
                }
            )
            keymap_stub:revert()

            local session_state = SessionState:new(config_options, "Test")
            session_state:set_usage({ used = 9000, size = 10000 })

            --- @type agentic.SessionManager
            local session = {
                is_generating = false,
                _is_restoring_session = false,
                session_id = "old-session",
                config_options = config_options,
                session_state = session_state,
                permission_manager = { clear = function() end },
                agent = {
                    agent_capabilities = { loadSession = true },
                    agent_info = nil,
                    provider_config = { name = "Test" },
                    cancel_session = function() end,
                    load_session = function() end,
                },
                widget = {
                    clear = function() end,
                    buf_nrs = { input = 1, chat = test_bufnr },
                },
                todo_list = { clear = function() end },
                file_list = { clear = function() end },
                code_selection = { clear = function() end },
                diagnostics_list = { clear = function() end },
                status_animation = {
                    start = function() end,
                    stop = function() end,
                },
                chat_history = ChatHistory:new(),
                history_to_send = {},
                message_writer = {
                    reset_sender_tracking = function() end,
                    generate_welcome_header = function()
                        return ""
                    end,
                    write_structural_message = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
                _build_handlers = function()
                    return {}
                end,
                load_acp_session = SessionManager.load_acp_session,
            } --[[@as agentic.SessionManager]]

            session:load_acp_session("new-session", "title", nil)

            assert.is_nil(session.session_state:get_context_used())

            vim.api.nvim_buf_delete(test_bufnr, { force = true })
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
                session._is_restoring_session = true --- @diagnostic disable-line: inject-field

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

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                session_id = "session-1",
                tab_page_id = 42,
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
                diff_coordinator = { clear = function() end },
                _on_tool_call = function() end,
                chat_history = {
                    update_tool_call = function() end,
                    add_message = function() end,
                },
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            cleanup_suggestion_buffer_stub =
                spy.stub(DiffPreview, "cleanup_suggestion_buffer")
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
            cleanup_suggestion_buffer_stub:revert()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_file_edit = nil
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
            local debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
            debug_stub:revert()
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
                assert.equal(42, data.tab_page_id)
                assert.equal(test_bufnr, data.bufnr)

                vim.api.nvim_buf_delete(test_bufnr, { force = true })
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
                session._is_restoring_session = true

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

                vim.api.nvim_buf_delete(test_bufnr, { force = true })
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

    describe("_cancel_session resets is_generating", function()
        --- @type TestStub
        local slash_commands_stub

        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            slash_commands_stub = spy.stub(SlashCommands, "setCommands")
        end)

        after_each(function()
            slash_commands_stub:revert()
        end)

        it("resets is_generating to false", function()
            local ChatHistory = require("agentic.ui.chat_history")
            --- @type agentic.SessionManager
            local session = {
                is_generating = true,
                _is_restoring_session = true,
                session_id = nil,
                permission_manager = {
                    clear = spy.new(function() end),
                },
                agent = {
                    cancel_session = spy.new(function() end),
                },
                widget = {
                    clear = spy.new(function() end),
                    buf_nrs = { input = 1 },
                },
                todo_list = { clear = function() end },
                file_list = { clear = function() end },
                code_selection = { clear = function() end },
                diagnostics_list = { clear = function() end },
                config_options = { clear = function() end },
                status_animation = { stop = spy.new(function() end) },
                chat_history = ChatHistory:new(),
                history_to_send = {},
                message_writer = {
                    reset_sender_tracking = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
            } --[[@as agentic.SessionManager]]

            session:_cancel_session()

            assert.is_false(session.is_generating)
            assert.spy(session.status_animation.stop).was.called(1)
        end)
    end)

    describe("_handle_input_submit /new while generating", function()
        it("allows /new even when is_generating is true", function()
            local new_session_spy = spy.new(function() end)

            --- @type agentic.SessionManager
            local session = {
                is_generating = true,
                todo_list = { close_if_all_completed = function() end },
                new_session = new_session_spy,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            local result = session:_handle_input_submit("/new")

            assert.is_true(result)
            assert.spy(new_session_spy).was.called(1)
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
                tab_page_id = 1,
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

            -- Trigger submit — captures send_prompt callback, writes user message once
            session:_handle_input_submit("hello")

            -- Verify send_prompt callback was captured
            assert.is_not_nil(captured_callback)

            -- Reset write_message tracking so we only count finish-message writes
            write_message_spy:reset()

            -- Simulate session change (cancel/restore/new session)
            session.session_id = "new-session"

            -- Fire the stale callback (simulates provider responding after session change)
            if captured_callback then
                captured_callback(nil, nil)
            end

            -- Flush vim.schedule queue — runs the callback body
            while #schedule_queue > 0 do
                local fn = table.remove(schedule_queue, 1)
                fn()
            end

            -- Finish message must NOT be written for stale session
            assert.spy(write_message_spy).was.called(0)
        end)
    end)

    describe("new_session: on_create_session_response hook", function()
        local Config = require("agentic.config")
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        --- Build a session mock with just enough surface for the error path.
        --- new_session calls self:_cancel_session and self:_build_handlers
        --- before agent:create_session. Both are stubbed to no-ops so the
        --- test focuses on the hook invocation. The error path returns
        --- immediately after the hook, so success-path collaborators are
        --- not needed.
        --- @return agentic.SessionManager
        local function make_session()
            return {
                tab_page_id = 99,
                session_id = nil,
                status_animation = {
                    start = function() end,
                    stop = function() end,
                },
                _cancel_session = function() end,
                _build_handlers = function()
                    return {}
                end,
                new_session = SessionManager.new_session,
                agent = {
                    provider_config = { name = "Test" },
                },
            } --[[@as agentic.SessionManager]]
        end

        --- Stub agent:create_session to fire its callback synchronously
        --- with the given response/err pair.
        --- @param session agentic.SessionManager
        --- @param response agentic.acp.SessionCreationResponse|nil
        --- @param err agentic.acp.ACPError|nil
        local function fake_create_session(session, response, err)
            session.agent.create_session = function(_self, _handlers, callback)
                callback(response, err)
            end
        end

        after_each(function()
            schedule_stub:revert()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_create_session_response = nil
        end)

        it("fires on error with err set and response nil", function()
            local hook_spy = spy.new(function() end)
            Config.hooks = Config.hooks or {}
            Config.hooks.on_create_session_response = function(data)
                hook_spy(data)
            end

            local session = make_session()
            local err = { code = -32000, message = "boom" }
            fake_create_session(
                session,
                nil,
                err --[[@as agentic.acp.ACPError]]
            )

            SessionManager.new_session(session)

            assert.spy(hook_spy).was.called(1)
            local data = hook_spy.calls[1][1]
            assert.is_nil(data.session_id)
            assert.equal(99, data.tab_page_id)
            assert.is_nil(data.response)
            assert.equal(err, data.err)
            assert.is_nil(session.session_id)
        end)

        it("does not fire when no hook is configured", function()
            Config.hooks = Config.hooks or {}
            Config.hooks.on_create_session_response = nil

            local session = make_session()
            fake_create_session(session, nil, {
                code = -32000,
                message = "boom",
            } --[[@as agentic.acp.ACPError]])

            assert.has_no_errors(function()
                SessionManager.new_session(session)
            end)
        end)

        it(
            "fires on error but preserves an already-owned session_id",
            function()
                -- Contract: the hook still fires on the error path, but if a
                -- session_id is already set when this create callback fires, a
                -- restore/takeover owns the session. The staleness guard runs
                -- before the error branch, so even a FAILED stale create must not
                -- null out the owned session_id.
                local hook_call_order = {}
                Config.hooks = Config.hooks or {}
                Config.hooks.on_create_session_response = function(data)
                    table.insert(hook_call_order, {
                        err = data.err,
                        session_id_at_fire = data.session_id,
                    })
                end

                local session = make_session()
                session.session_id = "owned-id"
                fake_create_session(session, nil, {
                    code = -32000,
                    message = "boom",
                } --[[@as agentic.acp.ACPError]])

                SessionManager.new_session(session)

                assert.equal(1, #hook_call_order)
                assert.is_not_nil(hook_call_order[1].err)
                assert.equal("owned-id", session.session_id)
            end
        )
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
            local tab_ids = {}
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                table.insert(tab_ids, tab_id)
            end
            for _, tab_id in ipairs(tab_ids) do
                SessionRegistry.destroy_session(tab_id)
            end
        end)

        it(
            "applies default_thought_level when no model change is triggered",
            function()
                local tab_page_id = vim.api.nvim_get_current_tabpage()
                local _session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
                flush_schedule()

                assert.equal(1, set_initial_thought_level_stub.call_count)
                local call = set_initial_thought_level_stub.calls[1]
                -- call[1] is self, call[2] is target_value (no handler arg)
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
                tab_page_id = 1,
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
            assert.equal(1, data.tab_page_id)
            assert.equal(mock_request, data.request)
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

            -- Should not throw an error
            handlers.on_request_permission(mock_request, mock_callback)
        end)
    end)
end)
