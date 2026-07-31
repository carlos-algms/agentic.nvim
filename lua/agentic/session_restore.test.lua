local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local SessionRegistry = require("agentic.session_registry")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local Logger

    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_ui_select_stub
    --- @type TestStub
    local vim_schedule_stub
    --- @type TestStub
    local create_stub
    --- @type TestStub
    local destroy_stub
    --- @type TestStub
    local show_session_stub
    --- @type TestStub
    local find_live_stub
    --- Stands in for the session `SessionRegistry.create` hands back
    local restored_session

    --- @param opts {chat_history?: table, list_sessions?: TestSpy, when_ready?: TestSpy, empty?: boolean, load_session_capable?: boolean}|nil
    local function create_mock_session(opts)
        opts = opts or {}
        local is_empty = opts.empty ~= false
        local caps = opts.load_session_capable ~= false
                and { loadSession = true }
            or nil

        return {
            session_id = "current-session",
            session_key = 1,
            chat_history = opts.chat_history or { messages = {} },
            file_list = {
                is_empty = function()
                    return is_empty
                end,
            },
            code_selection = {
                is_empty = function()
                    return is_empty
                end,
            },
            diagnostics_list = {
                is_empty = function()
                    return is_empty
                end,
            },
            -- No input buffer: `is_empty`'s unsent-draft branch is covered
            -- against a real one in test_multi_session.lua
            widget = { buf_nrs = {} },
            agent = {
                agent_capabilities = caps,
                cancel_session = spy.new(function() end),
                list_sessions = opts.list_sessions or spy.new(function() end),
                when_ready = opts.when_ready or spy.new(function(_self, cb)
                    cb()
                end),
            },
            load_acp_session = spy.new(function() end),
            _destroyed = false,
        }
    end

    local function select_session(index)
        local callback = vim_ui_select_stub.calls[index][3]
        local items = vim_ui_select_stub.calls[index][1]
        return callback, items
    end

    before_each(function()
        package.loaded["agentic.session_restore"] = nil
        package.loaded["agentic.utils.logger"] = nil

        SessionRestore = require("agentic.session_restore")
        Logger = require("agentic.utils.logger")

        restored_session = {
            session_key = 99,
            load_acp_session = spy.new(function() end),
        }

        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
        vim_schedule_stub = spy.stub(vim, "schedule")
        vim_schedule_stub:invokes(function(cb)
            cb()
        end)

        create_stub = spy.stub(SessionRegistry, "create")
        create_stub:invokes(function()
            return restored_session
        end)
        destroy_stub = spy.stub(SessionRegistry, "destroy")
        show_session_stub = spy.stub(SessionRegistry, "show_session")
        find_live_stub = spy.stub(SessionRegistry, "find_by_acp_session_id")
        find_live_stub:returns(nil)
    end)

    after_each(function()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
        vim_schedule_stub:revert()
        create_stub:revert()
        destroy_stub:revert()
        show_session_stub:revert()
        find_live_stub:revert()
    end)

    describe("restore_by_id", function()
        it("loads into a new session and shows it", function()
            local session = create_mock_session()

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(session.agent.list_sessions).was.called(0)
            assert.spy(session.load_acp_session).was.called(0)

            assert.spy(restored_session.load_acp_session).was.called(1)
            local call_args = restored_session.load_acp_session.calls[1]
            assert.equal("abc-123", call_args[2])
            assert.is_nil(call_args[3])
            assert.is_nil(call_args[4])

            assert.spy(show_session_stub).was.called_with(99)
        end)

        it("discards the empty session it was resolved into", function()
            local session = create_mock_session()

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(destroy_stub).was.called_with(1)
        end)

        it(
            "shows a live session and discards a distinct empty placeholder",
            function()
                local session = create_mock_session()
                local live_session = create_mock_session({ empty = false })
                live_session.session_id = "abc-123"
                live_session.session_key = 7
                find_live_stub:returns(live_session)

                SessionRestore.restore_by_id(
                    session --[[@as agentic.SessionManager]],
                    "abc-123"
                )

                assert.spy(create_stub).was.called(0)
                assert.spy(show_session_stub).was.called_with(7)
                assert.spy(destroy_stub).was.called_with(1)
            end
        )

        it("reuses a restore already in flight", function()
            restored_session.load_acp_session = spy.new(function(_, session_id)
                restored_session._restoring_session_id = session_id
            end)
            find_live_stub:invokes(function(session_id)
                if restored_session._restoring_session_id == session_id then
                    return restored_session
                end
            end)
            local session = create_mock_session()

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )
            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(create_stub).was.called(1)
            assert.spy(restored_session.load_acp_session).was.called(1)
            assert.spy(show_session_stub).was.called(2)
        end)

        -- Files, code selections and diagnostics are user work; only explicit
        -- intent may discard them.
        it("keeps a session that still holds context", function()
            local session = create_mock_session({ empty = false })

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(destroy_stub).was.called(0)
            assert.spy(restored_session.load_acp_session).was.called(1)
        end)

        -- `create` answers nil with no configured provider, and when the agent
        -- instance hands back no client. Destroying the resolved session before
        -- finding that out leaves the user no session at all and no word of why.
        it("keeps the resolved session when create fails", function()
            create_stub:invokes(function()
                return nil
            end)

            local session = create_mock_session()

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(destroy_stub).was.called(0)
            assert.spy(show_session_stub).was.called(0)
            assert.spy(logger_notify_stub).was.called(1)
        end)

        -- Checked before `create`, not inside `load_acp_session`: a late check
        -- churns a session key and swaps the widget for an operation the
        -- provider never supported.
        it("creates nothing when the agent cannot load sessions", function()
            local session = create_mock_session({
                load_session_capable = false,
            })

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(create_stub).was.called(0)
            assert.spy(show_session_stub).was.called(0)
            assert.spy(destroy_stub).was.called(0)
            assert.spy(logger_notify_stub).was.called(1)
        end)

        it("never prompts about the resolved session", function()
            local session = create_mock_session({
                chat_history = { messages = { { type = "user" } } },
                empty = false,
            })

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )

            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("does nothing when destroyed before the ready callback", function()
            local ready_callback
            local when_ready = spy.new(function(_self, callback)
                ready_callback = callback
            end)
            local session = create_mock_session({ when_ready = when_ready })

            SessionRestore.restore_by_id(
                session --[[@as agentic.SessionManager]],
                "abc-123"
            )
            session._destroyed = true
            ready_callback()

            assert.spy(vim_schedule_stub).was.called(0)
            assert.spy(create_stub).was.called(0)
            assert.spy(show_session_stub).was.called(0)
        end)

        it(
            "does nothing when destroyed before the scheduled restore",
            function()
                local scheduled_callback
                vim_schedule_stub:invokes(function(callback)
                    scheduled_callback = callback
                end)
                local session = create_mock_session()

                SessionRestore.restore_by_id(
                    session --[[@as agentic.SessionManager]],
                    "abc-123"
                )
                session._destroyed = true
                scheduled_callback()

                assert.spy(create_stub).was.called(0)
                assert.spy(show_session_stub).was.called(0)
            end
        )
    end)

    describe("show_picker with ACP session list", function()
        local acp_sessions = {
            {
                sessionId = "acp-1",
                title = "ACP First",
                updatedAt = "2026-03-20T14:30:00Z",
            },
            {
                sessionId = "acp-2",
                title = "ACP Second",
                updatedAt = "2026-03-21T09:15:00Z",
            },
        }

        local function create_acp_session(opts)
            opts = opts or {}
            local list_sessions_spy = spy.new(function(_self, _cwd, callback)
                if opts.error then
                    callback(nil, opts.error)
                else
                    callback({ sessions = opts.sessions or acp_sessions }, nil)
                end
            end)
            return create_mock_session({
                list_sessions = list_sessions_spy,
                chat_history = opts.chat_history,
                empty = opts.empty,
            })
        end

        it("uses ACP list with formatted sessions", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(session.agent.list_sessions).was.called(1)
            assert.spy(vim_ui_select_stub).was.called(1)

            local items = vim_ui_select_stub.calls[1][1]
            assert.equal(2, #items)
            assert.equal("acp-1", items[1].session_id)
            assert.equal("acp-2", items[2].session_id)
            assert.truthy(items[1].display:match("2026%-03%-20 14:30"))
            assert.truthy(items[1].display:match("ACP First"))
            assert.truthy(items[2].display:match("2026%-03%-21 09:15"))
            assert.truthy(items[2].display:match("ACP Second"))
        end)

        it("notifies error on ACP error", function()
            local session = create_acp_session({
                error = { message = "Provider error" },
            })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("Provider error")
            )
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("shows no sessions found when ACP returns empty list", function()
            local session = create_acp_session({ sessions = {} })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("loads the picked session into a new one and shows it", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({
                session_id = "acp-1",
                title = "ACP First",
                display = "2026-03-20 14:30 - ACP First",
            })

            assert.spy(restored_session.load_acp_session).was.called(1)
            local call_args = restored_session.load_acp_session.calls[1]
            assert.equal("acp-1", call_args[2])
            assert.equal("ACP First", call_args[3])

            -- Only the list picker: no second prompt about the resolved session
            assert.spy(vim_ui_select_stub).was.called(1)
            assert.spy(show_session_stub).was.called_with(99)
        end)

        -- `show_picker` shows after an async `when_ready` -> `list_sessions` ->
        -- `vim.ui.select` chain, so it must route through the eviction choke
        -- point, not show the widget directly.
        it("keeps a session with messages and adds a new one", function()
            local session = create_acp_session({
                chat_history = { messages = { { type = "user" } } },
                empty = false,
            })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "acp-1", title = "ACP First" })

            assert.spy(destroy_stub).was.called(0)
            assert.spy(create_stub).was.called(1)
            assert.spy(show_session_stub).was.called_with(99)
        end)

        it("does nothing when destroyed before the ready callback", function()
            local ready_callback
            local when_ready = spy.new(function(_self, callback)
                ready_callback = callback
            end)
            local session = create_mock_session({ when_ready = when_ready })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])
            session._destroyed = true
            ready_callback()

            assert.spy(session.agent.list_sessions).was.called(0)
            assert.spy(vim_schedule_stub).was.called(0)
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("does nothing when destroyed before the list callback", function()
            local list_callback
            local list_sessions = spy.new(function(_self, _cwd, callback)
                list_callback = callback
            end)
            local session = create_mock_session({
                list_sessions = list_sessions,
            })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])
            session._destroyed = true
            list_callback({ sessions = acp_sessions }, nil)

            assert.spy(vim_schedule_stub).was.called(0)
            assert.spy(vim_ui_select_stub).was.called(0)
            assert.spy(create_stub).was.called(0)
        end)

        it("does nothing when destroyed before the picker schedule", function()
            local scheduled_callback
            vim_schedule_stub:invokes(function(callback)
                scheduled_callback = callback
            end)
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])
            session._destroyed = true
            scheduled_callback()

            assert.spy(vim_ui_select_stub).was.called(0)
            assert.spy(create_stub).was.called(0)
        end)

        it("does nothing when destroyed before the picker choice", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])
            local callback = select_session(1)
            session._destroyed = true
            callback({ session_id = "acp-1", title = "ACP First" })

            assert.spy(create_stub).was.called(0)
            assert.spy(show_session_stub).was.called(0)
        end)
    end)
end)
