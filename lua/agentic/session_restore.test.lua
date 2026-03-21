local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local Logger

    --- @type TestStub
    local chat_history_load_stub
    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_ui_select_stub
    --- @type TestStub
    local vim_schedule_stub

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
        },
    }

    local mock_history = {
        session_id = "restored-session",
        messages = { { type = "user", text = "Previous chat" } },
    }

    local NO_DEFAULT = {}

    --- @param opts {session_id?: string|table, chat_history?: table, list_sessions?: TestSpy}|nil
    local function create_mock_session(opts)
        opts = opts or {}
        local sid = opts.session_id
        if sid == nil then
            sid = "current-session"
        elseif sid == NO_DEFAULT then
            sid = nil
        end
        return {
            session_id = sid,
            chat_history = opts.chat_history or { messages = {} },
            agent = {
                cancel_session = spy.new(function() end),
                list_sessions = opts.list_sessions or spy.new(function()
                    return false
                end),
                when_ready = spy.new(function(_self, cb)
                    cb()
                end),
            },
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
            },
            restore_from_history = spy.new(function() end),
            load_acp_session = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(callback)
            callback(sessions or test_sessions)
        end)
    end

    local function setup_load_stub(history, err)
        chat_history_load_stub:invokes(function(_sid, callback)
            callback(history, err)
        end)
    end

    local function select_session(index)
        local callback = vim_ui_select_stub.calls[index][3]
        local items = vim_ui_select_stub.calls[index][1]
        return callback, items
    end

    before_each(function()
        package.loaded["agentic.session_restore"] = nil
        package.loaded["agentic.ui.chat_history"] = nil
        package.loaded["agentic.utils.logger"] = nil

        SessionRestore = require("agentic.session_restore")
        ChatHistory = require("agentic.ui.chat_history")
        Logger = require("agentic.utils.logger")

        chat_history_load_stub = spy.stub(ChatHistory, "load")
        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
        vim_schedule_stub = spy.stub(vim, "schedule")
        vim_schedule_stub:invokes(function(cb)
            cb()
        end)
    end)

    after_each(function()
        chat_history_load_stub:revert()
        chat_history_list_stub:revert()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
        vim_schedule_stub:revert()
    end)

    describe("show_picker local path", function()
        it("notifies and skips picker when no sessions exist", function()
            local session = create_mock_session()
            setup_list_stub({})

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("displays formatted sessions with date and title", function()
            local session = create_mock_session()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local items = vim_ui_select_stub.calls[1][1]
            local opts = vim_ui_select_stub.calls[1][2]

            assert.equal(2, #items)
            assert.equal("session-1", items[1].session_id)
            assert.truthy(items[1].display:match("First chat"))
            assert.truthy(opts.prompt:match("agentic session"))
            assert.equal(items[1].display, opts.format_item(items[1]))
        end)

        it("handles sessions with missing title", function()
            local session = create_mock_session()
            setup_list_stub({ { session_id = "s1" } })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local items = vim_ui_select_stub.calls[1][1]
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("does nothing when user cancels picker", function()
            local session = create_mock_session()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback(nil)

            assert.spy(chat_history_load_stub).was.called(0)
        end)
    end)

    describe("restore without conflict", function()
        it("restores directly with reuse_session=true", function()
            local session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(session.agent.cancel_session).was.called(0)
            assert.spy(session.widget.clear).was.called(0)
            assert.spy(session.restore_from_history).was.called(1)

            local restore_call = session.restore_from_history.calls[1]
            assert.equal(mock_history, restore_call[2])
            assert.is_true(restore_call[3].reuse_session)
            assert.spy(session.widget.show).was.called(1)
        end)
    end)

    describe("restore with conflict", function()
        local function session_with_messages()
            return create_mock_session({
                chat_history = { messages = { { type = "user" } } },
            })
        end

        it("prompts user when current session has messages", function()
            local session = session_with_messages()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(2)

            local conflict_opts = vim_ui_select_stub.calls[2][2]
            assert.truthy(
                conflict_opts.prompt:match("Current session has messages")
            )
        end)

        it("cancels restore when user chooses Cancel", function()
            local session = session_with_messages()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            local conflict_callback = vim_ui_select_stub.calls[2][3]
            conflict_callback("Cancel")

            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it(
            "clears session and restores with reuse_session=false when confirmed",
            function()
                local session = session_with_messages()
                setup_list_stub()
                setup_load_stub(mock_history)

                SessionRestore.show_picker(
                    session --[[@as agentic.SessionManager]]
                )

                local callback = select_session(1)
                callback({ session_id = "session-1" })

                local conflict_callback = vim_ui_select_stub.calls[2][3]
                conflict_callback("Clear current session and restore")

                assert.spy(session.agent.cancel_session).was.called(1)
                assert.spy(session.widget.clear).was.called(1)

                local restore_call = session.restore_from_history.calls[1]
                assert.is_false(restore_call[3].reuse_session)
            end
        )
    end)

    describe("load failures", function()
        it("shows warning on load error", function()
            local session = create_mock_session()
            setup_list_stub()
            setup_load_stub(nil, "File not found")

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
        end)

        it("shows warning on nil history without error", function()
            local session = create_mock_session()
            setup_list_stub()
            setup_load_stub(nil, nil)

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(logger_notify_stub.calls[1][1]:match("unknown error"))
        end)
    end)

    describe("conflict detection", function()
        it("detects no conflict when session has no messages", function()
            local session = create_mock_session()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when session_id is nil", function()
            local session = create_mock_session({
                session_id = NO_DEFAULT,
                chat_history = { messages = { { type = "user" } } },
            })
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when chat_history is nil", function()
            local session = create_mock_session({ chat_history = nil })
            --- @diagnostic disable-next-line: inject-field
            session.chat_history = nil
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)
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
                return true
            end)
            return create_mock_session({
                list_sessions = list_sessions_spy,
                chat_history = opts.chat_history,
                session_id = opts.session_id,
            })
        end

        it("uses ACP list with formatted sessions when capable", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(session.agent.list_sessions).was.called(1)
            assert.spy(chat_history_list_stub).was.called(0)
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

        it(
            "falls back to local ChatHistory when agent returns false",
            function()
                local session = create_mock_session()
                setup_list_stub()

                SessionRestore.show_picker(
                    session --[[@as agentic.SessionManager]]
                )

                assert.spy(session.agent.list_sessions).was.called(1)
                assert.spy(chat_history_list_stub).was.called(1)
            end
        )

        it("falls back to local on ACP error", function()
            local session = create_acp_session({
                error = { message = "Provider error" },
            })
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("Provider error")
            )
            assert.spy(chat_history_list_stub).was.called(1)
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

        it("calls load_acp_session on selection without conflict", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({
                session_id = "acp-1",
                title = "ACP First",
                display = "2026-03-20 14:30 - ACP First",
            })

            assert.spy(session.load_acp_session).was.called(1)
            local call_args = session.load_acp_session.calls[1]
            assert.equal("acp-1", call_args[2])
            assert.equal("ACP First", call_args[3])
            assert.spy(session.widget.show).was.called(1)
        end)

        it(
            "handles conflict: prompts user and calls load_acp_session on confirm",
            function()
                local session = create_acp_session({
                    chat_history = { messages = { { type = "user" } } },
                    session_id = "existing-session",
                })

                SessionRestore.show_picker(
                    session --[[@as agentic.SessionManager]]
                )

                local callback = select_session(1)
                callback({
                    session_id = "acp-1",
                    title = "ACP First",
                    display = "2026-03-20 14:30 - ACP First",
                })

                assert.spy(vim_ui_select_stub).was.called(2)

                local conflict_callback = vim_ui_select_stub.calls[2][3]
                conflict_callback("Clear current session and restore")

                assert.spy(session.load_acp_session).was.called(1)
                assert.spy(session.widget.show).was.called(1)
            end
        )
    end)
end)
