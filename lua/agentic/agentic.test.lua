--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local SessionNavigation = require("agentic.session_navigation")
local AgentInstance = require("agentic.acp.agent_instance")
local ACPHealth = require("agentic.acp.acp_health")

describe("agentic: switch_provider", function()
    --- @type TestStub
    local get_instance_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local health_check_stub
    --- @type TestStub
    local schedule_stub
    local original_provider
    local initial_tab_id

    --- @type fun()[]
    local schedule_queue = {}

    --- Flush queued vim.schedule callbacks in order
    local function flush_schedule()
        while #schedule_queue > 0 do
            local fn = table.remove(schedule_queue, 1)
            fn()
        end
    end

    before_each(function()
        original_provider = Config.provider
        initial_tab_id = vim.api.nvim_get_current_tabpage()
        logger_notify_stub = spy.stub(Logger, "notify")

        -- Queue callbacks so they run after synchronous code completes
        schedule_queue = {}
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            table.insert(schedule_queue, fn)
        end)

        -- Fake providers must pass validation
        health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
        health_check_stub:returns(true)

        get_instance_stub = spy.stub(AgentInstance, "get_instance")

        local function get_fake_agent(provider_name)
            local agent_name = provider_name or "TestProvider"
            --- @type agentic.acp.ACPClient
            local fake_agent = {}

            fake_agent.state = "ready"
            fake_agent.provider_config = {
                name = agent_name,
                initial_model = nil,
                default_mode = nil,
            }
            fake_agent.agent_info = {}

            -- Synchronous: mini.test has no event loop to pump
            function fake_agent:create_session(_handlers, callback)
                callback({
                    sessionId = "test-session-" .. agent_name,
                    configOptions = nil,
                    modes = nil,
                    models = nil,
                })
            end

            function fake_agent:cancel_session() end

            return fake_agent
        end

        get_instance_stub:invokes(function(provider_name, callback)
            local fake_agent = get_fake_agent(provider_name)
            if callback then
                callback(fake_agent)
            end
            return fake_agent
        end)
    end)

    --- Creates a registered, fully initialized session and makes it the one
    --- `SessionRegistry.resolve_or_create` returns, without opening any window.
    --- @return agentic.SessionManager
    local function create_session()
        local session = SessionRegistry.create() --[[@as agentic.SessionManager]]
        flush_schedule()
        SessionRegistry._most_recent = session

        return session
    end

    after_each(function()
        Config.provider = original_provider
        logger_notify_stub:revert()
        schedule_stub:revert()
        health_check_stub:revert()
        if get_instance_stub then
            get_instance_stub:revert()
            get_instance_stub = nil
        end

        -- Collect keys first: `destroy` mutates the table `pairs()` walks
        local keys = {}
        for key in pairs(SessionRegistry.sessions) do
            table.insert(keys, key)
        end
        for _, key in ipairs(keys) do
            SessionRegistry.destroy(key)
        end
        SessionRegistry._next_id = 0
        SessionRegistry._most_recent = nil
        SessionRegistry._previous_most_recent = nil

        vim.api.nvim_set_current_tabpage(initial_tab_id)
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
            if tp ~= initial_tab_id then
                vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tp))
            end
        end
    end)

    it("can create a session with mocked agent", function()
        local session = create_session()

        assert.is_not_nil(session)
        assert.equal(session, SessionRegistry.sessions[session.session_key])
    end)

    it("restores chat history messages after switching provider", function()
        local session = create_session()
        assert.is_not_nil(session)

        session.session_id = "old-session-id" --[[@as string]]
        local message1 = {
            type = "user",
            text = "hello",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]]
        session.chat_history:add_message(message1)

        local message2 = {
            type = "agent",
            text = "hi there",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]]
        session.chat_history:add_message(message2)

        local initial_message_count = #session.chat_history.messages
        assert.equal(2, initial_message_count)

        local Agentic = require("agentic")
        assert.are_not.equal("NewProvider", Config.provider)
        Agentic.switch_provider({ provider = "NewProvider" })
        flush_schedule()

        assert.equal("NewProvider", Config.provider)

        local new_session = SessionRegistry.list()[1] --[[@as agentic.SessionManager]]
        assert.is_not_nil(new_session)
        assert.are_not.equal(session, new_session)

        -- Fails if `replay_history_messages` never ran or `on_session_ready`
        -- never fired
        assert.equal(initial_message_count, #new_session.chat_history.messages)

        assert.equal("user", new_session.chat_history.messages[1].type)
        assert.equal("hello", new_session.chat_history.messages[1].text)
        assert.equal("agent", new_session.chat_history.messages[2].type)
        assert.equal("hi there", new_session.chat_history.messages[2].text)

        -- `history_to_send` feeds the next prompt
        assert.equal(
            initial_message_count,
            #(new_session.history_to_send or {})
        )
    end)

    it("reuses the switched session on the next open", function()
        local Agentic = require("agentic")

        local session = create_session()
        session.session_id = "old-session-id" --[[@as string]]
        assert.is_false(session.widget:is_open())

        Agentic.switch_provider({ provider = "ClosedWidgetProvider" })
        flush_schedule()

        local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
        assert.is_not_nil(replacement)

        -- The switch must repoint `_most_recent`, closed widget or not: otherwise
        -- `resolve_or_create` finds nothing and `open` spawns a THIRD session,
        -- leaving the replayed history reachable only through the picker.
        Agentic.open()
        flush_schedule()

        assert.is_nil(SessionRegistry.sessions[3])
        assert.equal(replacement, SessionRegistry.resolve_or_create())
    end)

    it("blocks switch when session is initializing", function()
        local Agentic = require("agentic")

        -- No flush: leaves the session initializing
        local session = SessionRegistry.create() --[[@as agentic.SessionManager]]
        SessionRegistry._most_recent = session
        assert.is_not_nil(session)
        assert.is_nil(session.session_id)

        Agentic.switch_provider({ provider = "TestProvider" })

        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Ii]nitializ"))
        assert.equal(session, SessionRegistry.sessions[session.session_key])
    end)

    it("blocks switch when generating", function()
        local Agentic = require("agentic")

        local session = create_session()
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true

        Agentic.switch_provider({ provider = "TestProvider" })

        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Gg]enerating"))
        assert.equal(session, SessionRegistry.sessions[session.session_key])
    end)

    it(
        "switch_provider only affects the resolved session, not the others",
        function()
            local Agentic = require("agentic")

            local first = create_session()
            first.session_id = "first-old-session" --[[@as string]]

            first.chat_history:add_message({
                type = "user",
                text = "first user msg",
                timestamp = os.time(),
                provider_name = "OriginalProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            first.chat_history:add_message({
                type = "agent",
                text = "first agent reply",
                timestamp = os.time(),
                provider_name = "OriginalProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])

            assert.equal(2, #first.chat_history.messages)

            local second = create_session()
            second.session_id = "second-session" --[[@as string]]

            second.chat_history:add_message({
                type = "user",
                text = "second question",
                timestamp = os.time(),
                provider_name = "SecondProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            second.chat_history:add_message({
                type = "agent",
                text = "second answer",
                timestamp = os.time(),
                provider_name = "SecondProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            second.chat_history:add_message({
                type = "user",
                text = "second followup",
                timestamp = os.time(),
                provider_name = "SecondProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])

            assert.equal(3, #second.chat_history.messages)

            local second_session_id_before = second.session_id
            local second_history_to_send_before = second.history_to_send
            local second_msg_count_before = #second.chat_history.messages

            -- `switch_provider` acts on the resolved session, which is
            -- `_most_recent` while no widget is visible.
            SessionRegistry._most_recent = first

            assert.are_not.equal("SwitchedProvider", Config.provider)
            Agentic.switch_provider({ provider = "SwitchedProvider" })
            flush_schedule()

            assert.equal("SwitchedProvider", Config.provider)

            -- Keys 1 and 2 are `first` and `second`; the replacement gets 3.
            local replacement = SessionRegistry.sessions[3] --[[@as agentic.SessionManager]]
            assert.is_not_nil(replacement)
            assert.is_nil(SessionRegistry.sessions[first.session_key])
            assert.are_not.equal("first-old-session", replacement.session_id)
            assert.truthy(
                tostring(replacement.session_id):match("SwitchedProvider")
            )

            -- History restored from the replaced session
            assert.equal(2, #replacement.chat_history.messages)
            assert.equal(
                "first user msg",
                replacement.chat_history.messages[1].text
            )
            assert.equal(
                "first agent reply",
                replacement.chat_history.messages[2].text
            )

            assert.is_not_nil(replacement.history_to_send)
            assert.equal(2, #replacement.history_to_send)

            -- The other session must be completely unchanged
            local current_second = SessionRegistry.sessions[second.session_key] --[[@as agentic.SessionManager]]
            assert.is_not_nil(current_second)

            assert.equal(second, current_second)

            assert.equal(second_session_id_before, current_second.session_id)

            assert.equal(
                second_history_to_send_before,
                current_second.history_to_send
            )

            assert.equal(
                second_msg_count_before,
                #current_second.chat_history.messages
            )
            assert.equal(
                "second question",
                current_second.chat_history.messages[1].text
            )
            assert.equal(
                "second answer",
                current_second.chat_history.messages[2].text
            )
            assert.equal(
                "second followup",
                current_second.chat_history.messages[3].text
            )
            assert.equal("user", current_second.chat_history.messages[1].type)
            assert.equal("agent", current_second.chat_history.messages[2].type)
            assert.equal("user", current_second.chat_history.messages[3].type)
            assert.equal(
                "SecondProvider",
                current_second.chat_history.messages[1].provider_name
            )
        end
    )

    it("reuses nothing but the replayed content on switch", function()
        local Agentic = require("agentic")

        local session = create_session()
        session.session_id = "old-session-id" --[[@as string]]
        session.config_options:set_options({
            {
                id = "mode-1",
                category = "mode",
                currentValue = "plan",
                description = "Mode",
                name = "Mode",
                options = {
                    { value = "plan", name = "Plan", description = "" },
                },
            },
        })
        assert.is_not_nil(session.config_options.mode)

        local old_chat_bufnr = session.widget.buf_nrs.chat
        session.chat_history:add_message({
            type = "user",
            text = "carried message",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]])

        session.file_list:add(vim.fn.fnamemodify("tests/init.lua", ":p"))
        session.code_selection:add({
            file_path = "tests/init.lua",
            start_line = 1,
            end_line = 2,
            lines = { "line one", "line two" },
        } --[[@as agentic.Selection]])

        Agentic.switch_provider({ provider = "FreshProvider" })
        flush_schedule()

        local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
        assert.is_not_nil(replacement)

        -- A different provider announces a different option set
        assert.is_nil(replacement.config_options.mode)
        assert.is_nil(replacement.config_options.model)
        assert.equal(0, #replacement.config_options.options)

        assert.are_not.equal(old_chat_bufnr, replacement.widget.buf_nrs.chat)
        assert.is_false(vim.api.nvim_buf_is_valid(old_chat_bufnr))

        -- Files and code selections carry over
        assert.equal(1, #replacement.file_list:get_files())
        assert.equal(1, #replacement.code_selection:get_selections())

        -- The replayed message reached the NEW chat buffer
        local lines = vim.api.nvim_buf_get_lines(
            replacement.widget.buf_nrs.chat,
            0,
            -1,
            false
        )
        assert.truthy(
            table.concat(lines, "\n"):find("carried message", 1, true)
        )
    end)

    it(
        "rebuilds the widget in the session's tab without moving the cursor",
        function()
            local Agentic = require("agentic")

            local session = create_session()
            session.session_id = "old-session-id" --[[@as string]]

            vim.cmd("tabnew")
            local widget_tab = vim.api.nvim_get_current_tabpage()
            SessionRegistry.show_session(session.session_key)
            assert.equal(widget_tab, session.widget:get_visible_tab_id())

            vim.api.nvim_set_current_tabpage(initial_tab_id)
            local win_before = vim.api.nvim_get_current_win()

            Agentic.switch_provider({ provider = "TabProvider" })
            flush_schedule()

            -- Cursor must not follow the rebuilt widget
            assert.equal(initial_tab_id, vim.api.nvim_get_current_tabpage())
            assert.equal(win_before, vim.api.nvim_get_current_win())

            local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
            assert.is_not_nil(replacement)
            assert.equal(widget_tab, replacement.widget:get_visible_tab_id())
        end
    )

    it("stop_generation resets is_generating and stops animation", function()
        local Agentic = require("agentic")

        local session = create_session()
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true

        -- Avoids a real RPC call
        local agent_stop_stub = spy.stub(session.agent, "stop_generation")
        local pm_clear_stub = spy.stub(session.permission_manager, "clear")
        local anim_stop_spy = spy.stub(session.status_animation, "stop")

        Agentic.stop_generation()

        -- Both immediate, not deferred to the callback
        assert.is_false(session.is_generating)
        assert.spy(anim_stop_spy).was.called(1)

        agent_stop_stub:revert()
        pm_clear_stub:revert()
        anim_stop_spy:revert()
    end)

    it("delegates explicit session destruction to the registry", function()
        local Agentic = require("agentic")
        local destroy_stub = spy.stub(SessionRegistry, "destroy")

        Agentic.destroy_session({ session = 7 })

        assert.spy(destroy_stub).was.called_with(7)
        destroy_stub:revert()
    end)

    it("delegates default session destruction to the registry", function()
        local Agentic = require("agentic")
        local destroy_current_stub =
            spy.stub(SessionRegistry, "destroy_current")

        Agentic.destroy_session()

        assert.spy(destroy_current_stub).was.called(1)
        destroy_current_stub:revert()
    end)

    it("delegates session selection to SessionNavigation", function()
        local Agentic = require("agentic")
        local select_stub = spy.stub(SessionNavigation, "select")

        Agentic.select_session()

        assert.spy(select_stub).was.called(1)
        select_stub:revert()
    end)

    it("delegates next-session navigation to SessionNavigation", function()
        local Agentic = require("agentic")
        local next_stub = spy.stub(SessionNavigation, "next")

        Agentic.next_session()

        assert.spy(next_stub).was.called(1)
        next_stub:revert()
    end)

    it("delegates previous-session navigation to SessionNavigation", function()
        local Agentic = require("agentic")
        local previous_stub = spy.stub(SessionNavigation, "previous")

        Agentic.prev_session()

        assert.spy(previous_stub).was.called(1)
        previous_stub:revert()
    end)

    it("does not clear prompt buffer when session cannot submit", function()
        -- No flush: `session_id` stays nil, so submit must be blocked
        local session = SessionRegistry.create() --[[@as agentic.SessionManager]]
        assert.is_nil(session.session_id)

        local input_bufnr = session.widget.buf_nrs.input
        vim.api.nvim_buf_set_lines(
            input_bufnr,
            0,
            -1,
            false,
            { "my prompt text" }
        )

        session.widget:_submit_input()

        local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
        assert.equal("my prompt text", lines[1])
    end)
end)
