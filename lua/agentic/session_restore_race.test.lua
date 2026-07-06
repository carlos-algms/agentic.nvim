--- MRE for the race condition between create_session and load_acp_session.
---
--- When new_session() is called, an async create_session ACP request goes in-flight.
--- If load_acp_session() is called before the create_session callback returns, the
--- late-firing callback can overwrite session_id with a fresh empty session, silently
--- discarding the restored context.
---
--- Two orderings are possible:
---   Race A: create_session callback fires while _is_restoring_session is still true
---            (load_session hasn't completed yet).
---   Race B: load_session completes first (clearing _is_restoring_session), then
---            create_session callback fires and overwrites session_id.
---
--- Race B is the more common one in practice: the user has to interact with the
--- restore picker, giving load_session time to complete before create fires.

--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, param-type-mismatch, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local SessionManager = require("agentic.session_manager")
local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local SlashCommands = require("agentic.acp.slash_commands")

describe("race: stale create_session after load_acp_session", function()
    local original_schedule
    local slash_stub
    local payload_stub

    before_each(function()
        original_schedule = vim.schedule
        -- Run vim.schedule callbacks synchronously so callbacks fire inline
        vim.schedule = function(fn)
            fn()
        end

        slash_stub = spy.stub(SlashCommands, "setCommands")
        payload_stub = spy.stub(ACPPayloads, "generate_user_message")
        payload_stub:invokes(function()
            return {}
        end)
    end)

    after_each(function()
        vim.schedule = original_schedule
        slash_stub:revert()
        payload_stub:revert()
    end)

    --- Build a minimal session object that can run new_session() and
    --- load_acp_session() without a real UI or ACP process.
    --- @param create_cb_ref table Mutable holder; .cb is set when create_session is called.
    --- @param load_cb_ref table  Mutable holder; .cb is set when load_session is called (for deferring in Race A).
    local function make_session(create_cb_ref, load_cb_ref)
        local cancelled = {}

        local session = {
            session_id = nil,
            _is_restoring_session = false,
            is_generating = false,
            _session_ready_callbacks = {},
            _is_first_message = true,
            _connection_error = false,
            _header_refresh_scheduled = false,
            history_to_send = nil,
            tab_page_id = 1,

            agent = {
                agent_capabilities = { loadSession = true },
                provider_config = { name = "test-provider" },
                agent_info = nil,

                create_session = function(_, _handlers, cb)
                    create_cb_ref.cb = cb -- capture; do NOT call yet
                end,

                load_session = function(_, _sid, _cwd, _mcp, _handlers, cb)
                    if load_cb_ref then
                        load_cb_ref.cb = cb -- capture; caller fires manually (Race A)
                    else
                        cb(nil) -- fire immediately (Race B)
                    end
                end,

                cancel_session = function(_, sid)
                    table.insert(cancelled, sid)
                end,
            },
            _cancelled = cancelled,

            status_animation = {
                start = function() end,
                stop = function() end,
            },
            widget = {
                clear = function() end,
                buf_nrs = { input = 0, chat = 0 },
            },
            todo_list = { clear = function() end },
            file_list = { clear = function() end },
            code_selection = { clear = function() end },
            diagnostics_list = { clear = function() end },
            config_options = {
                clear = function() end,
                mode = nil,
                model = nil,
                thought_level = nil,
                snapshot = function()
                    return {}
                end,
                restore_snapshot = function() end,
                get_mode_id = function()
                    return nil
                end,
                legacy_agent_modes = {
                    save = function()
                        return {}
                    end,
                    restore = function() end,
                    current_mode_id = nil,
                },
                legacy_agent_models = {
                    save = function()
                        return {}
                    end,
                    restore = function() end,
                },
                set_initial_model = function()
                    return false
                end,
                set_initial_mode = function() end,
                set_initial_thought_level = function() end,
            },
            permission_manager = { clear = function() end },
            message_writer = {
                write_structural_message = function() end,
                write_message = function() end,
                reset_sender_tracking = function() end,
                generate_welcome_header = function()
                    return ""
                end,
                tool_call_blocks = {},
            },
            chat_history = ChatHistory:new(),

            _build_handlers = function()
                return {}
            end,
            _set_mode_to_chat_header = function() end,
            _cancel_session = SessionManager._cancel_session,
            new_session = SessionManager.new_session,
            load_acp_session = SessionManager.load_acp_session,
        }

        return session
    end

    -- Race A: create_session callback fires BEFORE load_session completes.
    -- _is_restoring_session is still true → our guard should catch it.
    it(
        "Race A: create fires before load completes — fix should prevent overwrite",
        function()
            local create_cb_ref = {}
            local load_cb_ref = {}
            local session = make_session(create_cb_ref, load_cb_ref)

            -- Step 1: new_session in-flight (create deferred)
            session:new_session()
            assert.is_nil(session.session_id)

            -- Step 2: load_acp_session starts but load_session callback is also deferred
            session:load_acp_session("restored-id", "title", nil)
            assert.is_true(session._is_restoring_session) -- load hasn't completed yet

            -- Step 3: create fires first (while _is_restoring_session is still true)
            create_cb_ref.cb({ sessionId = "new-id" }, nil)

            -- Step 4: load completes
            load_cb_ref.cb(nil)

            assert.equal("restored-id", session.session_id)
            assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
        end
    )

    -- Race B: load_session completes BEFORE create_session callback fires.
    -- session_id is already set by the time create fires; the staleness guard catches it.
    it(
        "Race B: load completes before create fires — session_id guard prevents overwrite",
        function()
            local create_cb_ref = {}
            local session = make_session(create_cb_ref, nil) -- load fires immediately

            -- Step 1: new_session in-flight (create deferred)
            session:new_session()
            assert.is_nil(session.session_id)

            -- Step 2: load_acp_session — load fires and completes synchronously
            session:load_acp_session("restored-id", "title", nil)
            assert.equal("restored-id", session.session_id)
            assert.is_false(session._is_restoring_session) -- cleared by load callback

            -- Step 3: stale create fires after load already finished
            create_cb_ref.cb({ sessionId = "new-id" }, nil)

            assert.equal("restored-id", session.session_id)
            assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
        end
    )

    -- Race B with a FAILED stale create: response is nil and err is set.
    -- The staleness guard runs before the `if err or not response` branch, so
    -- the restored session_id survives. If the guard were moved below that
    -- branch, the error path would null out session_id and silently drop the
    -- restore. No cancellation is expected: a failed create has no sessionId.
    it(
        "Race B: stale create ERRORS after load — restored session survives",
        function()
            local create_cb_ref = {}
            local session = make_session(create_cb_ref, nil) -- load fires immediately

            -- Step 1: new_session in-flight (create deferred)
            session:new_session()
            assert.is_nil(session.session_id)

            -- Step 2: load_acp_session — load fires and completes synchronously
            session:load_acp_session("restored-id", "title", nil)
            assert.equal("restored-id", session.session_id)
            assert.is_false(session._is_restoring_session) -- cleared by load callback

            -- Step 3: stale create fails after restore already finished
            create_cb_ref.cb(nil, { message = "boom" })

            assert.equal("restored-id", session.session_id)
            assert.equal(0, #session._cancelled)
        end
    )
end)
