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
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
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

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
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

                assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
                assert.truthy(header:match("\n%- %d%d%d%d%-%d%d%-%d%d"))
                assert.truthy(header:match("\n%- session id: abc123\n"))
                assert.truthy(header:match("\n%-%-%- %-%-$"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.truthy(header:match("\n%- session id: unknown\n"))
            assert.truthy(header:match("\n%-%-%- %-%-$"))
        end)

        it("includes version when provided", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                "1.2.3"
            )

            assert.truthy(header:match("^# Agentic %- Claude ACP v1%.2%.3\n"))
            assert.truthy(header:match("\n%- session id: abc123\n"))
        end)

        it("omits version when nil", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                nil
            )

            assert.truthy(header:match("^# Agentic %- Claude ACP\n"))
            assert.is_nil(header:match(" v"))
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
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                message_writer = {
                    update_tool_call_block = function() end,
                    tool_call_blocks = tool_call_blocks,
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    remove_request_by_tool_call_id = function() end,
                },
                status_animation = { start = function() end },
                _clear_diff_in_buffer = function() end,
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
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
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
end)
