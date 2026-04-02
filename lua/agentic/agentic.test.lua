--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
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

    --- Flush all queued vim.schedule callbacks in order
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

        -- Queue vim.schedule callbacks so they run after synchronous code completes
        schedule_queue = {}
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            table.insert(schedule_queue, fn)
        end)

        -- Stub health check so fake providers pass validation
        health_check_stub = spy.stub(ACPHealth, "check_configured_provider")
        health_check_stub:returns(true)

        -- Mock AgentInstance globally for all tests
        get_instance_stub = spy.stub(AgentInstance, "get_instance")

        -- Create a function that returns the appropriate agent based on provider
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

            -- Mock create_session method (synchronous to work with mini.test)
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

    after_each(function()
        Config.provider = original_provider
        logger_notify_stub:revert()
        schedule_stub:revert()
        health_check_stub:revert()
        if get_instance_stub then
            get_instance_stub:revert()
            get_instance_stub = nil
        end

        -- Clean up any sessions created during tests
        -- Collect IDs first to avoid mutating the table during pairs() iteration
        local tab_ids = {}
        for tab_id, _ in pairs(SessionRegistry.sessions) do
            table.insert(tab_ids, tab_id)
        end
        for _, tab_id in ipairs(tab_ids) do
            SessionRegistry.destroy_session(tab_id)
        end

        -- Close any extra tabs created during the test
        vim.api.nvim_set_current_tabpage(initial_tab_id)
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
            if tp ~= initial_tab_id then
                vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tp))
            end
        end
    end)

    it("can create a session with mocked agent", function()
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        flush_schedule()
        assert.is_not_nil(session)
        SessionRegistry.sessions[tab_page_id] = session
    end)

    it("restores chat history messages after switching provider", function()
        -- Setup: Create initial session with messages manually
        local tab_page_id = vim.api.nvim_get_current_tabpage()
        local SessionManager = require("agentic.session_manager")

        -- Create initial session manually
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        flush_schedule()
        assert.is_not_nil(session)

        SessionRegistry.sessions[tab_page_id] = session

        -- Manually set session_id and initialize chat_history
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

        -- Get initial message count
        local initial_message_count = #session.chat_history.messages
        assert.equal(2, initial_message_count)

        -- Now do the provider switch
        local Agentic = require("agentic")
        assert.are_not.equal("NewProvider", Config.provider)
        Agentic.switch_provider({ provider = "NewProvider" })
        flush_schedule()

        -- Verify Config.provider was updated by switch_provider
        assert.equal("NewProvider", Config.provider)

        -- Get new session
        local new_session = SessionRegistry.sessions[tab_page_id] --[[@as agentic.SessionManager]]
        assert.is_not_nil(new_session)
        assert.are_not.equal(session, new_session)

        -- CRITICAL TEST: Verify history messages were restored
        -- This test will fail if replay_history_messages wasn't called
        -- or if on_session_ready didn't fire
        assert.equal(initial_message_count, #new_session.chat_history.messages)

        -- Verify message content is correct
        assert.equal("user", new_session.chat_history.messages[1].type)
        assert.equal("hello", new_session.chat_history.messages[1].text)
        assert.equal("agent", new_session.chat_history.messages[2].type)
        assert.equal("hi there", new_session.chat_history.messages[2].text)

        -- Verify history_to_send was set for next prompt
        assert.equal(
            initial_message_count,
            #(new_session.history_to_send or {})
        )
    end)

    it("blocks switch when session is initializing", function()
        local Agentic = require("agentic")
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create session without flushing schedule — keeps it in initializing state
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        assert.is_not_nil(session)
        assert.is_nil(session.session_id) -- Not initialized yet
        SessionRegistry.sessions[tab_page_id] = session

        -- Try to switch
        Agentic.switch_provider({ provider = "TestProvider" })

        -- Should notify user about initialization
        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Ii]nitializ"))
        assert.equal(session, SessionRegistry.sessions[tab_page_id])
    end)

    it("blocks switch when generating", function()
        local Agentic = require("agentic")
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create initialized session
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        flush_schedule()
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true -- Set generating flag
        SessionRegistry.sessions[tab_page_id] = session

        -- Try to switch
        Agentic.switch_provider({ provider = "TestProvider" })

        -- Should notify user
        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Gg]enerating"))
        assert.equal(session, SessionRegistry.sessions[tab_page_id])
    end)

    it(
        "switch_provider only affects the current tabpage, not other tabs",
        function()
            local Agentic = require("agentic")
            local SessionManager = require("agentic.session_manager")

            -- Tab 1: current tabpage
            local tab1_id = vim.api.nvim_get_current_tabpage()
            local session1 = SessionManager:new(tab1_id) --[[@as agentic.SessionManager]]
            flush_schedule()
            assert.is_not_nil(session1)

            SessionRegistry.sessions[tab1_id] = session1
            session1.session_id = "tab1-old-session" --[[@as string]]

            session1.chat_history:add_message({
                type = "user",
                text = "tab1 user msg",
                timestamp = os.time(),
                provider_name = "OriginalProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            session1.chat_history:add_message({
                type = "agent",
                text = "tab1 agent reply",
                timestamp = os.time(),
                provider_name = "OriginalProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])

            assert.equal(2, #session1.chat_history.messages)

            -- Tab 2: create a new tabpage with distinct state
            vim.cmd("tabnew")
            local tab2_id = vim.api.nvim_get_current_tabpage()
            assert.are_not.equal(tab1_id, tab2_id)

            local session2 = SessionManager:new(tab2_id) --[[@as agentic.SessionManager]]
            flush_schedule()
            assert.is_not_nil(session2)

            SessionRegistry.sessions[tab2_id] = session2
            session2.session_id = "tab2-session" --[[@as string]]

            session2.chat_history:add_message({
                type = "user",
                text = "tab2 question",
                timestamp = os.time(),
                provider_name = "Tab2Provider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            session2.chat_history:add_message({
                type = "agent",
                text = "tab2 answer",
                timestamp = os.time(),
                provider_name = "Tab2Provider",
            } --[[@as agentic.ui.ChatHistory.Message]])
            session2.chat_history:add_message({
                type = "user",
                text = "tab2 followup",
                timestamp = os.time(),
                provider_name = "Tab2Provider",
            } --[[@as agentic.ui.ChatHistory.Message]])

            assert.equal(3, #session2.chat_history.messages)

            -- Snapshot tab2 state before switch
            local tab2_session_id_before = session2.session_id
            local tab2_history_to_send_before = session2.history_to_send
            local tab2_msg_count_before = #session2.chat_history.messages

            -- Switch back to tab1 (switch_provider operates on current tabpage)
            vim.api.nvim_set_current_tabpage(tab1_id)
            assert.equal(tab1_id, vim.api.nvim_get_current_tabpage())

            -- Perform provider switch on tab1 only
            assert.are_not.equal("SwitchedProvider", Config.provider)
            Agentic.switch_provider({ provider = "SwitchedProvider" })
            flush_schedule()

            -- Verify Config.provider was updated by switch_provider
            assert.equal("SwitchedProvider", Config.provider)

            -- === Tab 1: session was updated ===
            local new_session1 = SessionRegistry.sessions[tab1_id] --[[@as agentic.SessionManager]]
            assert.is_not_nil(new_session1)
            assert.are_not.equal("tab1-old-session", new_session1.session_id)
            assert.truthy(
                tostring(new_session1.session_id):match("SwitchedProvider")
            )

            -- Chat history restored from tab1's original messages
            assert.equal(2, #new_session1.chat_history.messages)
            assert.equal(
                "tab1 user msg",
                new_session1.chat_history.messages[1].text
            )
            assert.equal(
                "tab1 agent reply",
                new_session1.chat_history.messages[2].text
            )

            -- history_to_send set with tab1's saved messages
            assert.is_not_nil(new_session1.history_to_send)
            assert.equal(2, #new_session1.history_to_send)

            -- === Tab 2: must be completely unchanged ===
            local current_session2 = SessionRegistry.sessions[tab2_id] --[[@as agentic.SessionManager]]
            assert.is_not_nil(current_session2)

            -- Same session object (not recreated)
            assert.equal(session2, current_session2)

            -- session_id unchanged
            assert.equal(tab2_session_id_before, current_session2.session_id)

            -- history_to_send unchanged (was nil)
            assert.equal(
                tab2_history_to_send_before,
                current_session2.history_to_send
            )

            -- chat_history messages: same count, text, types, and provider_names
            assert.equal(
                tab2_msg_count_before,
                #current_session2.chat_history.messages
            )
            assert.equal(
                "tab2 question",
                current_session2.chat_history.messages[1].text
            )
            assert.equal(
                "tab2 answer",
                current_session2.chat_history.messages[2].text
            )
            assert.equal(
                "tab2 followup",
                current_session2.chat_history.messages[3].text
            )
            assert.equal("user", current_session2.chat_history.messages[1].type)
            assert.equal(
                "agent",
                current_session2.chat_history.messages[2].type
            )
            assert.equal("user", current_session2.chat_history.messages[3].type)
            assert.equal(
                "Tab2Provider",
                current_session2.chat_history.messages[1].provider_name
            )
        end
    )

    it("stop_generation resets is_generating and stops animation", function()
        local Agentic = require("agentic")
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create an initialized session
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        flush_schedule()
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true
        SessionRegistry.sessions[tab_page_id] = session

        -- Stub agent.stop_generation to avoid real RPC call
        local agent_stop_stub = spy.stub(session.agent, "stop_generation")
        -- Stub permission_manager.clear
        local pm_clear_stub = spy.stub(session.permission_manager, "clear")
        -- Spy on status_animation.stop
        local anim_stop_spy = spy.stub(session.status_animation, "stop")

        Agentic.stop_generation()

        -- is_generating must be false immediately (not waiting for callback)
        assert.is_false(session.is_generating)
        -- animation must have been stopped immediately
        assert.spy(anim_stop_spy).was.called(1)

        agent_stop_stub:revert()
        pm_clear_stub:revert()
        anim_stop_spy:revert()
    end)

    it("does not clear prompt buffer when session cannot submit", function()
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create session without flushing — session_id is nil
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        assert.is_nil(session.session_id)
        SessionRegistry.sessions[tab_page_id] = session

        -- Write text to the input buffer
        local input_bufnr = session.widget.buf_nrs.input
        vim.api.nvim_buf_set_lines(
            input_bufnr,
            0,
            -1,
            false,
            { "my prompt text" }
        )

        -- Try to submit (session not ready, should be blocked)
        session.widget:_submit_input()

        -- Prompt buffer should NOT have been cleared
        local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
        assert.equal("my prompt text", lines[1])
    end)
end)
