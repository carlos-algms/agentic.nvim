local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

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
                list_sessions = opts.list_sessions or spy.new(function() end),
                when_ready = spy.new(function(_self, cb)
                    cb()
                end),
            },
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
            },
            load_acp_session = spy.new(function() end),
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

        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
        vim_schedule_stub = spy.stub(vim, "schedule")
        vim_schedule_stub:invokes(function(cb)
            cb()
        end)
    end)

    after_each(function()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
        vim_schedule_stub:revert()
    end)

    describe("conflict detection", function()
        local acp_sessions = {
            {
                sessionId = "acp-1",
                title = "ACP First",
                updatedAt = "2026-03-20T14:30:00Z",
            },
        }

        local function create_acp_session(opts)
            opts = opts or {}
            local list_sessions_spy = spy.new(function(_self, _cwd, callback)
                callback({ sessions = opts.sessions or acp_sessions }, nil)
            end)
            return create_mock_session({
                list_sessions = list_sessions_spy,
                chat_history = opts.chat_history,
                session_id = opts.session_id,
            })
        end

        it("detects no conflict when session has no messages", function()
            local session = create_acp_session()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "acp-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when session_id is nil", function()
            local session = create_acp_session({
                session_id = NO_DEFAULT,
                chat_history = { messages = { { type = "user" } } },
            })

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "acp-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when chat_history is nil", function()
            local session = create_acp_session({ chat_history = nil })
            --- @diagnostic disable-next-line: inject-field
            session.chat_history = nil

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            local callback = select_session(1)
            callback({ session_id = "acp-1" })

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
            end)
            return create_mock_session({
                list_sessions = list_sessions_spy,
                chat_history = opts.chat_history,
                session_id = opts.session_id,
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
