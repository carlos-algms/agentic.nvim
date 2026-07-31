--- MRE: `new_session`'s in-flight create_session callback can fire after
--- `load_acp_session` and overwrite session_id with a fresh empty session,
--- silently discarding the restored context.
---
--- Race A: create callback fires while _is_restoring_session is still true.
--- Race B: load completes (clearing _is_restoring_session), then create fires.
--- Race B dominates in practice: the restore picker gives load time to finish.

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

    --- Queued `vim.schedule` callbacks, in enqueue order. Inline execution
    --- cannot express ordering: a callback a later tick must observe would run
    --- before that tick exists.
    --- @type fun()[]
    local queue = {}

    --- Runs every queued callback, including ones enqueued while draining.
    local function drain()
        local index = 1

        while index <= #queue do
            local fn = queue[index]
            index = index + 1
            fn()
        end

        queue = {}
    end

    before_each(function()
        queue = {}
        original_schedule = vim.schedule
        vim.schedule = function(fn)
            queue[#queue + 1] = fn
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

    --- Runs new_session() and load_acp_session() without a real UI or ACP process.
    --- @param create_cb_ref table Mutable holder; .cb is set when create_session is called.
    --- @param load_cb_ref table Mutable holder; .cb set on load_session, for deferring in Race A.
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
            session_key = 1,

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
                get_visible_tab_id = function()
                    return 1
                end,
            },
            todo_list = { clear = function() end },
            file_list = { clear = function() end },
            code_selection = { clear = function() end },
            diagnostics_list = { clear = function() end },
            session_state = { clear = function() end },
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
                _legacy_modes_set = nil,
                _legacy_models_set = nil,
                set_legacy_modes = function(self, modes_info)
                    self._legacy_modes_set = modes_info
                end,
                set_legacy_models = function(self, models_info)
                    self._legacy_models_set = models_info
                end,
                set_options = function(self, opts)
                    self._config_options_set = opts
                end,
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
            _bootstrap_session = SessionManager._bootstrap_session,
            new_session = SessionManager.new_session,
            load_acp_session = SessionManager.load_acp_session,
        }

        return session
    end

    -- _is_restoring_session is still true when create fires → guard catches it.
    it(
        "Race A: create fires before load completes — fix should prevent overwrite",
        function()
            local create_cb_ref = {}
            local load_cb_ref = {}
            local session = make_session(create_cb_ref, load_cb_ref)

            session:new_session()
            assert.is_nil(session.session_id)

            session:load_acp_session("restored-id", "title", nil)
            assert.is_true(session._is_restoring_session)

            create_cb_ref.cb({ sessionId = "new-id" }, nil)
            drain()

            load_cb_ref.cb(nil)
            drain()

            assert.equal("restored-id", session.session_id)
            assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
        end
    )

    -- session_id is already set when create fires; staleness guard catches it.
    it(
        "Race B: load completes before create fires — session_id guard prevents overwrite",
        function()
            local create_cb_ref = {}
            local session = make_session(create_cb_ref, nil) -- load fires immediately

            session:new_session()
            assert.is_nil(session.session_id)

            -- Load answers in the same tick, but its handler is scheduled, so it
            -- only lands on the drain.
            session:load_acp_session("restored-id", "title", nil)
            drain()
            assert.equal("restored-id", session.session_id)
            assert.is_false(session._is_restoring_session)

            create_cb_ref.cb({ sessionId = "new-id" }, nil)
            drain()

            assert.equal("restored-id", session.session_id)
            assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
        end
    )

    -- Regression #277 / #180: on restore-first, modes come ONLY from the stale
    -- create response. The guard must adopt its mode/model capabilities before
    -- returning, else mode switching fails with "This provider does not support
    -- mode switching".
    it(
        "Race A: stale create adopts legacy modes/models from response",
        function()
            local create_cb_ref = {}
            local load_cb_ref = {}
            local session = make_session(create_cb_ref, load_cb_ref)

            session:new_session()
            session:load_acp_session("restored-id", "title", nil)
            assert.is_true(session._is_restoring_session)

            create_cb_ref.cb({
                sessionId = "new-id",
                modes = {
                    currentModeId = "chat",
                    availableModes = {
                        { id = "chat", name = "Chat" },
                        { id = "plan", name = "Plan" },
                    },
                },
                models = { currentModelId = "sonnet", availableModels = {} },
            }, nil)
            drain()
            load_cb_ref.cb(nil)
            drain()

            assert.equal("restored-id", session.session_id)
            assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
            --- @type agentic.acp.ModesInfo
            local modes_set = session.config_options._legacy_modes_set
            assert.is_not_nil(modes_set)
            assert.equal("chat", modes_set.currentModeId)
            assert.is_not_nil(session.config_options._legacy_models_set)
        end
    )

    -- Same regression on the configOptions path: providers announcing
    -- configOptions instead of legacy modes/models also need adoption from the
    -- stale create response on restore-first.
    it("Race A: stale create adopts configOptions from response", function()
        local create_cb_ref = {}
        local load_cb_ref = {}
        local session = make_session(create_cb_ref, load_cb_ref)

        session:new_session()
        session:load_acp_session("restored-id", "title", nil)
        assert.is_true(session._is_restoring_session)

        local config_options = {
            { category = "mode", currentValue = "chat" },
        }
        create_cb_ref.cb({
            sessionId = "new-id",
            configOptions = config_options,
        }, nil)
        drain()
        load_cb_ref.cb(nil)
        drain()

        assert.equal("restored-id", session.session_id)
        assert.is_true(vim.tbl_contains(session._cancelled, "new-id"))
        assert.equal(config_options, session.config_options._config_options_set)
        -- configOptions path must NOT touch the legacy setters.
        assert.is_nil(session.config_options._legacy_modes_set)
        assert.is_nil(session.config_options._legacy_models_set)
    end)

    -- The ordering `SessionRestore` produces: the manager is built for the
    -- restore, so its bootstrap `session/new` is already queued for the next tick
    -- when `load_acp_session` runs in this one. An unguarded bootstrap reaches
    -- `_cancel_session`, which clears `_is_restoring_session` and thereby disarms
    -- the Race A guard, leaving two requests competing for `session_id`.
    it("load before the bootstrap sends no competing create", function()
        local create_cb_ref = {}
        local load_cb_ref = {}
        local session = make_session(create_cb_ref, load_cb_ref)

        -- The constructor's queued bootstrap, through the same `vim.schedule`
        -- queue the real one uses: enqueued first, run last.
        vim.schedule(function()
            session:_bootstrap_session()
        end)

        session:load_acp_session("restored-id", "title", nil)
        drain()

        -- Nothing in flight to answer out of order, and the guard is still armed.
        assert.is_nil(create_cb_ref.cb)
        assert.is_true(session._is_restoring_session)

        load_cb_ref.cb(nil)
        drain()

        assert.equal("restored-id", session.session_id)
        assert.equal(0, #session._cancelled)
    end)

    -- The staleness guard runs BEFORE the `if err or not response` branch, so the
    -- restored session_id survives. Moved below that branch, the error path would
    -- null out session_id and silently drop the restore. No cancellation expected:
    -- a failed create has no sessionId.
    it(
        "Race B: stale create ERRORS after load — restored session survives",
        function()
            local create_cb_ref = {}
            local session = make_session(create_cb_ref, nil) -- load fires immediately

            session:new_session()
            assert.is_nil(session.session_id)

            -- Load answers in the same tick, its handler lands on the drain.
            session:load_acp_session("restored-id", "title", nil)
            drain()
            assert.equal("restored-id", session.session_id)
            assert.is_false(session._is_restoring_session)

            create_cb_ref.cb(nil, { message = "boom" })
            drain()

            assert.equal("restored-id", session.session_id)
            assert.equal(0, #session._cancelled)
        end
    )

    it("claims the ACP id while restoring and clears it on failure", function()
        local create_cb_ref = {}
        local load_cb_ref = {}
        local session = make_session(create_cb_ref, load_cb_ref)

        session:load_acp_session("restored-id", "title", nil)

        assert.equal("restored-id", session._restoring_session_id)

        load_cb_ref.cb({ message = "boom" })
        drain()

        assert.is_nil(session._restoring_session_id)
        assert.is_nil(session.session_id)
    end)

    it("cancels an in-flight restore before starting a new session", function()
        local create_cb_ref = {}
        local load_cb_ref = {}
        local session = make_session(create_cb_ref, load_cb_ref)
        local clear_spy = spy.new(function() end)
        session.widget.clear = clear_spy

        session:load_acp_session("restored-id", "title", nil)
        session:new_session()

        assert.is_true(vim.tbl_contains(session._cancelled, "restored-id"))
        assert.is_nil(session._restoring_session_id)
        assert.spy(clear_spy).was.called(1)
    end)
end)
