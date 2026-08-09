--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local SessionNavigation = require("agentic.session_navigation")
local ProviderSwitcher = require("agentic.provider_switcher")
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
    --- @type TestStub[]
    local transient_stubs
    local original_provider
    local initial_tab_id
    local deferred_create_callback
    local create_session_calls
    --- @type table<integer, boolean>
    local initial_tabs

    --- @type fun()[]
    local schedule_queue = {}

    --- Flush queued vim.schedule callbacks in order
    local function flush_schedule()
        while #schedule_queue > 0 do
            local fn = table.remove(schedule_queue, 1)
            fn()
        end
    end

    --- @param target table
    --- @param method string
    --- @return TestStub stub
    local function track_stub(target, method)
        local stub = spy.stub(target, method)
        transient_stubs[#transient_stubs + 1] = stub
        return stub
    end

    before_each(function()
        original_provider = Config.provider
        initial_tab_id = vim.api.nvim_get_current_tabpage()
        initial_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            initial_tabs[tabpage] = true
        end
        transient_stubs = {}
        deferred_create_callback = nil
        create_session_calls = 0
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

            function fake_agent:when_ready(on_ready, _on_failure)
                vim.schedule(function()
                    on_ready(fake_agent)
                end)
            end

            -- Synchronous: mini.test has no event loop to pump
            function fake_agent:create_session(_handlers, callback)
                create_session_calls = create_session_calls + 1
                if agent_name == "DeferredProvider" then
                    deferred_create_callback = callback
                    return
                end

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

    it(
        "open creates one manager and one ACP session with no current session",
        function()
            local Agentic = require("agentic")

            Agentic.open({ auto_add_to_context = false })
            flush_schedule()

            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            assert.equal(1, get_instance_stub.call_count)
            assert.equal(1, create_session_calls)
            assert.is_not_nil(SessionRegistry.sessions[1].session_id)
        end
    )

    it(
        "explicit new creates one manager and one ACP session with no current session",
        function()
            local Agentic = require("agentic")

            Agentic.new_session({ auto_add_to_context = false })
            flush_schedule()

            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            assert.equal(1, get_instance_stub.call_count)
            assert.equal(1, create_session_calls)
            assert.is_not_nil(SessionRegistry.sessions[1].session_id)
        end
    )

    it("open creates no target when provider resolution fails", function()
        local Agentic = require("agentic")
        local FloatingMessage = require("agentic.ui.floating_message")
        local show_warning_stub = track_stub(FloatingMessage, "show")
        health_check_stub:revert()
        get_instance_stub:revert()
        Config.provider = "missing-provider"

        Agentic.open({ auto_add_to_context = false })
        flush_schedule()

        assert.equal(0, vim.tbl_count(SessionRegistry.sessions))
        assert.equal(0, get_instance_stub.call_count)
        assert.equal(0, create_session_calls)
        assert.spy(show_warning_stub).was.called(1)
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
        for _, stub in ipairs(transient_stubs) do
            stub:revert()
        end
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

        if vim.api.nvim_tabpage_is_valid(initial_tab_id) then
            vim.api.nvim_set_current_tabpage(initial_tab_id)
        end
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
            if not initial_tabs[tp] and vim.api.nvim_tabpage_is_valid(tp) then
                vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tp))
            end
        end
    end)

    it("can create a session with mocked agent", function()
        local session = create_session()

        assert.is_not_nil(session)
        assert.equal(session, SessionRegistry.sessions[session.session_key])
    end)

    it(
        "creates only the requested provider when the registry is empty",
        function()
            local provider_names = {}
            local ready_callbacks = {}

            get_instance_stub:invokes(function(provider_name, callback)
                provider_names[#provider_names + 1] = provider_name
                ready_callbacks[provider_name] = callback

                local fake_agent = {
                    state = "connecting",
                    provider_config = {
                        name = provider_name,
                        initial_model = nil,
                        default_mode = nil,
                    },
                    agent_info = {},
                }

                function fake_agent:cancel_session() end
                function fake_agent:when_ready(on_ready, _on_failure)
                    ready_callbacks[provider_name] = on_ready
                end

                return fake_agent
            end)

            Config.provider = "OldProvider"

            local Agentic = require("agentic")
            Agentic.switch_provider({ provider = "RequestedProvider" })

            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            local session = SessionRegistry.list()[1]
            assert.is_not_nil(session)
            assert.equal(
                "RequestedProvider",
                session.agent.provider_config.name
            )
            assert.same({ "RequestedProvider" }, provider_names)
            assert.is_not_nil(ready_callbacks.RequestedProvider)
            assert.is_nil(ready_callbacks.OldProvider)
            assert.equal("RequestedProvider", Config.provider)
        end
    )

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
        session.chat_history.title = "Original session title"

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
        assert.equal("Original session title", new_session.chat_history.title)

        -- `history_to_send` feeds the next prompt
        assert.equal(
            initial_message_count,
            #(new_session.history_to_send or {})
        )
    end)

    it("keeps the original session when replacement creation fails", function()
        local Agentic = require("agentic")
        local session = create_session()
        session.session_id = "old-session-id" --[[@as string]]
        local create_stub = track_stub(SessionRegistry, "create")
        create_stub:returns(nil)

        Agentic.switch_provider({ provider = "MissingProvider" })

        assert.spy(create_stub).was.called_with("MissingProvider")
        assert.equal(original_provider, Config.provider)
        assert.equal(session, SessionRegistry.sessions[session.session_key])
        assert.spy(logger_notify_stub).was.called(1)
    end)

    it(
        "keeps the original session when replacement creation fails asynchronously",
        function()
            local Agentic = require("agentic")
            local session = create_session()
            session.session_id = "old-session-id" --[[@as string]]
            session.chat_history:add_message({
                type = "user",
                text = "keep this message",
                timestamp = os.time(),
                provider_name = "OriginalProvider",
            } --[[@as agentic.ui.ChatHistory.Message]])

            Agentic.switch_provider({ provider = "DeferredProvider" })
            flush_schedule()

            assert.equal(session, SessionRegistry.sessions[session.session_key])
            assert.equal(original_provider, Config.provider)
            assert.is_not_nil(deferred_create_callback)

            deferred_create_callback(nil, { message = "creation failed" })
            flush_schedule()

            assert.equal(session, SessionRegistry.sessions[session.session_key])
            assert.equal(1, #session.chat_history.messages)
            assert.equal(
                "keep this message",
                session.chat_history.messages[1].text
            )
            assert.equal(original_provider, Config.provider)
            assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
            assert.spy(logger_notify_stub).was.called()
        end
    )

    it("aborts a deferred provider switch when generation starts", function()
        local Agentic = require("agentic")
        local session = create_session()
        session.session_id = "old-session-id" --[[@as string]]

        Agentic.switch_provider({ provider = "DeferredProvider" })
        flush_schedule()
        session.is_generating = true

        deferred_create_callback({
            sessionId = "deferred-session",
            configOptions = nil,
            modes = nil,
            models = nil,
        })
        flush_schedule()

        assert.equal(session, SessionRegistry.sessions[session.session_key])
        assert.equal(original_provider, Config.provider)
        assert.equal(1, vim.tbl_count(SessionRegistry.sessions))
        assert.spy(logger_notify_stub).was.called()
    end)

    it("captures provider-switch state at replacement commit", function()
        local Agentic = require("agentic")
        local session = create_session()
        session.session_id = "old-session-id" --[[@as string]]

        Agentic.switch_provider({ provider = "DeferredProvider" })
        flush_schedule()

        session.chat_history:add_message({
            type = "user",
            text = "added while replacement initialized",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]])
        session.chat_history.title = "Updated title"
        session.file_list:add(vim.fn.fnamemodify("tests/init.lua", ":p"))
        session.code_selection:add({
            file_path = "tests/init.lua",
            start_line = 1,
            end_line = 1,
            lines = { "late context" },
        } --[[@as agentic.Selection]])
        vim.cmd("tabnew")
        local latest_widget_tab = vim.api.nvim_get_current_tabpage()
        SessionRegistry.show_session(session.session_key)
        flush_schedule()
        vim.api.nvim_set_current_tabpage(initial_tab_id)

        deferred_create_callback({
            sessionId = "deferred-session",
            configOptions = nil,
            modes = nil,
            models = nil,
        })
        flush_schedule()

        local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
        assert.is_not_nil(replacement)
        assert.equal(1, #replacement.chat_history.messages)
        assert.equal(
            "added while replacement initialized",
            replacement.chat_history.messages[1].text
        )
        assert.equal("Updated title", replacement.chat_history.title)
        assert.equal(1, #replacement.file_list:get_files())
        assert.equal(1, #replacement.code_selection:get_selections())
        assert.equal(latest_widget_tab, replacement.widget:get_visible_tab_id())
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
            flush_schedule()

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

    it(
        "keeps the replacement hidden when the original tab closes during teardown",
        function()
            local Agentic = require("agentic")
            local session = create_session()
            session.session_id = "old-session-id" --[[@as string]]

            vim.cmd("tabnew")
            local widget_tab = vim.api.nvim_get_current_tabpage()
            SessionRegistry.show_session(session.session_key)
            flush_schedule()
            vim.api.nvim_set_current_tabpage(initial_tab_id)

            local original_destroy = SessionRegistry.destroy
            local destroy_stub = track_stub(SessionRegistry, "destroy")
            destroy_stub:invokes(function(session_key)
                original_destroy(session_key)
                if vim.api.nvim_tabpage_is_valid(widget_tab) then
                    vim.cmd(
                        "tabclose "
                            .. vim.api.nvim_tabpage_get_number(widget_tab)
                    )
                end
            end)

            Agentic.switch_provider({ provider = "TabClosedProvider" })
            flush_schedule()

            local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
            assert.is_not_nil(replacement)
            assert.is_nil(replacement.widget:get_visible_tab_id())
            assert.equal(initial_tab_id, vim.api.nvim_get_current_tabpage())
        end
    )

    it(
        "re-resolves the replacement anchor after old-session teardown",
        function()
            local Agentic = require("agentic")
            local session = create_session()
            session.session_id = "old-session-id" --[[@as string]]

            vim.cmd("tabnew")
            local widget_tab = vim.api.nvim_get_current_tabpage()
            SessionRegistry.show_session(session.session_key)
            flush_schedule()
            local stale_anchor = session.widget:find_first_non_widget_window()
            assert.is_not_nil(stale_anchor)
            vim.api.nvim_set_current_tabpage(initial_tab_id)

            local original_destroy = SessionRegistry.destroy
            local destroy_stub = track_stub(SessionRegistry, "destroy")
            destroy_stub:invokes(function(session_key)
                original_destroy(session_key)
                vim.api.nvim_win_call(stale_anchor, function()
                    vim.cmd("new")
                end)
                vim.api.nvim_win_close(stale_anchor, true)
            end)

            Agentic.switch_provider({ provider = "ReanchoredProvider" })
            flush_schedule()

            local replacement = SessionRegistry.sessions[2] --[[@as agentic.SessionManager]]
            assert.is_not_nil(replacement)
            assert.equal(widget_tab, replacement.widget:get_visible_tab_id())
            assert.equal(initial_tab_id, vim.api.nvim_get_current_tabpage())
        end
    )

    it(
        "rejects an ineligible live anchor after old-session teardown",
        function()
            local Agentic = require("agentic")
            local session = create_session()
            session.session_id = "old-session-id" --[[@as string]]

            vim.cmd("tabnew")
            SessionRegistry.show_session(session.session_key)
            flush_schedule()
            local stale_anchor = session.widget:find_first_non_widget_window()
            assert.is_not_nil(stale_anchor)
            vim.api.nvim_set_current_tabpage(initial_tab_id)

            local eligible_anchor
            local original_destroy = SessionRegistry.destroy
            local destroy_stub = track_stub(SessionRegistry, "destroy")
            destroy_stub:invokes(function(session_key)
                original_destroy(session_key)
                vim.api.nvim_win_call(stale_anchor, function()
                    vim.cmd("new")
                    eligible_anchor = vim.api.nvim_get_current_win()
                end)
                vim.bo[vim.api.nvim_win_get_buf(stale_anchor)].filetype =
                    "TelescopePrompt"
            end)

            local placement_anchor
            local original_show = SessionRegistry.show_session
            local show_stub = track_stub(SessionRegistry, "show_session")
            show_stub:invokes(function(...)
                placement_anchor = vim.api.nvim_get_current_win()
                original_show(...)
            end)

            Agentic.switch_provider({ provider = "EligibleAnchorProvider" })
            flush_schedule()

            assert.is_not_nil(eligible_anchor)
            assert.equal(eligible_anchor, placement_anchor)
            assert.are_not.equal(stale_anchor, placement_anchor)
        end
    )

    it("stop_generation resets is_generating and stops animation", function()
        local Agentic = require("agentic")

        local session = create_session()
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true

        -- Avoids a real RPC call
        local stop_generation_stub =
            track_stub(session.agent, "stop_generation")
        local permission_clear_stub =
            track_stub(session.permission_manager, "clear")
        local anim_stop_spy = track_stub(session.status_animation, "stop")

        Agentic.stop_generation()

        -- Both immediate, not deferred to the callback
        assert.spy(stop_generation_stub).was.called(1)
        assert
            .spy(stop_generation_stub).was
            .called_with(session.agent, "test-session-id")
        assert.spy(permission_clear_stub).was.called(1)
        assert.is_false(session.is_generating)
        assert.spy(anim_stop_spy).was.called(1)
    end)

    -- Creation spawns a provider subprocess. Stopping generation with nothing
    -- live used to create a session only to immediately reset it: a no-op with
    -- a real side effect.
    it("stop_generation creates no session when none is live", function()
        local Agentic = require("agentic")

        Agentic.stop_generation()

        assert.equal(0, vim.tbl_count(SessionRegistry.sessions))
    end)

    it("delegates explicit session destruction to the registry", function()
        local Agentic = require("agentic")
        local live_session = {}
        local get_stub = track_stub(SessionRegistry, "get")
        get_stub:returns(live_session)
        local destroy_stub = track_stub(SessionRegistry, "destroy")

        Agentic.destroy_session({ session = 7 })

        assert.spy(get_stub).was.called_with(7)
        assert.spy(destroy_stub).was.called(1)
        assert.spy(destroy_stub).was.called_with(7)
        assert.spy(logger_notify_stub).was.called(0)
    end)

    it("reports an unknown explicit session without destroying it", function()
        local Agentic = require("agentic")
        local get_stub = track_stub(SessionRegistry, "get")
        get_stub:returns(nil)
        local destroy_stub = track_stub(SessionRegistry, "destroy")

        Agentic.destroy_session({ session = 9999 })

        assert.spy(get_stub).was.called_with(9999)
        assert.spy(logger_notify_stub).was.called(1)
        assert.truthy(tostring(logger_notify_stub.calls[1][1]):find("9999"))
        assert.spy(destroy_stub).was.called(0)
    end)

    it("delegates default session destruction to the registry", function()
        local Agentic = require("agentic")
        local destroy_current_stub =
            track_stub(SessionRegistry, "destroy_current")

        Agentic.destroy_session()

        assert.spy(destroy_current_stub).was.called(1)
    end)

    it("delegates session selection to SessionNavigation", function()
        local Agentic = require("agentic")
        local select_stub = track_stub(SessionNavigation, "select")

        Agentic.select_session()

        assert.spy(select_stub).was.called(1)
    end)

    it("delegates next-session navigation to SessionNavigation", function()
        local Agentic = require("agentic")
        local next_stub = track_stub(SessionNavigation, "next")

        Agentic.next_session()

        assert.spy(next_stub).was.called(1)
    end)

    it("delegates previous-session navigation to SessionNavigation", function()
        local Agentic = require("agentic")
        local previous_stub = track_stub(SessionNavigation, "previous")

        Agentic.prev_session()

        assert.spy(previous_stub).was.called(1)
    end)

    it("delegates provider switching to ProviderSwitcher", function()
        local Agentic = require("agentic")
        local switch_stub = track_stub(ProviderSwitcher, "switch")
        local opts = { provider = "TestProvider" }

        Agentic.switch_provider(opts)

        assert.spy(switch_stub).was.called_with(opts)
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

    it("does not create a session from clipboard callbacks", function()
        local Agentic = require("agentic")
        local original_image_paste_enabled = Config.image_paste.enabled
        local original_clipboard = package.loaded["agentic.ui.clipboard"]
        local original_widget_registry =
            package.loaded["agentic.ui.widget_registry"]
        local clipboard_opts

        package.loaded["agentic.ui.clipboard"] = {
            setup = function(opts)
                clipboard_opts = opts
            end,
        }
        package.loaded["agentic.ui.widget_registry"] = {
            get = function()
                return { session_key = 9999 }
            end,
        }
        Config.image_paste.enabled = true

        local get_stub = track_stub(SessionRegistry, "get")
        get_stub:returns(nil)
        local create_stub = track_stub(SessionRegistry, "create")
        local resolve_stub = track_stub(SessionRegistry, "resolve_or_create")
        local new_signal_stub = track_stub(vim.uv, "new_signal")
        new_signal_stub:returns(nil)

        Agentic.setup({})

        local is_in_widget = clipboard_opts.is_cursor_in_widget()
        local pasted = clipboard_opts.on_paste("image.png")

        Config.image_paste.enabled = original_image_paste_enabled
        package.loaded["agentic.ui.clipboard"] = original_clipboard
        package.loaded["agentic.ui.widget_registry"] = original_widget_registry

        assert.is_false(is_in_widget)
        assert.is_false(pasted)
        assert.spy(get_stub).was.called(2)
        assert.spy(get_stub).was.called_with(9999)
        assert.spy(create_stub).was.called(0)
        assert.spy(resolve_stub).was.called(0)
    end)
end)

describe("agentic: restore entry points", function()
    local Agentic = require("agentic")
    local SessionRestore = require("agentic.session_restore")
    local current_stub
    local resolve_stub
    local get_instance_stub
    local picker_stub
    local restore_stub

    before_each(function()
        current_stub = spy.stub(SessionRegistry, "current")
        resolve_stub = spy.stub(SessionRegistry, "resolve_or_create")
        get_instance_stub = spy.stub(AgentInstance, "get_instance")
        picker_stub = spy.stub(SessionRestore, "show_picker")
        restore_stub = spy.stub(SessionRestore, "restore_by_id")
    end)

    after_each(function()
        current_stub:revert()
        resolve_stub:revert()
        get_instance_stub:revert()
        picker_stub:revert()
        restore_stub:revert()
    end)

    it(
        "lists with a directly resolved client when no session exists",
        function()
            local agent = { provider_config = { name = "Test" } }
            current_stub:returns(nil)
            get_instance_stub:returns(agent)

            Agentic.restore_session()

            assert.equal(1, current_stub.call_count)
            assert.equal(1, get_instance_stub.call_count)
            assert.spy(get_instance_stub).was.called_with(Config.provider)
            assert.spy(resolve_stub).was.called(0)
            assert.spy(picker_stub).was.called_with({
                agent = agent,
                provider_name = Config.provider,
            })
        end
    )

    it("passes the current source and its injected client", function()
        local agent = { provider_config = { name = "Test" } }
        local source = {
            agent = agent,
            provider_name = "claude-acp",
        }
        current_stub:returns(source)

        Agentic.restore_session_by_id("saved-id")

        assert.spy(get_instance_stub).was.called(0)
        assert.spy(resolve_stub).was.called(0)
        assert.spy(restore_stub).was.called_with({
            agent = agent,
            provider_name = "claude-acp",
            source = source,
        }, "saved-id")
    end)

    it("creates no placeholder when provider resolution fails", function()
        current_stub:returns(nil)
        get_instance_stub:returns(nil)

        Agentic.restore_session()

        assert.equal(1, current_stub.call_count)
        assert.equal(1, get_instance_stub.call_count)
        assert.spy(resolve_stub).was.called(0)
        assert.spy(picker_stub).was.called(0)
        assert.spy(restore_stub).was.called(0)
    end)
end)
